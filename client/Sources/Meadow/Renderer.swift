import Foundation
import MetalKit
import simd

struct Uniforms {
    var vp: matrix_float4x4
    var cam: SIMD4<Float>
    var sun: SIMD4<Float>
    var camRight: SIMD4<Float>
    var camUp: SIMD4<Float>
    var species: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private var charPipeline: MTLRenderPipelineState!
    private var groundPipeline: MTLRenderPipelineState!
    private var fxPipeline: MTLRenderPipelineState!
    private var skyPipeline: MTLRenderPipelineState!

    private var depthState: MTLDepthStencilState!
    private var fxDepthState: MTLDepthStencilState!
    private var skyDepthState: MTLDepthStencilState!

    private let deerMesh: MTLBuffer
    private let deerCount: Int
    private let wolfMesh: MTLBuffer
    private let wolfCount: Int
    private let bushMesh: MTLBuffer
    private let bushCount: Int
    private let pineMesh: MTLBuffer
    private let pineCount: Int
    private let groundMesh: MTLBuffer
    private let groundCount: Int

    private let pineInstances: MTLBuffer
    private let pineInstanceCount: Int

    private var grassTexture: MTLTexture

    private let world = World()
    private var net: Net!

    private let freeCamera = FreeCamera()
    private weak var input: InputState?
    private var cinematic = false
    private var lastDrawTime: Double = 0

    private var aspect: Float = 16.0 / 9.0

    init(view: MTKView) {
        if let inputView = view as? InputView {
            input = inputView.input
        }
        let dev = view.device!
        device = dev
        queue = dev.makeCommandQueue()!

        func meshBuffer(_ verts: [MeshVertex]) -> MTLBuffer {
            dev.makeBuffer(bytes: verts,
                           length: MemoryLayout<MeshVertex>.stride * verts.count,
                           options: .storageModeShared)!
        }

        let deer = MeshBuilder.deer()
        let wolf = MeshBuilder.wolf()
        let bush = MeshBuilder.bush()
        let pine = MeshBuilder.pine()
        let ground = MeshBuilder.ground()

        deerCount = deer.count
        wolfCount = wolf.count
        bushCount = bush.count
        pineCount = pine.count
        groundCount = ground.count

        deerMesh = meshBuffer(deer)
        wolfMesh = meshBuffer(wolf)
        bushMesh = meshBuffer(bush)
        pineMesh = meshBuffer(pine)
        groundMesh = meshBuffer(ground)

        let pines = Scenery.pines(count: 56)
        pineInstanceCount = pines.count
        pineInstances = dev.makeBuffer(bytes: pines,
                                       length: MemoryLayout<Instance>.stride * max(pines.count, 1),
                                       options: .storageModeShared)!

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 36, height: 24, mipmapped: false)
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .shared
        grassTexture = dev.makeTexture(descriptor: texDesc)!

        super.init()

        buildPipelines(view: view)

        let env = ProcessInfo.processInfo.environment
        let host = env["HOST"] ?? "127.0.0.1"
        let port = Int(env["PORT"] ?? "") ?? 4041
        net = Net(world: world, host: host, port: port)
        net.start()
    }

    private func buildPipelines(view: MTKView) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }

        func pipeline(_ vfn: String, _ ffn: String, blend: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            if blend {
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .sourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        charPipeline = pipeline("v_char", "f_char", blend: false)
        groundPipeline = pipeline("v_ground", "f_ground", blend: false)
        fxPipeline = pipeline("v_fx", "f_fx", blend: true)
        skyPipeline = pipeline("v_sky", "f_sky", blend: false)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        let fd = MTLDepthStencilDescriptor()
        fd.depthCompareFunction = .less
        fd.isDepthWriteEnabled = false
        fxDepthState = device.makeDepthStencilState(descriptor: fd)

        let sd = MTLDepthStencilDescriptor()
        sd.depthCompareFunction = .always
        sd.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: sd)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
    }

    func draw(in view: MTKView) {
        guard world.started else { return }
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastDrawTime > 0 ? Float(min(now - lastDrawTime, 0.1)) : Float(1.0 / 60.0)
        lastDrawTime = now

        let (deer, wolves, bushes, fxVerts) = world.buildFrame()

        if let input, input.toggleCinematic {
            input.toggleCinematic = false
            cinematic.toggle()
        }

        let vp: matrix_float4x4
        let cam: SIMD3<Float>
        let camRight: SIMD3<Float>
        let camUp: SIMD3<Float>

        if cinematic {
            let (m, e) = world.director.matrices(aspect: aspect, now: now)
            vp = m
            cam = e
            camRight = world.director.camRight
            camUp = world.director.camUp
        } else {
            if let input { freeCamera.update(input: input, dt: dt) }
            let r = freeCamera.matrices(aspect: aspect)
            vp = r.vp
            cam = r.eye
            camRight = r.right
            camUp = r.up
        }

        // Update grass texture from the latest frame.
        let g = world.grassSnapshot()
        if g.w == grassTexture.width && g.h == grassTexture.height {
            g.bytes.withUnsafeBytes { raw in
                grassTexture.replace(
                    region: MTLRegionMake2D(0, 0, g.w, g.h),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: g.w)
            }
        }

        var uni = Uniforms(
            vp: vp,
            cam: SIMD4<Float>(cam.x, cam.y, cam.z,
                              Float(CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))),
            sun: SIMD4<Float>(simd_normalize(SIMD3<Float>(0.45, 0.85, 0.3)), 0),
            camRight: SIMD4<Float>(camRight, 0),
            camUp: SIMD4<Float>(camUp, 0),
            species: SIMD4<Float>(0, 0, 0, 0)
        )

        // sky backdrop
        enc.setDepthStencilState(skyDepthState)
        enc.setCullMode(.none)
        enc.setRenderPipelineState(skyPipeline)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setDepthStencilState(depthState)

        // ground with grass texture
        enc.setRenderPipelineState(groundPipeline)
        enc.setVertexBuffer(groundMesh, offset: 0, index: 0)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setFragmentTexture(grassTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundCount)

        // instanced species draws
        enc.setRenderPipelineState(charPipeline)

        drawSpecies(enc, mesh: deerMesh, meshCount: deerCount, instances: deer, speciesId: 0, uni: &uni)
        drawSpecies(enc, mesh: wolfMesh, meshCount: wolfCount, instances: wolves, speciesId: 1, uni: &uni)
        drawSpecies(enc, mesh: bushMesh, meshCount: bushCount, instances: bushes, speciesId: 2, uni: &uni)

        // static pines
        uni.species.x = 3
        enc.setVertexBuffer(pineMesh, offset: 0, index: 0)
        enc.setVertexBuffer(pineInstances, offset: 0, index: 1)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                           vertexCount: pineCount, instanceCount: pineInstanceCount)

        // FX
        if !fxVerts.isEmpty {
            enc.setDepthStencilState(fxDepthState)
            enc.setRenderPipelineState(fxPipeline)
            let buf = device.makeBuffer(bytes: fxVerts,
                                        length: MemoryLayout<FXVertex>.stride * fxVerts.count,
                                        options: .storageModeShared)!
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fxVerts.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func drawSpecies(_ enc: MTLRenderCommandEncoder,
                             mesh: MTLBuffer, meshCount: Int,
                             instances: [Instance], speciesId: Float,
                             uni: inout Uniforms) {
        guard !instances.isEmpty else { return }
        uni.species.x = speciesId
        let buf = device.makeBuffer(bytes: instances,
                                    length: MemoryLayout<Instance>.stride * instances.count,
                                    options: .storageModeShared)!
        enc.setVertexBuffer(mesh, offset: 0, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                           vertexCount: meshCount, instanceCount: instances.count)
    }
}
