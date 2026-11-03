import CoreGraphics
import Foundation

struct ModelScore: Codable, Identifiable {
    var kind: ModelKind
    var accuracy: Float          // zone taps classified into the right cell
    var errorMM: Float           // mean distance from the estimated point to the true one
    var noiseRejected: Float     // noise examples correctly ignored (NaN when there are none)
    var id: String { kind.rawValue }
}

struct TrainReport: Codable {
    var date = Date()
    var grid: Grid
    var samples: Int
    var perCell: [Int]
    var noise: Int
    var usesAudio: Bool
    var scores: [ModelScore]
    var chosen: ModelKind
    var accuracy: Float
    var rowAccuracy: Float
    var columnAccuracy: Float
    var perCellAccuracy: [Float]
    var confusion: [[Int]]       // [true cell][predicted class]; last column = noise when present
    var errorMM: Float
    var seconds: Double
}

/// Everything needed at tap time: feature scaling, the classifier, the tap memory for rejecting unfamiliar taps,
/// and where taps in each cell actually landed.
struct TouchModel: Codable {
    var grid: Grid
    var usesAudio: Bool
    var hasNoise: Bool
    var standardizer: Standardizer
    var classifier: Classifier
    var memory: KNN
    var typical: Floats          // per class: median distance from a tap to its nearest same-class neighbour
    var centroids: [Float]       // per cell: mean landing point x,y (normalised)
    var audioFill: Floats?       // feature means used when a tap arrives without audio
    var report: TrainReport

    var cells: Int { grid.count }

    func features(of s: TapSample) -> [Float] {
        Trainer.features(s, audio: usesAudio, fill: audioFill?.v)
    }

    func predict(_ raw: [Float]) -> Prediction {
        let q = standardizer.apply(raw)
        let p = classifier.probs(q)
        let zone = Array(p.prefix(cells))
        let noiseP = hasNoise ? p[cells] : 0
        let zoneSum = max(zone.reduce(0, +), 1e-6)
        let post = zone.map { $0 / zoneSum }
        let best = post.indices.max { post[$0] < post[$1] } ?? 0
        var x: Float = 0, y: Float = 0
        for c in 0..<cells { x += post[c] * centroids[c * 2]; y += post[c] * centroids[c * 2 + 1] }
        // How far is this tap from what we've seen in its cell?
        let dist = memory.distances(q)
        var nearest = Float.infinity
        for i in dist.indices where memory.y[i] == best { nearest = min(nearest, dist[i]) }
        let ratio = nearest / max(typical.v[best], 1e-3)
        return Prediction(posterior: post, cell: best, confidence: zone[best], noise: noiseP,
                          point: CGPoint(x: CGFloat(x), y: CGFloat(y)), familiarity: ratio)
    }
}

struct Prediction {
    var posterior: [Float]   // over cells, sums to 1
    var cell: Int
    var confidence: Float    // probability of `cell` among all classes (noise included)
    var noise: Float         // probability it wasn't a deliberate tap
    var point: CGPoint       // estimated landing point, normalised
    var familiarity: Float   // distance to nearest known tap of this cell / typical distance (≈1 is normal)

    func isNoise() -> Bool { noise > confidence }
    func isUnfamiliar(_ factor: Float) -> Bool { familiarity > factor }
}

enum TrainError: LocalizedError {
    case notEnough(String)
    var errorDescription: String? { switch self { case .notEnough(let s): s } }
}

enum Trainer {
    /// Feature vector for one sample. `fill` stands in for missing audio.
    static func features(_ s: TapSample, audio: Bool, fill: [Float]?) -> [Float] {
        var f = Features.imu(gyro: s.gyro.v, accel: s.accel.v, lidAngle: s.lidAngle)
        if audio {
            if let a = s.audio?.v, a.count == MicRing.segmentLength {
                f += Features.audio(a, sampleRate: s.sampleRate ?? 48_000, tapStrength: s.peakGyro)
            } else {
                f += fill ?? Array(repeating: 0, count: Features.audioCount)
            }
        }
        return f
    }

    /// Full training run: features → cross-validate every model → pick the best → fit it on everything.
    static func train(samples: [TapSample], grid: Grid, micFusion: Bool, choice: ModelKind?, screenMM: CGSize,
                      progress: @escaping (Double, String) -> Void) throws -> TouchModel {
        let start = Date()
        let cells = grid.count
        let zone = samples.filter { !$0.isNoise && $0.point != nil }
        let noise = samples.filter(\.isNoise)
        var perCell = [Int](repeating: 0, count: cells)
        for s in zone { perCell[grid.cell(at: s.point!)] += 1 }
        let thin = perCell.enumerated().filter { $0.element < 3 }.map { $0.offset + 1 }
        guard thin.isEmpty else {
            throw TrainError.notEnough("Every cell needs at least 3 taps. Missing: cell \(thin.map(String.init).joined(separator: ", ")).")
        }
        let hasNoise = noise.count >= 4
        let all = zone + (hasNoise ? noise : [])
        let classes = cells + (hasNoise ? 1 : 0)
        let labels = all.map { $0.isNoise ? cells : grid.cell(at: $0.point!) }
        let audioShare = Float(zone.filter { $0.audio != nil }.count) / Float(max(zone.count, 1))
        let usesAudio = micFusion && audioShare >= 0.7
        progress(0.03, "Extracting features")

        // Base features, with missing audio filled by the mean of present audio.
        var base = all.map { features($0, audio: false, fill: nil) }
        var fill: [Float]?
        if usesAudio {
            let audioF: [[Float]?] = all.map { s in
                s.audio.map { Features.audio($0.v, sampleRate: s.sampleRate ?? 48_000, tapStrength: s.peakGyro) }
            }
            let present = audioF.compactMap { $0 }
            let mean = (0..<Features.audioCount).map { j in present.reduce(0) { $0 + $1[j] } / Float(max(present.count, 1)) }
            fill = mean
            for i in base.indices { base[i] += audioF[i] ?? mean }
        }
        // Two augmented copies of every tap (time shift + sensor noise) for training folds only.
        var rng = SplitMix(seed: 42)
        var augmented: [[[Float]]] = []
        for (i, s) in all.enumerated() {
            var copies: [[Float]] = []
            for shift in [-2, 2] {
                let gn = max(s.peakGyro * 0.03, 0.04)
                let g = Features.augment(s.gyro.v, shift: shift, noise: gn, rng: &rng)
                let a = Features.augment(s.accel.v, shift: shift, noise: 0.0006, rng: &rng)
                var f = Features.imu(gyro: g, accel: a, lidAngle: s.lidAngle)
                if usesAudio { f += Array(base[i][Features.imuCount...]) }
                copies.append(f)
            }
            augmented.append(copies)
        }
        let d = base[0].count
        let weights = Features.weights(audio: usesAudio)
        progress(0.12, "Cross-validating")

        // Stratified folds.
        let minCount = (0..<classes).map { c in labels.filter { $0 == c }.count }.min() ?? 0
        let k = max(2, min(5, minCount))
        var fold = [Int](repeating: 0, count: all.count)
        for c in 0..<classes {
            var idx = labels.indices.filter { labels[$0] == c }
            idx.shuffle(using: &rng)
            for (j, i) in idx.enumerated() { fold[i] = j % k }
        }

        let kinds: [ModelKind] = [.knn, .lda, .logistic, .mlp]
        var oof: [ModelKind: [[Float]]] = [:]
        for kind in ModelKind.allCases { oof[kind] = Array(repeating: [], count: all.count) }
        for f in 0..<k {
            let trainIdx = all.indices.filter { fold[$0] != f }, testIdx = all.indices.filter { fold[$0] == f }
            let (xTrain, yTrain, std) = matrix(trainIdx, base: base, augmented: augmented, labels: labels, d: d, weights: weights)
            let n = yTrain.count
            var perKind: [ModelKind: Classifier] = [:]
            for kind in kinds {
                perKind[kind] = Classifier.train(kind, x: xTrain, y: yTrain, n: n, d: d, classes: classes, seed: UInt64(f + 1))
            }
            for i in testIdx {
                let q = std.apply(base[i])
                var probsAll: [[Float]] = []
                for kind in kinds {
                    let p = perKind[kind]!.probs(q)
                    oof[kind]![i] = p
                    probsAll.append(p)
                }
                oof[.ensemble]![i] = (0..<classes).map { c in probsAll.reduce(0) { $0 + $1[c] } / Float(probsAll.count) }
            }
            progress(0.12 + 0.68 * Double(f + 1) / Double(k), "Cross-validating \(f + 1)/\(k)")
        }

        // True landing-point centroid of each cell, for turning cell probabilities into a point.
        var centroids = [Float](repeating: 0, count: cells * 2)
        for c in 0..<cells {
            let pts = zone.compactMap(\.point).filter { grid.cell(at: $0) == c }
            let ctr = grid.center(c)
            let cx = pts.isEmpty ? ctr.x : pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            let cy = pts.isEmpty ? ctr.y : pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
            centroids[c * 2] = Float(cx)
            centroids[c * 2 + 1] = Float(cy)
        }

        func score(_ kind: ModelKind) -> ModelScore {
            var correct = 0, zoneN = 0, noiseOK = 0, err: Float = 0
            for (i, s) in all.enumerated() {
                let p = oof[kind]![i]
                let pred = p.indices.max { p[$0] < p[$1] }!
                if s.isNoise { if pred == cells { noiseOK += 1 }; continue }
                zoneN += 1
                if pred == labels[i] { correct += 1 }
                let zs = max(p.prefix(cells).reduce(0, +), 1e-6)
                var x: Float = 0, y: Float = 0
                for c in 0..<cells { x += p[c] / zs * centroids[c * 2]; y += p[c] / zs * centroids[c * 2 + 1] }
                let pt = s.point!
                let dx = (x - Float(pt.x)) * Float(screenMM.width), dy = (y - Float(pt.y)) * Float(screenMM.height)
                err += (dx * dx + dy * dy).squareRoot()
            }
            return ModelScore(kind: kind, accuracy: Float(correct) / Float(max(zoneN, 1)), errorMM: err / Float(max(zoneN, 1)),
                              noiseRejected: hasNoise ? Float(noiseOK) / Float(noise.count) : .nan)
        }
        let scores = ModelKind.allCases.map(score)
        // Prefer accuracy; between near-ties (within 1%), prefer the smaller position error.
        let bestAcc = scores.map(\.accuracy).max() ?? 0
        let auto = scores.filter { $0.accuracy >= bestAcc - 0.01 }.min { $0.errorMM < $1.errorMM }!.kind
        let chosen = choice ?? auto

        // Confusion and per-row / per-column accuracy for the chosen model.
        var confusion = Array(repeating: Array(repeating: 0, count: classes), count: cells)
        var rowOK = 0, colOK = 0, zoneN = 0
        for (i, s) in all.enumerated() where !s.isNoise {
            let p = oof[chosen]![i]
            let pred = p.indices.max { p[$0] < p[$1] }!
            confusion[labels[i]][pred] += 1
            zoneN += 1
            if pred < cells {
                if pred / grid.cols == labels[i] / grid.cols { rowOK += 1 }
                if pred % grid.cols == labels[i] % grid.cols { colOK += 1 }
            }
        }
        let perCellAcc = (0..<cells).map { c in Float(confusion[c][c]) / Float(max(confusion[c].reduce(0, +), 1)) }

        progress(0.85, "Training final model")
        let (xAll, yAll, std) = matrix(Array(all.indices), base: base, augmented: augmented, labels: labels, d: d, weights: weights)
        let classifier = Classifier.train(chosen, x: xAll, y: yAll, n: yAll.count, d: d, classes: classes, seed: 99)
        // Memory: original (not augmented) taps, standardised.
        let memX = all.indices.flatMap { std.apply(base[$0]) }
        let memory = KNN(x: Floats(memX), y: labels, d: d, classes: classes)
        var typical = [Float](repeating: 1, count: classes)
        for c in 0..<classes {
            let idx = labels.indices.filter { labels[$0] == c }
            var nn: [Float] = []
            for i in idx {
                let qi = Array(memX[(i * d)..<(i * d + d)])
                let dist = memory.distances(qi)
                nn.append(idx.filter { $0 != i }.map { dist[$0] }.min() ?? 1)
            }
            nn.sort()
            typical[c] = nn.isEmpty ? 1 : max(nn[nn.count / 2], 1e-3)
        }
        let chosenScore = scores.first { $0.kind == chosen }!
        let report = TrainReport(grid: grid, samples: zone.count, perCell: perCell, noise: noise.count, usesAudio: usesAudio,
                                 scores: scores, chosen: chosen, accuracy: chosenScore.accuracy,
                                 rowAccuracy: Float(rowOK) / Float(max(zoneN, 1)), columnAccuracy: Float(colOK) / Float(max(zoneN, 1)),
                                 perCellAccuracy: perCellAcc, confusion: confusion, errorMM: chosenScore.errorMM,
                                 seconds: Date().timeIntervalSince(start))
        progress(1, "Done")
        return TouchModel(grid: grid, usesAudio: usesAudio, hasNoise: hasNoise, standardizer: std, classifier: classifier,
                          memory: memory, typical: Floats(typical), centroids: centroids, audioFill: fill.map(Floats.init),
                          report: report)
    }

    /// Standardised training matrix (originals + augmented copies) for a set of sample indices.
    private static func matrix(_ idx: [Int], base: [[Float]], augmented: [[[Float]]], labels: [Int], d: Int,
                               weights: [Float]) -> ([Float], [Int], Standardizer) {
        var raw: [Float] = []
        raw.reserveCapacity(idx.count * d)
        for i in idx { raw += base[i] }
        let std = Standardizer(fit: raw, n: idx.count, d: d, weights: weights)
        var x = std.apply(raw), y = idx.map { labels[$0] }
        for i in idx { for copy in augmented[i] { x += std.apply(copy); y.append(labels[i]) } }
        return (x, y, std)
    }
}
