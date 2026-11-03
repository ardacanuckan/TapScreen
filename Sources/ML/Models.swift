import Accelerate
import Foundation

// Small on-device learners. Data is row-major [Float] (n × d). Everything trains in well under a second on a few
// hundred taps, so cross-validating all of them on every training run is affordable.

/// C (m×n) = A (m×p) · B (p×n), row-major.
func matmul(_ a: [Float], _ b: [Float], _ m: Int, _ p: Int, _ n: Int) -> [Float] {
    var c = [Float](repeating: 0, count: m * n)
    vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(p))
    return c
}

/// Transpose of a rows×cols matrix.
func transpose(_ a: [Float], _ rows: Int, _ cols: Int) -> [Float] {
    var t = [Float](repeating: 0, count: rows * cols)
    vDSP_mtrans(a, 1, &t, 1, vDSP_Length(cols), vDSP_Length(rows))
    return t
}

func softmaxInPlace(_ z: inout [Float], rows: Int, cols: Int) {
    for r in 0..<rows {
        let o = r * cols
        var m = -Float.infinity
        for c in 0..<cols { m = max(m, z[o + c]) }
        var s: Float = 0
        for c in 0..<cols { z[o + c] = exp(z[o + c] - m); s += z[o + c] }
        for c in 0..<cols { z[o + c] /= s }
    }
}

struct Standardizer: Codable {
    var mean: Floats
    var scale: Floats   // weight / std

    init(fit x: [Float], n: Int, d: Int, weights: [Float]) {
        var m = [Float](repeating: 0, count: d), v = [Float](repeating: 0, count: d)
        for i in 0..<n { for j in 0..<d { m[j] += x[i * d + j] } }
        for j in 0..<d { m[j] /= Float(max(n, 1)) }
        for i in 0..<n { for j in 0..<d { let e = x[i * d + j] - m[j]; v[j] += e * e } }
        var s = [Float](repeating: 1, count: d)
        for j in 0..<d { s[j] = weights[j] / max((v[j] / Float(max(n - 1, 1))).squareRoot(), 1e-3) }
        mean = Floats(m)
        scale = Floats(s)
    }

    var dimension: Int { mean.v.count }

    func apply(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        let d = mean.v.count
        for i in 0..<x.count { out[i] = (x[i] - mean.v[i % d]) * scale.v[i % d] }
        return out
    }
}

/// Distance-weighted k-nearest neighbours. Also the memory used for rejecting unfamiliar taps.
struct KNN: Codable {
    var x: Floats
    var y: [Int]
    var d: Int
    var k = 5
    var classes: Int

    func distances(_ q: [Float]) -> [Float] {
        let n = y.count
        var out = [Float](repeating: 0, count: n)
        x.v.withUnsafeBufferPointer { xp in
            q.withUnsafeBufferPointer { qp in
                for i in 0..<n {
                    var s: Float = 0
                    vDSP_distancesq(xp.baseAddress! + i * d, 1, qp.baseAddress!, 1, &s, vDSP_Length(d))
                    out[i] = s.squareRoot()
                }
            }
        }
        return out
    }

    func probs(_ q: [Float]) -> [Float] {
        let dist = distances(q)
        let order = dist.indices.sorted { dist[$0] < dist[$1] }.prefix(min(k, dist.count))
        var p = [Float](repeating: 0.02, count: classes)
        for i in order { p[y[i]] += 1 / (dist[i] + 0.5) }
        let s = p.reduce(0, +)
        return p.map { $0 / s }
    }
}

/// A linear softmax model: logits = x·W + b (W is d×C). Both LDA and logistic regression produce one.
struct Linear: Codable {
    var w: Floats
    var b: Floats
    var d: Int
    var classes: Int
    var temperature: Float = 1

    func probs(_ q: [Float]) -> [Float] {
        var z = matmul(q, w.v, 1, d, classes)
        for c in 0..<classes { z[c] = (z[c] + b.v[c]) / temperature }
        softmaxInPlace(&z, rows: 1, cols: classes)
        return z
    }

    /// Shrinkage linear discriminant analysis: class means with a pooled covariance pulled toward a scaled identity,
    /// which keeps it stable when there are fewer taps than features.
    /// Tuned on real taps (see tools/experiment.swift).
    static var ldaShrinkage = 0.4

    static func lda(x: [Float], y: [Int], n: Int, d: Int, classes: Int, shrinkage: Double = ldaShrinkage) -> Linear {
        var means = [Double](repeating: 0, count: classes * d), counts = [Double](repeating: 0, count: classes)
        for i in 0..<n { counts[y[i]] += 1; for j in 0..<d { means[y[i] * d + j] += Double(x[i * d + j]) } }
        for c in 0..<classes where counts[c] > 0 { for j in 0..<d { means[c * d + j] /= counts[c] } }
        var centered = [Float](repeating: 0, count: n * d)
        for i in 0..<n { for j in 0..<d { centered[i * d + j] = x[i * d + j] - Float(means[y[i] * d + j]) } }
        let s = matmul(transpose(centered, n, d), centered, d, n, d)
        let denom = Double(max(n - classes, 1))
        var cov = s.map { Double($0) / denom }
        var trace = 0.0
        for j in 0..<d { trace += cov[j * d + j] }
        let target = max(trace / Double(d), 1e-6)
        for idx in 0..<(d * d) { cov[idx] *= (1 - shrinkage) }
        for j in 0..<d { cov[j * d + j] += shrinkage * target }
        let chol = Cholesky(cov, d)
        var w = [Float](repeating: 0, count: d * classes), b = [Float](repeating: 0, count: classes)
        for c in 0..<classes {
            let mu = Array(means[(c * d)..<(c * d + d)])
            let sol = chol.solve(mu)
            var quad = 0.0
            for j in 0..<d { w[j * classes + c] = Float(sol[j]); quad += sol[j] * mu[j] }
            let prior = max(counts[c], 1) / Double(n)
            b[c] = Float(-0.5 * quad + log(prior))
        }
        var model = Linear(w: Floats(w), b: Floats(b), d: d, classes: classes)
        model.temperature = model.fitTemperature(x: x, y: y, n: n)
        return model
    }

    /// Multinomial logistic regression with L2, full-batch Adam.
    static func logistic(x: [Float], y: [Int], n: Int, d: Int, classes: Int, l2: Float = 0.02, epochs: Int = 250) -> Linear {
        var w = [Float](repeating: 0, count: d * classes), b = [Float](repeating: 0, count: classes)
        var adamW = Adam(count: w.count, lr: 0.05), adamB = Adam(count: classes, lr: 0.05)
        let xt = transpose(x, n, d)
        for _ in 0..<epochs {
            var z = matmul(x, w, n, d, classes)
            for i in 0..<n { for c in 0..<classes { z[i * classes + c] += b[c] } }
            softmaxInPlace(&z, rows: n, cols: classes)
            for i in 0..<n { z[i * classes + y[i]] -= 1 }
            let inv = 1 / Float(n)
            var gw = matmul(xt, z, d, n, classes)
            for i in 0..<gw.count { gw[i] = gw[i] * inv + l2 * w[i] }
            var gb = [Float](repeating: 0, count: classes)
            for i in 0..<n { for c in 0..<classes { gb[c] += z[i * classes + c] * inv } }
            adamW.step(&w, gw)
            adamB.step(&b, gb)
        }
        return Linear(w: Floats(w), b: Floats(b), d: d, classes: classes)
    }

    /// Picks a softmax temperature so probabilities aren't wildly overconfident (LDA tends to be).
    func fitTemperature(x: [Float], y: [Int], n: Int) -> Float {
        let z0 = matmul(x, w.v, n, d, classes)
        var best: Float = 1, bestLoss = Float.infinity
        for t in [1, 2, 4, 8, 16, 32, 64] as [Float] {
            var z = z0
            for i in 0..<n { for c in 0..<classes { z[i * classes + c] = (z[i * classes + c] + b.v[c]) / t } }
            softmaxInPlace(&z, rows: n, cols: classes)
            var loss: Float = 0
            // Training-set fit is optimistic, so also penalise near-certainty a little.
            for i in 0..<n { loss -= log(max(z[i * classes + y[i]], 1e-6)) * 0.9 + log(max(1 - z[i * classes + y[i]], 1e-6)) * 0.02 }
            if loss < bestLoss { bestLoss = loss; best = t }
        }
        return best
    }
}

/// One-hidden-layer neural network (ReLU) trained with Adam, weight decay and input-noise regularisation.
struct MLP: Codable {
    var w1: Floats, b1: Floats, w2: Floats, b2: Floats
    var d: Int, hidden: Int, classes: Int

    func probs(_ q: [Float]) -> [Float] {
        var h = matmul(q, w1.v, 1, d, hidden)
        for j in 0..<hidden { h[j] = max(0, h[j] + b1.v[j]) }
        var z = matmul(h, w2.v, 1, hidden, classes)
        for c in 0..<classes { z[c] += b2.v[c] }
        softmaxInPlace(&z, rows: 1, cols: classes)
        return z
    }

    static func train(x: [Float], y: [Int], n: Int, d: Int, classes: Int, hidden: Int = 48, epochs: Int = 320,
                      l2: Float = 2e-3, inputNoise: Float = 0.35, seed: UInt64) -> MLP {
        var rng = SplitMix(seed: seed)
        let s1 = (2 / Float(d)).squareRoot(), s2 = (2 / Float(hidden)).squareRoot()
        var w1 = (0..<(d * hidden)).map { _ in rng.gaussian() * s1 }, b1 = [Float](repeating: 0.01, count: hidden)
        var w2 = (0..<(hidden * classes)).map { _ in rng.gaussian() * s2 * 0.5 }, b2 = [Float](repeating: 0, count: classes)
        var a1 = Adam(count: w1.count, lr: 0.01), ab1 = Adam(count: hidden, lr: 0.01)
        var a2 = Adam(count: w2.count, lr: 0.01), ab2 = Adam(count: classes, lr: 0.01)
        var noisy = x
        let inv = 1 / Float(n)
        for epoch in 0..<epochs {
            // Uniform noise with the requested standard deviation (cheaper than Gaussian, same effect here).
            let amp = inputNoise * 1.732
            for i in 0..<noisy.count { noisy[i] = x[i] + amp * (Float(rng.next() >> 40) / Float(1 << 24) * 2 - 1) }
            var h = matmul(noisy, w1, n, d, hidden)
            for i in 0..<n { for j in 0..<hidden { h[i * hidden + j] = max(0, h[i * hidden + j] + b1[j]) } }
            var z = matmul(h, w2, n, hidden, classes)
            for i in 0..<n { for c in 0..<classes { z[i * classes + c] += b2[c] } }
            softmaxInPlace(&z, rows: n, cols: classes)
            for i in 0..<n { z[i * classes + y[i]] -= 1 }
            for i in 0..<z.count { z[i] *= inv }
            var gw2 = matmul(transpose(h, n, hidden), z, hidden, n, classes)
            var gb2 = [Float](repeating: 0, count: classes)
            for i in 0..<n { for c in 0..<classes { gb2[c] += z[i * classes + c] } }
            var dh = matmul(z, transpose(w2, hidden, classes), n, classes, hidden)
            for i in 0..<dh.count where h[i] <= 0 { dh[i] = 0 }
            var gw1 = matmul(transpose(noisy, n, d), dh, d, n, hidden)
            var gb1 = [Float](repeating: 0, count: hidden)
            for i in 0..<n { for j in 0..<hidden { gb1[j] += dh[i * hidden + j] } }
            for i in 0..<gw1.count { gw1[i] += l2 * w1[i] }
            for i in 0..<gw2.count { gw2[i] += l2 * w2[i] }
            // Cosine learning-rate decay.
            let lr = 0.01 * (0.55 + 0.45 * cos(Float.pi * Float(epoch) / Float(epochs)))
            a1.lr = lr; ab1.lr = lr; a2.lr = lr; ab2.lr = lr
            a1.step(&w1, gw1); ab1.step(&b1, gb1); a2.step(&w2, gw2); ab2.step(&b2, gb2)
        }
        return MLP(w1: Floats(w1), b1: Floats(b1), w2: Floats(w2), b2: Floats(b2), d: d, hidden: hidden, classes: classes)
    }
}

struct Adam {
    var m: [Float], v: [Float]
    var lr: Float
    var t: Float = 0
    init(count: Int, lr: Float) { m = Array(repeating: 0, count: count); v = m; self.lr = lr }

    mutating func step(_ p: inout [Float], _ g: [Float]) {
        t += 1
        let b1: Float = 0.9, b2: Float = 0.999
        let c1 = 1 - pow(b1, t), c2 = 1 - pow(b2, t)
        for i in 0..<p.count {
            m[i] = b1 * m[i] + (1 - b1) * g[i]
            v[i] = b2 * v[i] + (1 - b2) * g[i] * g[i]
            p[i] -= lr * (m[i] / c1) / ((v[i] / c2).squareRoot() + 1e-7)
        }
    }
}

/// Dense Cholesky factorisation for the LDA solve (d is a few hundred at most).
struct Cholesky {
    var l: [Double]
    let d: Int

    init(_ a: [Double], _ d: Int) {
        self.d = d
        l = [Double](repeating: 0, count: d * d)
        for i in 0..<d {
            for j in 0...i {
                var s = a[i * d + j]
                for k in 0..<j { s -= l[i * d + k] * l[j * d + k] }
                l[i * d + j] = i == j ? max(s, 1e-9).squareRoot() : s / l[j * d + j]
            }
        }
    }

    func solve(_ b: [Double]) -> [Double] {
        var y = b
        for i in 0..<d {
            var s = y[i]
            for k in 0..<i { s -= l[i * d + k] * y[k] }
            y[i] = s / l[i * d + i]
        }
        var x = y
        for i in stride(from: d - 1, through: 0, by: -1) {
            var s = x[i]
            for k in (i + 1)..<d { s -= l[k * d + i] * x[k] }
            x[i] = s / l[i * d + i]
        }
        return x
    }
}

enum ModelKind: String, Codable, CaseIterable, Identifiable {
    case knn, lda, logistic, mlp, ensemble
    var id: String { rawValue }

    var title: String {
        switch self {
        case .knn: "k-Nearest Neighbours"
        case .lda: "Shrinkage LDA"
        case .logistic: "Logistic Regression"
        case .mlp: "Neural Net (MLP ×3)"
        case .ensemble: "Ensemble (all)"
        }
    }
}

/// A trained classifier of one kind (the ensemble averages all the others).
struct Classifier: Codable {
    var kind: ModelKind
    var knn: KNN?
    var lda: Linear?
    var logistic: Linear?
    var mlp: [MLP]?

    static func train(_ kind: ModelKind, x: [Float], y: [Int], n: Int, d: Int, classes: Int, seed: UInt64) -> Classifier {
        var c = Classifier(kind: kind)
        let needs: Set<ModelKind> = kind == .ensemble ? [.knn, .lda, .logistic, .mlp] : [kind]
        if needs.contains(.knn) { c.knn = KNN(x: Floats(x), y: y, d: d, classes: classes) }
        if needs.contains(.lda) { c.lda = .lda(x: x, y: y, n: n, d: d, classes: classes) }
        if needs.contains(.logistic) { c.logistic = .logistic(x: x, y: y, n: n, d: d, classes: classes) }
        if needs.contains(.mlp) {
            c.mlp = (0..<3).map { MLP.train(x: x, y: y, n: n, d: d, classes: classes, seed: seed &+ UInt64($0) &* 7919) }
        }
        return c
    }

    func probs(_ q: [Float]) -> [Float] {
        var parts: [[Float]] = []
        if let knn { parts.append(knn.probs(q)) }
        if let lda { parts.append(lda.probs(q)) }
        if let logistic { parts.append(logistic.probs(q)) }
        if let mlp {
            let each = mlp.map { $0.probs(q) }
            parts.append((0..<each[0].count).map { c in each.reduce(0) { $0 + $1[c] } / Float(each.count) })
        }
        guard let first = parts.first else { return [] }
        return (0..<first.count).map { c in parts.reduce(0) { $0 + $1[c] } / Float(parts.count) }
    }
}
