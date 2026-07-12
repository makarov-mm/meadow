import AppKit
import MetalKit
import simd

/// Shared input state written by the view on the main thread and consumed by
/// the renderer, also on the main thread (MTKView draws on the main runloop).
final class InputState {
    var keys = Set<UInt16>()
    var yawDelta: Float = 0
    var pitchDelta: Float = 0
    var zoomDelta: Float = 0
    var toggleCinematic = false

    func consumeDeltas() -> (yaw: Float, pitch: Float, zoom: Float) {
        defer { yawDelta = 0; pitchDelta = 0; zoomDelta = 0 }
        return (yawDelta, pitchDelta, zoomDelta)
    }
}

/// MTKView subclass that captures keyboard and mouse input.
final class InputView: MTKView {
    let input = InputState()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 8 { // C: toggle cinematic camera
            if !event.isARepeat { input.toggleCinematic = true }
            return
        }
        input.keys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        input.keys.remove(event.keyCode)
    }

    override func scrollWheel(with event: NSEvent) {
        input.zoomDelta += Float(event.scrollingDeltaY)
    }

    override func mouseDragged(with event: NSEvent) {
        input.yawDelta += Float(event.deltaX)
        input.pitchDelta += Float(event.deltaY)
    }

    override func rightMouseDragged(with event: NSEvent) {
        input.yawDelta += Float(event.deltaX)
        input.pitchDelta += Float(event.deltaY)
    }
}

/// Manual observer camera. Hovers over the meadow at a fixed tilt; WASD or
/// arrow keys pan the focus point across the field, mouse drag rotates and
/// tilts, the scroll wheel zooms. Pan direction follows the current view
/// heading, and pan speed scales with zoom so travel feels constant.
final class FreeCamera {
    private var focus = SIMD2<Float>(0, 0)
    private var yaw: Float = -.pi / 2
    private var pitch: Float = 0.9        // radians above horizontal
    private var dist: Float = 75

    private let fieldX: Float = Scenery.fieldX + 20
    private let fieldZ: Float = Scenery.fieldZ + 20

    // macOS virtual key codes (layout independent):
    // W 13, A 0, S 1, D 2, Q 12, E 14, arrows 123-126.
    func update(input: InputState, dt: Float) {
        let d = input.consumeDeltas()
        yaw += d.yaw * 0.006
        pitch = min(max(pitch - d.pitch * 0.004, 0.35), 1.35)
        dist = min(max(dist * (1.0 - d.zoom * 0.015), 14), 190)

        var move = SIMD2<Float>(0, 0)
        let k = input.keys
        if k.contains(13) || k.contains(126) { move.x += 1 }  // W / up
        if k.contains(1) || k.contains(125) { move.x -= 1 }   // S / down
        if k.contains(0) || k.contains(123) { move.y -= 1 }   // A / left
        if k.contains(2) || k.contains(124) { move.y += 1 }   // D / right
        if k.contains(12) { yaw -= 1.4 * dt }                 // Q rotate
        if k.contains(14) { yaw += 1.4 * dt }                 // E rotate

        if move != .zero {
            let fwd = SIMD2<Float>(cos(yaw), sin(yaw))
            let right = SIMD2<Float>(-fwd.y, fwd.x)
            let dir = simd_normalize(fwd * move.x + right * move.y)
            let speed = dist * 0.75 + 8
            focus += dir * speed * dt
            focus.x = min(max(focus.x, -fieldX), fieldX)
            focus.y = min(max(focus.y, -fieldZ), fieldZ)
        }
    }

    func matrices(aspect: Float) -> (vp: matrix_float4x4, eye: SIMD3<Float>,
                                     right: SIMD3<Float>, up: SIMD3<Float>) {
        let cp = cos(pitch), sp = sin(pitch)
        let eye = SIMD3<Float>(
            focus.x - cos(yaw) * cp * dist,
            sp * dist + 1.5,
            focus.y - sin(yaw) * cp * dist
        )
        let look = SIMD3<Float>(focus.x, 0.8, focus.y)

        let upW = SIMD3<Float>(0, 1, 0)
        let view = lookAt(eye: eye, center: look, up: upW)
        let proj = perspective(fovyRadians: 56 * Float.pi / 180, aspect: aspect,
                               near: 0.5, far: 700)

        let f = simd_normalize(look - eye)
        let right = simd_normalize(simd_cross(f, upW))
        let up = simd_cross(right, f)

        return (proj * view, eye, right, up)
    }
}
