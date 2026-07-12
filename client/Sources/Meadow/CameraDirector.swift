import Foundation
import simd

/// Heat-driven cinematic camera. Kills and hunts deposit the most heat, so
/// the camera gravitates toward chases. When the meadow is calm it frames the
/// centroid of the animals and just watches the herds.
final class CameraDirector {
    private struct Heat {
        var x: Float
        var z: Float
        var w: Float
        var born: Double
    }

    private enum Shot {
        case orbit(radius: Float, height: Float, speed: Float, phase0: Float)
        case flyover(height: Float, dir: SIMD2<Float>, span: Float)
        case lowTrack(height: Float, offset: Float, dir: SIMD2<Float>, span: Float)
        case crane(radius: Float, phase0: Float)
    }

    private let lock = NSLock()
    private var heat = [Heat]()

    private var crowd = SIMD3<Float>(0, 0, 0)
    private var haveCrowd = false

    private var shot: Shot = .orbit(radius: 40, height: 26, speed: 0.12, phase0: 0)
    private var shotStart: Double = 0
    private var shotDuration: Double = 9

    private var eye = SIMD3<Float>(0, 50, 60)
    private var look = SIMD3<Float>(0, 0, 0)
    private var poi = SIMD3<Float>(0, 0, 0)
    private var inited = false
    private var hardCut = false

    private let decay: Float = 3.0
    private let window: Double = 6.0

    private(set) var camRight = SIMD3<Float>(1, 0, 0)
    private(set) var camUp = SIMD3<Float>(0, 1, 0)

    func setCrowd(_ c: SIMD3<Float>) {
        lock.lock()
        crowd = c
        haveCrowd = true
        lock.unlock()
    }

    func feed(_ e: EventWire) {
        let w: Float
        switch e.type {
        case 0: w = 6.0        // kill
        case 4: w = 3.0        // hunt started
        case 1: w = 1.5        // birth
        case 2: w = 1.5        // starvation
        case 3: w = 0.3        // berry
        default: return
        }
        lock.lock()
        heat.append(Heat(x: e.x, z: e.z, w: w, born: CFAbsoluteTimeGetCurrent()))
        lock.unlock()
    }

    private func computePOI(now: Double) -> SIMD3<Float> {
        lock.lock()
        heat.removeAll { now - $0.born > window }
        let snapshot = heat
        let mass = crowd
        let haveMass = haveCrowd
        lock.unlock()

        var sx: Float = 0, sz: Float = 0, sw: Float = 0
        for h in snapshot {
            let age = Float(now - h.born)
            let w = h.w * expf(-age / decay)
            sx += h.x * w
            sz += h.z * w
            sw += w
        }

        if sw < 0.5 {
            return haveMass ? mass : poi
        }

        let hot = SIMD3<Float>(sx / sw, 0, sz / sw)
        return haveMass ? simd_mix(hot, mass, SIMD3<Float>(repeating: 0.30)) : hot
    }

    private func pickShot(now: Double) {
        let ang = Float.random(in: 0...(2 * Float.pi))
        let dir = SIMD2<Float>(cos(ang), sin(ang))

        let choices: [Shot] = [
            .orbit(radius: .random(in: 28...50),
                   height: .random(in: 22...40),
                   speed: [Float]([-1, 1]).randomElement()! * .random(in: 0.06...0.15),
                   phase0: .random(in: 0...(2 * Float.pi))),
            .flyover(height: .random(in: 30...48), dir: dir, span: 55),
            .lowTrack(height: .random(in: 12...20),
                      offset: .random(in: 18...28),
                      dir: dir, span: 40),
            .crane(radius: .random(in: 24...38), phase0: .random(in: 0...(2 * Float.pi)))
        ]
        shot = choices.randomElement()!
        shotStart = now
        shotDuration = .random(in: 7...12)
    }

    func matrices(aspect: Float, now: Double) -> (matrix_float4x4, SIMD3<Float>) {
        if !inited {
            shotStart = now
            inited = true
            lock.lock(); let c = crowd; let have = haveCrowd; lock.unlock()
            if have {
                poi = c
                look = c
                eye = c + SIMD3<Float>(0, 48, 48)
            }
        }
        if now - shotStart > shotDuration {
            let smooth = Double.random(in: 0...1) < 0.3
            pickShot(now: now)
            if !smooth { hardCut = true }
        }

        let target = computePOI(now: now)
        poi = simd_mix(poi, target, SIMD3<Float>(repeating: 0.04))
        if !isFinite(poi) { poi = isFinite(target) ? target : SIMD3<Float>(0, 0, 0) }

        let tShot = Float(now - shotStart)
        var desiredEye = eye
        var desiredLook = poi
        desiredLook.y = 0.8

        switch shot {
        case let .orbit(radius, height, speed, phase0):
            let a = phase0 + tShot * speed * 2 * .pi
            desiredEye = poi + SIMD3<Float>(cos(a) * radius, height, sin(a) * radius)

        case let .flyover(height, dir, span):
            let p = (tShot / Float(shotDuration)) * 2 - 1
            let dir3 = SIMD3<Float>(dir.x, 0, dir.y)
            desiredEye = poi + dir3 * (p * span) + SIMD3<Float>(0, height, 0)

        case let .lowTrack(height, offset, dir, span):
            let p = (tShot / Float(shotDuration)) * 2 - 1
            let along = SIMD3<Float>(dir.x, 0, dir.y)
            let side = SIMD3<Float>(-dir.y, 0, dir.x)
            desiredEye = poi + along * (p * span) + side * offset + SIMD3<Float>(0, height, 0)
            desiredLook.y = 1.2

        case let .crane(radius, phase0):
            let f = tShot / Float(shotDuration)
            let h = lerpF(42, 16, smoothstep(0, 1, f))
            let a = phase0 + f * 1.1
            desiredEye = poi + SIMD3<Float>(cos(a) * radius, h, sin(a) * radius)
        }

        // Never look straight down: a vertical view makes lookAt degenerate.
        var offX = desiredEye.x - poi.x
        var offZ = desiredEye.z - poi.z
        var horiz = sqrt(offX * offX + offZ * offZ)
        if horiz < 10 {
            let a = (horiz > 0.001) ? (offX / horiz) : 1.0
            let b = (horiz > 0.001) ? (offZ / horiz) : 0.0
            horiz = 10
            offX = a * horiz
            offZ = b * horiz
            desiredEye.x = poi.x + offX
            desiredEye.z = poi.z + offZ
        }
        // Downward pitch: horizon stays near the top of the frame.
        desiredEye.y = max(desiredEye.y, horiz * 0.55 + 5)

        if hardCut {
            eye = desiredEye
            look = desiredLook
            hardCut = false
        } else {
            let k: Float = 4.5 * (1.0 / 60.0)
            eye = simd_mix(eye, desiredEye, SIMD3<Float>(repeating: k))
            look = simd_mix(look, desiredLook, SIMD3<Float>(repeating: k))
        }

        // NaN can otherwise stick forever through the smoothing mix.
        if !isFinite(eye) { eye = desiredEye }
        if !isFinite(look) { look = desiredLook }
        if !isFinite(eye) { eye = SIMD3<Float>(0, 45, 45) }
        if !isFinite(look) { look = SIMD3<Float>(0, 0, 0) }
        eye.y = max(eye.y, 2.5)
        if simd_length(eye - look) < 1.0 {
            eye = look + SIMD3<Float>(0, 30, 30)
        }

        let upW = SIMD3<Float>(0, 1, 0)
        let view = lookAt(eye: eye, center: look, up: upW)
        let proj = perspective(fovyRadians: 56 * Float.pi / 180, aspect: aspect, near: 0.5, far: 700)

        let f = simd_normalize(look - eye)
        camRight = simd_normalize(simd_cross(f, upW))
        camUp = simd_cross(camRight, f)

        return (proj * view, eye)
    }

    private func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}

// MARK: - Math

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
    let f = simd_normalize(center - eye)
    var upRef = up
    if abs(simd_dot(f, up)) > 0.999 {
        upRef = SIMD3<Float>(0, 0, 1)
    }
    let s = simd_normalize(simd_cross(f, upRef))
    let u = simd_cross(s, f)
    return matrix_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

/// Right-handed projection matching the right-handed lookAt above, mapping
/// z_view = -near to 0 and z_view = -far to 1 (Metal NDC depth). Mixing
/// handedness between the two matrices silently culls everything in front of
/// the camera; that bug cost a whole debugging session in a previous project.
func perspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let y = 1 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let zs = far / (near - far)
    return matrix_float4x4(columns: (
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, near * zs, 0)
    ))
}
