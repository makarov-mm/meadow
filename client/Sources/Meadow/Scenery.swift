import Foundation
import simd

/// Client-side decorative scenery. Pines are placed with a seeded generator,
/// so every run looks the same. Pond constants must match the server's
/// Meadow.Const values.
enum Scenery {
    static let fieldX: Float = 140
    static let fieldZ: Float = 90

    static let pondCX: Float = 34
    static let pondCZ: Float = -18
    static let pondRX: Float = 20
    static let pondRZ: Float = 13

    static func pondField(_ x: Float, _ z: Float) -> Float {
        let dx = (x - pondCX) / pondRX
        let dz = (z - pondCZ) / pondRZ
        return dx * dx + dz * dz
    }

    /// Simple deterministic LCG so tree placement is stable across runs.
    private struct LCG {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
    }

    static func pines(count: Int) -> [Instance] {
        var rng = LCG(s: 20260711)
        var out = [Instance]()
        out.reserveCapacity(count)

        var attempts = 0
        while out.count < count && attempts < count * 30 {
            attempts += 1
            let x = (rng.next() - 0.5) * 2 * (fieldX + 40)
            let z = (rng.next() - 0.5) * 2 * (fieldZ + 40)

            let inField = abs(x) < fieldX - 10 && abs(z) < fieldZ - 10
            let nearPond = pondField(x, z) < 2.2
            // keep the central meadow open, allow a sparse few inside
            let central = abs(x) < fieldX * 0.6 && abs(z) < fieldZ * 0.6
            let allowInside = rng.next() < 0.12

            if nearPond { continue }
            if inField && central && !allowInside { continue }

            let scale = 0.8 + rng.next() * 0.9
            let heading = rng.next() * 6.28
            out.append(Instance(
                posHead: SIMD4<Float>(x, 0, z, heading),
                misc: SIMD4<Float>(0, 0, 4, scale)
            ))
        }
        return out
    }
}
