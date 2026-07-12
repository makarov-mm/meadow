import Foundation
import simd

struct Track {
    var id: UInt16
    var species: UInt8
    var state: UInt8
    var scale: Float

    var prevX: Float
    var prevZ: Float
    var prevHeading: Float

    var nextX: Float
    var nextZ: Float
    var nextHeading: Float

    var animPhase: Float
    var stateStart: Double
}

struct FX {
    var kind: Int      // 0 kill puff, 1 birth ring, 2 starve puff, 3 berry sparkle
    var x: Float
    var z: Float
    var born: Double
    var life: Float
}

/// Holds interpolated world state. Written by Net (background), read by
/// Renderer (main). The roster is dynamic: animals are born and die, so
/// tracks are created and pruned as ids appear and vanish.
final class World {
    private let lock = NSLock()

    private var tracks = [UInt16: Track]()
    private var fx = [FX]()

    private(set) var grassW = 36
    private(set) var grassH = 24
    private var grassBytes = [UInt8](repeating: 200, count: 36 * 24)

    private var lastFrameAt: Double = 0
    private var interval: Double = 0.05
    private(set) var started = false

    let director = CameraDirector()

    private func now() -> Double { CFAbsoluteTimeGetCurrent() }

    func ingest(_ frame: Frame) {
        lock.lock()
        defer { lock.unlock() }

        let t = now()
        if lastFrameAt > 0 {
            let dt = t - lastFrameAt
            if dt > 0.005 && dt < 0.5 {
                interval = interval * 0.9 + dt * 0.1
            }
        }
        lastFrameAt = t
        started = true

        grassW = frame.grassW
        grassH = frame.grassH
        grassBytes = frame.grass

        var seen = Set<UInt16>()
        seen.reserveCapacity(frame.agents.count)

        for a in frame.agents {
            seen.insert(a.id)
            if var tr = tracks[a.id] {
                tr.prevX = tr.nextX
                tr.prevZ = tr.nextZ
                tr.prevHeading = tr.nextHeading

                let jump = hypot(a.x - tr.nextX, a.z - tr.nextZ)
                if jump > 8.0 {
                    tr.prevX = a.x
                    tr.prevZ = a.z
                    tr.prevHeading = a.heading
                }

                tr.nextX = a.x
                tr.nextZ = a.z
                tr.nextHeading = a.heading

                let moved = hypot(tr.nextX - tr.prevX, tr.nextZ - tr.prevZ)
                tr.animPhase += moved * 2.6

                if a.state != tr.state {
                    tr.state = a.state
                    tr.stateStart = t
                }
                tr.scale = a.scale
                tracks[a.id] = tr
            } else {
                tracks[a.id] = Track(
                    id: a.id, species: a.species, state: a.state, scale: a.scale,
                    prevX: a.x, prevZ: a.z, prevHeading: a.heading,
                    nextX: a.x, nextZ: a.z, nextHeading: a.heading,
                    animPhase: Float.random(in: 0...6), stateStart: t
                )
            }
        }

        // Dynamic roster: prune tracks whose ids vanished from the stream.
        if tracks.count != seen.count {
            for key in tracks.keys where !seen.contains(key) {
                tracks.removeValue(forKey: key)
            }
        }

        for e in frame.events {
            spawnFX(e, at: t)
            director.feed(e)
        }

        fx.removeAll { Float(t - $0.born) > $0.life }
    }

    private func spawnFX(_ e: EventWire, at t: Double) {
        switch e.type {
        case 0: fx.append(FX(kind: 0, x: e.x, z: e.z, born: t, life: 0.8))
        case 1: fx.append(FX(kind: 1, x: e.x, z: e.z, born: t, life: 1.2))
        case 2: fx.append(FX(kind: 2, x: e.x, z: e.z, born: t, life: 1.0))
        case 3: fx.append(FX(kind: 3, x: e.x, z: e.z, born: t, life: 0.6))
        default: break
        }
    }

    func grassSnapshot() -> (w: Int, h: Int, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        return (grassW, grassH, grassBytes)
    }

    /// Per-frame sample: instances split by mesh kind plus FX verts. Camera
    /// matrices are the renderer's business; World only feeds the director
    /// with heat (in ingest) and the crowd centroid (here).
    func buildFrame() -> (deer: [Instance], wolves: [Instance], bushes: [Instance],
                          fxVerts: [FXVertex]) {
        lock.lock()
        let localTracks = tracks
        let localFX = fx
        let iv = interval
        let last = lastFrameAt
        lock.unlock()

        let t = now()
        let raw = iv > 0 ? Float((t - last) / iv) : 0
        let alpha = min(max(raw, 0), 1.25)

        var deer = [Instance]()
        var wolves = [Instance]()
        var bushes = [Instance]()
        deer.reserveCapacity(localTracks.count)

        var cx: Float = 0, cz: Float = 0, alive: Float = 0

        for (_, tr) in localTracks {
            let x = lerpF(tr.prevX, tr.nextX, alpha)
            let z = lerpF(tr.prevZ, tr.nextZ, alpha)
            let h = lerpAngle(tr.prevHeading, tr.nextHeading, alpha)

            if tr.species != 2 && tr.state != 3 {
                cx += x; cz += z; alive += 1
            }

            let stateTime = Float(t - tr.stateStart)
            let inst = Instance(
                posHead: SIMD4<Float>(x, 0, z, h),
                misc: SIMD4<Float>(tr.animPhase, stateTime, Float(tr.state), tr.scale)
            )

            switch tr.species {
            case 0: deer.append(inst)
            case 1: wolves.append(inst)
            default: bushes.append(inst)
            }
        }

        if alive > 0 {
            director.setCrowd(SIMD3<Float>(cx / alive, 0, cz / alive))
        }

        var fxVerts = [FXVertex]()
        buildFXVerts(localFX, at: t, into: &fxVerts)

        return (deer, wolves, bushes, fxVerts)
    }

    private func buildFXVerts(_ list: [FX], at t: Double, into out: inout [FXVertex]) {
        for f in list {
            let age = Float(t - f.born)
            let u = min(max(age / max(f.life, 0.0001), 0), 1)

            switch f.kind {
            case 0: // kill: red puff, quick rise
                addBillboard(kind: 0, x: f.x, y: 1.0 + u * 0.8, z: f.z,
                             size: 0.9 + u * 1.4, u: u, into: &out)
            case 1: // birth: soft expanding ring near the ground
                addBillboard(kind: 1, x: f.x, y: 0.7, z: f.z,
                             size: 0.5 + u * 2.2, u: u, into: &out)
            case 2: // starvation: gray puff
                addBillboard(kind: 2, x: f.x, y: 0.9 + u * 0.6, z: f.z,
                             size: 0.8 + u * 1.0, u: u, into: &out)
            case 3: // berry: tiny sparkle
                addBillboard(kind: 3, x: f.x, y: 1.4 + u * 0.7, z: f.z,
                             size: 0.5, u: u, into: &out)
            default:
                break
            }
        }
    }

    private func addBillboard(kind: Int, x: Float, y: Float, z: Float, size: Float,
                              u: Float, into out: inout [FXVertex]) {
        let center = SIMD3<Float>(x, y, z)
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, -1), (1, 1), (-1, 1)]
        for (cxx, cyy) in corners {
            out.append(FXVertex(
                center: center,
                corner: SIMD2<Float>(cxx, cyy),
                data: SIMD4<Float>(Float(kind), u, 0, size)
            ))
        }
    }
}

@inline(__always) func lerpF(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

@inline(__always) func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return a + d * t
}
