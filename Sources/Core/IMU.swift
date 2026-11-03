import Foundation
import IOKit
import IOKit.hid

/// Reads the undocumented Bosch IMU and lid-angle sensor on Apple Silicon MacBooks.
///
/// The IMU lives on the logic board and shows up as `AppleSPUHIDDevice` services: usage page 0xFF00,
/// usage 3 = accelerometer (g), 9 = gyroscope (deg/s). Each 22-byte report carries int32 Q16.16 x/y/z at
/// offsets 6/10/14. They only stream after the `AppleSPUHIDDriver` services are told to report.
/// The lid sensor is usage page 0x20 / usage 0x8A (whole degrees, feature report 1).
/// Access needs Input Monitoring, not root. (Sensor format credit: LidTap, yamete, apple-silicon-accelerometer.)
final class IMUReader {
    enum Kind { case accel, gyro }

    /// Called on the sensor thread for every report. Keep it cheap.
    var onSample: ((Kind, Double, SIMD3<Float>) -> Void)?

    private let lock = NSLock()
    private var _lidAngle: Int?
    private var _lidMovedAt = 0.0
    private var stableLid: Int?
    private var _error: String?
    private var _counts = (accel: 0, gyro: 0)
    private var _stop = false
    private var _restart = false
    private var thread: Thread?

    // Sensor thread only.
    private var devices: [IOHIDDevice] = []
    private var lidDevice: IOHIDDevice?
    private var boxes: [Box] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    fileprivate var lastSample = 0.0
    fileprivate var localCounts = (accel: 0, gyro: 0)

    var lidAngle: Int? { lock.withLock { _lidAngle } }
    /// When the lid last moved by 2° or more (mach seconds).
    var lidMovedAt: Double { lock.withLock { _lidMovedAt } }
    var error: String? { lock.withLock { _error } }
    var isRunning: Bool { lock.withLock { thread != nil && !_stop } }

    /// Samples received since the last call, per stream.
    func takeCounts() -> (accel: Int, gyro: Int) {
        lock.withLock { defer { _counts = (0, 0) }; return _counts }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        // A thread that is still shutting down starts again once it has closed the devices.
        guard thread == nil else { if _stop { _restart = true }; return }
        _stop = false
        let t = Thread { [weak self] in self?.run() }
        t.name = "TapScreen.IMU"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { lock.withLock { _stop = true; _restart = false } }

    private func run() {
        open()
        var lastReopen = MachClock.now()
        var lastLid = 0.0
        lastSample = MachClock.now()
        var feature = [UInt8](repeating: 0, count: 8)
        while !lock.withLock({ _stop }) {
            if devices.isEmpty { Thread.sleep(forTimeInterval: 0.1) } else { CFRunLoopRunInMode(.defaultMode, 0.1, false) }
            let now = MachClock.now()
            lock.withLock {
                _counts.accel += localCounts.accel
                _counts.gyro += localCounts.gyro
            }
            localCounts = (0, 0)
            // Watchdog: reports stop after sleep/wake or when something powers the sensor down.
            if now - lastSample > 2.5 && now - lastReopen > 5 {
                Log.sensor.notice("No IMU data for \(Int(now - self.lastSample)) s, reopening")
                lastReopen = now
                close()
                open()
            }
            if let lid = lidDevice, now - lastLid > 0.1 {
                lastLid = now
                var len: CFIndex = 8
                if IOHIDDeviceGetReport(lid, kIOHIDReportTypeFeature, 1, &feature, &len) == kIOReturnSuccess, len >= 3 {
                    let angle = Int(feature[1]) | Int(feature[2]) << 8
                    let moved = stableLid.map { abs($0 - angle) >= 2 } ?? false
                    if stableLid == nil || moved { stableLid = angle }
                    lock.withLock {
                        _lidAngle = angle
                        if moved { _lidMovedAt = now }
                    }
                }
            }
        }
        close()
        setReporting(false)
        let restart = lock.withLock { () -> Bool in
            thread = nil
            _stop = false
            defer { _restart = false }
            return _restart
        }
        if restart { start() }
    }

    private final class Box {
        weak var reader: IMUReader?
        let kind: Kind
        init(_ reader: IMUReader, _ kind: Kind) { self.reader = reader; self.kind = kind }
    }

    private func setReporting(_ on: Bool) {
        for driver in services("AppleSPUHIDDriver") {
            let values = on ? [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)]
                            : [("SensorPropertyReportingState", 0)]
            for (key, value) in values { IORegistryEntrySetCFProperty(driver, key as CFString, NSNumber(value: value)) }
            IOObjectRelease(driver)
        }
    }

    private func open() {
        setReporting(true)
        var foundAccel = false, foundGyro = false
        let loop = CFRunLoopGetCurrent()!
        for service in services("AppleSPUHIDDevice") {
            defer { IOObjectRelease(service) }
            let page = intProperty(service, "PrimaryUsagePage"), usage = intProperty(service, "PrimaryUsage")
            if page == 0x20, usage == 0x8A, lidDevice == nil {
                if let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                   IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                    lidDevice = dev
                }
                continue
            }
            guard page == 0xFF00, usage == 3 || usage == 9, intProperty(service, "MaxInputReportSize") == 22 else { continue }
            let kind: Kind = usage == 3 ? .accel : .gyro
            if (kind == .accel && foundAccel) || (kind == .gyro && foundGyro) { continue }
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let status = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else {
                lock.withLock { _error = status == kIOReturnNotPermitted ? "permission" : "open failed (\(status))" }
                continue
            }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            let box = Box(self, kind)
            boxes.append(box)
            buffers.append(buffer)
            devices.append(dev)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, buffer, 64, { context, _, _, _, _, report, length, timestamp in
                guard let context, length == 22 else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                guard let reader = box.reader else { return }
                func q16(_ offset: Int) -> Float {
                    var v: Int32 = 0
                    memcpy(&v, report + offset, 4)
                    return Float(Int32(littleEndian: v)) / 65536
                }
                let t = Double(timestamp) * MachClock.tick
                reader.lastSample = t
                if box.kind == .accel { reader.localCounts.accel += 1 } else { reader.localCounts.gyro += 1 }
                reader.onSample?(box.kind, t, SIMD3(q16(6), q16(10), q16(14)))
            }, Unmanaged.passUnretained(box).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(dev, loop, CFRunLoopMode.defaultMode.rawValue)
            if kind == .accel { foundAccel = true } else { foundGyro = true }
        }
        if foundAccel && foundGyro {
            lock.withLock { _error = nil }
        } else if lock.withLock({ _error == nil }) {
            lock.withLock { _error = "missing" }
        }
    }

    private func close() {
        let loop = CFRunLoopGetCurrent()!
        for dev in devices {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, buffers[0], 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(dev, loop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let lid = lidDevice { IOHIDDeviceClose(lid, IOOptionBits(kIOHIDOptionsTypeNone)) }
        devices = []
        lidDevice = nil
        boxes = []
        // Report buffers stay allocated: a closed device may still touch them once more. They are tiny.
    }

    private func services(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_service_t] = []
        while case let s = IOIteratorNext(iterator), s != 0 { out.append(s) }
        return out
    }

    private func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
}
