import Foundation

/// Shared by iPhone and Mac. The input is linear -20...+3 VU; the printed
/// analog-style scale expands the region around 0 VU. 0 VU = -18 dBFS RMS.
enum PastelVUMeterScale {
    static let referenceDBFS = -18.0
    static let marks: [(vu: Int, position: Double)] = [
        (-20, 0), (-10, 0.12), (-7, 0.24), (-5, 0.35), (-3, 0.45),
        (-2, 0.55), (-1, 0.65), (0, 0.73), (1, 0.82), (2, 0.91), (3, 1)
    ]
    static let secondaryMarks = [-20, -10, -5, 0]
    static func normalizedValue(rmsDBFS: Double) -> Double {
        guard rmsDBFS.isFinite else { return 0 }
        return min(1, max(0, (rmsDBFS - referenceDBFS + 20) / 23))
    }
    static func position(forLevel value: Double) -> Double {
        let level = value.isFinite ? min(1, max(0, value)) : 0
        let vu = level * 23 - 20
        for (a, b) in zip(marks, marks.dropFirst()) where vu <= Double(b.vu) {
            return a.position + (b.position - a.position) * (vu - Double(a.vu)) / Double(b.vu - a.vu)
        }
        return 1
    }
}
