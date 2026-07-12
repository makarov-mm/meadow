import Foundation
import simd

/// Vertex layout shared with the shader, read manually by vertex_id.
/// 32 bytes: packed_float3 pos + packed_float3 nrm + float part + float pad.
struct MeshVertex {
    var px: Float; var py: Float; var pz: Float
    var nx: Float; var ny: Float; var nz: Float
    var part: Float
    var pad: Float
}

struct Instance {
    var posHead: SIMD4<Float>  // x, y, z, heading
    var misc: SIMD4<Float>     // animPhase, stateTime, state, scale
}

struct FXVertex {
    var center: SIMD3<Float>
    var corner: SIMD2<Float>
    var data: SIMD4<Float>     // kind, age 0..1, unused, size
}

/// Part ids used by the animation shader:
///   0 body, 1 head and neck, 2 leg FL, 3 leg FR, 4 leg BL, 5 leg BR,
///   6 tail, 7 antlers or ears,
///   10 bush foliage, 11 berries, 12 trunk, 13 pine foliage, 100 ground.
/// Local model space: forward = +X, up = +Y, lateral = Z.
enum MeshBuilder {
    static func deer() -> [MeshVertex] {
        var v = [MeshVertex]()
        // body
        box(&v, cx: 0, cy: 1.05, cz: 0, sx: 1.25, sy: 0.55, sz: 0.5, part: 0)
        // neck, slightly raised toward the front
        box(&v, cx: 0.62, cy: 1.35, cz: 0, sx: 0.3, sy: 0.55, sz: 0.24, part: 1)
        // head
        box(&v, cx: 0.85, cy: 1.62, cz: 0, sx: 0.42, sy: 0.26, sz: 0.24, part: 1)
        // ears
        box(&v, cx: 0.72, cy: 1.82, cz: -0.12, sx: 0.08, sy: 0.18, sz: 0.06, part: 7)
        box(&v, cx: 0.72, cy: 1.82, cz: 0.12, sx: 0.08, sy: 0.18, sz: 0.06, part: 7)
        // legs
        box(&v, cx: 0.45, cy: 0.4, cz: -0.16, sx: 0.13, sy: 0.8, sz: 0.13, part: 2)
        box(&v, cx: 0.45, cy: 0.4, cz: 0.16, sx: 0.13, sy: 0.8, sz: 0.13, part: 3)
        box(&v, cx: -0.45, cy: 0.4, cz: -0.16, sx: 0.13, sy: 0.8, sz: 0.13, part: 4)
        box(&v, cx: -0.45, cy: 0.4, cz: 0.16, sx: 0.13, sy: 0.8, sz: 0.13, part: 5)
        // tail
        box(&v, cx: -0.66, cy: 1.2, cz: 0, sx: 0.14, sy: 0.14, sz: 0.1, part: 6)
        return v
    }

    static func wolf() -> [MeshVertex] {
        var v = [MeshVertex]()
        // body, lower and longer than the deer
        box(&v, cx: 0, cy: 0.72, cz: 0, sx: 1.3, sy: 0.42, sz: 0.4, part: 0)
        // neck and head, thrust forward
        box(&v, cx: 0.66, cy: 0.85, cz: 0, sx: 0.28, sy: 0.32, sz: 0.26, part: 1)
        box(&v, cx: 0.95, cy: 0.88, cz: 0, sx: 0.42, sy: 0.24, sz: 0.22, part: 1)
        // ears
        box(&v, cx: 0.8, cy: 1.06, cz: -0.09, sx: 0.07, sy: 0.14, sz: 0.05, part: 7)
        box(&v, cx: 0.8, cy: 1.06, cz: 0.09, sx: 0.07, sy: 0.14, sz: 0.05, part: 7)
        // legs
        box(&v, cx: 0.48, cy: 0.28, cz: -0.14, sx: 0.11, sy: 0.56, sz: 0.11, part: 2)
        box(&v, cx: 0.48, cy: 0.28, cz: 0.14, sx: 0.11, sy: 0.56, sz: 0.11, part: 3)
        box(&v, cx: -0.48, cy: 0.28, cz: -0.14, sx: 0.11, sy: 0.56, sz: 0.11, part: 4)
        box(&v, cx: -0.48, cy: 0.28, cz: 0.14, sx: 0.11, sy: 0.56, sz: 0.11, part: 5)
        // tail, straight back
        box(&v, cx: -0.78, cy: 0.78, cz: 0, sx: 0.4, sy: 0.12, sz: 0.1, part: 6)
        return v
    }

    static func bush() -> [MeshVertex] {
        var v = [MeshVertex]()
        // foliage: a cluster of overlapping boxes
        box(&v, cx: 0, cy: 0.6, cz: 0, sx: 1.5, sy: 1.1, sz: 1.5, part: 10)
        box(&v, cx: 0.5, cy: 0.9, cz: 0.3, sx: 0.9, sy: 0.8, sz: 0.9, part: 10)
        box(&v, cx: -0.45, cy: 0.85, cz: -0.25, sx: 0.9, sy: 0.75, sz: 0.9, part: 10)
        // berries: small cubes on the surface, scaled by berry fill in shader
        let spots: [(Float, Float, Float)] = [
            (0.7, 0.9, 0.4), (-0.6, 1.0, 0.3), (0.2, 1.25, -0.5),
            (-0.3, 0.7, 0.7), (0.55, 0.6, -0.6), (0.0, 1.1, 0.75)
        ]
        for (bx, by, bz) in spots {
            box(&v, cx: bx, cy: by, cz: bz, sx: 0.16, sy: 0.16, sz: 0.16, part: 11)
        }
        return v
    }

    static func pine() -> [MeshVertex] {
        var v = [MeshVertex]()
        box(&v, cx: 0, cy: 0.8, cz: 0, sx: 0.34, sy: 1.6, sz: 0.34, part: 12)
        // three stacked foliage tiers
        box(&v, cx: 0, cy: 2.0, cz: 0, sx: 2.2, sy: 1.0, sz: 2.2, part: 13)
        box(&v, cx: 0, cy: 2.9, cz: 0, sx: 1.6, sy: 0.9, sz: 1.6, part: 13)
        box(&v, cx: 0, cy: 3.7, cz: 0, sx: 1.0, sy: 0.8, sz: 1.0, part: 13)
        return v
    }

    static func ground() -> [MeshVertex] {
        var v = [MeshVertex]()
        let hx: Float = 320, hz: Float = 220
        let n = SIMD3<Float>(0, 1, 0)
        func p(_ x: Float, _ z: Float) -> MeshVertex {
            MeshVertex(px: x, py: 0, pz: z, nx: n.x, ny: n.y, nz: n.z, part: 100, pad: 0)
        }
        v.append(p(-hx, -hz)); v.append(p(hx, -hz)); v.append(p(hx, hz))
        v.append(p(-hx, -hz)); v.append(p(hx, hz)); v.append(p(-hx, hz))
        return v
    }

    private static func box(_ out: inout [MeshVertex],
                            cx: Float, cy: Float, cz: Float,
                            sx: Float, sy: Float, sz: Float, part: Float) {
        let hx = sx / 2, hy = sy / 2, hz = sz / 2
        let c = [
            SIMD3<Float>(-hx, -hy, -hz), SIMD3<Float>(hx, -hy, -hz),
            SIMD3<Float>(hx, hy, -hz),   SIMD3<Float>(-hx, hy, -hz),
            SIMD3<Float>(-hx, -hy, hz),  SIMD3<Float>(hx, -hy, hz),
            SIMD3<Float>(hx, hy, hz),    SIMD3<Float>(-hx, hy, hz)
        ].map { $0 + SIMD3<Float>(cx, cy, cz) }

        let faces: [([Int], SIMD3<Float>)] = [
            ([0, 1, 2, 3], SIMD3<Float>(0, 0, -1)),
            ([5, 4, 7, 6], SIMD3<Float>(0, 0, 1)),
            ([4, 0, 3, 7], SIMD3<Float>(-1, 0, 0)),
            ([1, 5, 6, 2], SIMD3<Float>(1, 0, 0)),
            ([3, 2, 6, 7], SIMD3<Float>(0, 1, 0)),
            ([4, 5, 1, 0], SIMD3<Float>(0, -1, 0))
        ]
        for (idx, n) in faces {
            let quad = [c[idx[0]], c[idx[1]], c[idx[2]], c[idx[3]]]
            let tri = [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]]
            for p in tri {
                out.append(MeshVertex(px: p.x, py: p.y, pz: p.z,
                                      nx: n.x, ny: n.y, nz: n.z, part: part, pad: 0))
            }
        }
    }
}
