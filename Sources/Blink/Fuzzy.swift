import Foundation

/// A string pre-processed once so each keystroke only does byte comparisons.
struct Searchable {
    let lower: [UInt8]
    let starts: [Bool]  // true where a word begins

    init(_ s: String) {
        let orig = Array(s.utf8)
        let low = Array(s.lowercased().utf8)
        var st = [Bool](repeating: false, count: low.count)
        let same = orig.count == low.count
        for i in 0..<low.count {
            if i == 0 { st[i] = true; continue }
            let p = low[i - 1]
            if p == 32 || p == 45 || p == 95 || p == 46 || p == 47 {
                st[i] = true
            } else if same, orig[i] >= 65, orig[i] <= 90, orig[i - 1] >= 97, orig[i - 1] <= 122 {
                st[i] = true  // camelCase boundary
            }
        }
        lower = low
        starts = st
    }
}

func fuzzyQuery(_ s: String) -> [UInt8] {
    Array(s.lowercased().utf8)
}

/// Subsequence match with bonuses for word starts and consecutive runs.
/// Returns nil when `q` is not a subsequence of the target.
func fuzzyScore(_ q: [UInt8], _ t: Searchable) -> Int? {
    let c = t.lower
    let m = q.count, n = c.count
    if m == 0 { return 0 }
    if m > n { return nil }

    var qi = 0
    for b in c {
        if b == q[qi] {
            qi += 1
            if qi == m { break }
        }
    }
    if qi < m { return nil }

    let neg = Int.min / 2
    let live = neg / 2
    var prev = [Int](repeating: neg, count: n)
    var cur = prev
    for i in 0..<m {
        var gapBest = neg  // best earlier match reached across a gap
        for j in 0..<n {
            if j >= 2 { gapBest = max(gapBest - 1, prev[j - 2] - 3) }
            var v = neg
            if c[j] == q[i] {
                let bonus = 10 + (t.starts[j] ? 30 : 0)
                if i == 0 {
                    v = bonus + (j == 0 ? 20 : 0) - min(j, 10)
                } else {
                    var best = gapBest
                    if j >= 1, prev[j - 1] > live { best = max(best, prev[j - 1] + 25) }
                    if best > live { v = best + bonus }
                }
            }
            cur[j] = v
        }
        swap(&prev, &cur)
    }
    guard let best = prev.max(), best > live else { return nil }
    var score = best - (n - m) / 2
    if c.starts(with: q) { score += (n == m) ? 100 : 50 }
    return score
}
