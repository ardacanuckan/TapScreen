# Install guide

From download to your first tap in about 5 minutes. No Terminal needed.

## 1. Check your Mac

Apple menu  → **About This Mac**. TapScreen works if the chip is **M2 or newer** (M2, M3, M4...) or an **M1 Pro or
M1 Max** in a 14" or 16" MacBook Pro, and macOS is **14 (Sonoma) or newer**.

It does not work on the M1 MacBook Air, the 13" M1 MacBook Pro, Intel Macs or desktop Macs: they have no motion
sensor.

## 2. Download

1. Open the [latest release](https://github.com/ardacanuckan/TapScreen/releases/latest) and download **TapScreen-macOS.zip**.
2. Double-click the zip in your Downloads folder. You get **TapScreen.app**.
3. Drag **TapScreen.app** to your **Applications** folder (or the Desktop, if you prefer).

## 3. Open it the first time

TapScreen isn't from the App Store, so macOS asks before the first launch.

1. Double-click **TapScreen**. macOS says it can't verify the app. Click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security** and scroll down to **Security**. You'll see
   *"TapScreen" was blocked to protect your Mac*. Click **Open Anyway** and enter your password.
3. Click **Open Anyway** once more in the dialog that appears.

You only do this once. TapScreen opens with a window and a hand icon in the Dock.

## 4. Allow the two permissions

TapScreen needs two switches in System Settings. Everything stays on your Mac.

**Input Monitoring** lets it read the motion sensor (macOS files the sensor under input devices).

1. macOS shows *"TapScreen" would like to receive keystrokes from any application*. Click **Open System Settings**.
2. Turn **TapScreen** on, then click **Quit & Reopen** if asked.

If no prompt appears: System Settings → Privacy & Security → **Input Monitoring** → **+** → choose TapScreen.

**Accessibility** lets a tap press buttons and open apps.

1. In TapScreen's **Home** tab, click **Allow** on the orange banner.
2. In System Settings → Privacy & Security → **Accessibility**, turn **TapScreen** on.
3. Quit TapScreen (⌘Q) and open it again.

The Home tab shows "sensor 790 Hz" (or similar) in green when the sensor works, and the orange banners disappear
when both permissions are on.

## 5. Calibrate

TapScreen learns what a tap feels like on *your* Mac. This takes about 3 minutes.

1. Sit the way you normally use the laptop. If it's usually on your lap, calibrate on your lap.
2. Open the **Calibration** tab. Pick a grid (**3×3** is a good start) and keep 12-15 taps per cell.
3. Click **Start calibration**. The screen goes dark and shows a dot.
4. Tap the dot with a **quick, light flick** of your fingertip, the way you'd tap a phone. Don't press.
   Wait half a second; the dot moves. Repeat until the counter is full.
   - The panel says **Good tap**, **A little crisper** or **Gentler is fine**.
   - **delete** undoes the last tap, **esc** stops.
5. Then, for 20 seconds, **don't touch the screen**: type, click, scroll and shift around. TapScreen learns to
   ignore these bumps.
6. Training runs by itself and takes a couple of seconds. The **Model** tab shows how accurate it is.

## 6. Choose what a tap does

In the **Home** tab:

- **Smart Touch** presses the button, link or field where you tapped.
- **Tap Map** runs what you assigned to each part of the screen.
- **Zoom & Tap** zooms in with each tap and clicks after two or three.

To set up Tap Map, open the **Tap Map** tab, click a zone and pick what it does: open an app (pick it from
Applications), a website, a file or folder, music controls, desktops, Mission Control, or "Press what's under my
finger". **Try it now** runs it immediately. The percentage on each zone is how often the model gets that zone
right.

## 7. Everyday use

- **⌃⌥T** (Control-Option-T) turns TapScreen on or off from anywhere. When it's off, the sensors stop.
- Closing the window keeps TapScreen running. Click the Dock icon to bring it back; **⌘Q** quits.
- **Settings → Launch at login** starts it automatically.
- Typing, clicking and trackpad use are ignored, so you can work normally with it on.

## Getting better accuracy

- **Crisp, light taps.** A soft press is hard to tell from noise; a short flick is easy.
- **More taps.** Run another calibration round without "Discard earlier taps". New taps add to the old ones.
- **Calibrate where you use it.** Desk and lap feel different to the sensor. If you use both, calibrate in both.
- **Fewer zones if you want near-certainty.** 2×2 is the most reliable. Smart Touch still finds the exact button
  inside each zone.
- **Tap the middle of a zone**, not the edges.

## Troubleshooting

| Problem | Fix |
|---|---|
| Home says the sensor is off or "waiting for sensor" | Allow Input Monitoring (step 4) and reopen TapScreen. If it still shows no data, the Mac may have no motion sensor (step 1). |
| Taps are detected but nothing gets pressed | Allow Accessibility (step 4), then quit and reopen. |
| Permissions stopped working after an update | Only happens when coming from 1.0.0. In Privacy & Security → Accessibility and Input Monitoring, remove TapScreen with **–**, add it again with **+**, and reopen it. Later updates keep them. |
| Taps go to the wrong place | Add more calibration taps where you use the laptop, or use a coarser grid. Check the Model tab for weak zones. |
| It reacts when I didn't tap | Run **Calibration → Record noise only** while doing whatever triggered it. |
| No hand icon in the menu bar | A full menu bar hides icons behind the camera notch. Use the Dock icon or ⌃⌥T instead. |

## Update

Download the new zip, quit TapScreen, and replace the old app with the new one. Your calibration, settings and
permissions are kept. (Coming from 1.0.0, switch the two permissions on once more; see Troubleshooting.)

## Uninstall

1. Quit TapScreen and move **TapScreen.app** to the Trash.
2. Delete the folder `~/Library/Application Support/TapScreen` (Finder → Go → Go to Folder…) to remove your
   calibration data.
3. Optionally remove TapScreen from Privacy & Security → Accessibility and Input Monitoring.
