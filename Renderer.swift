import Metal
import MetalKit

enum Test {
	case fsTriangle
	case fsQuadStrip
	case fsQuadTwoDraws
}

extension MTLRenderCommandEncoder {
	func setVertexBytes<T>(_ buffer: [T], index: Int) {
		buffer.withUnsafeBytes {
			setVertexBytes($0.baseAddress!, length: $0.count, index: index)
		}
	}

	func setFragmentBytes<T>(_ buffer: [T], index: Int) {
		buffer.withUnsafeBytes {
			setFragmentBytes($0.baseAddress!, length: $0.count, index: index)
		}
	}
}

class Renderer : NSObject, MTKViewDelegate {
	struct Config {
		var live: Bool
		var flip: Bool
		var depth: Bool
		var drawTime: Float
		var testSize: (x: Int, y: Int)
		var tests: [Test]

		static var fromEnv: Config {
			var config = Renderer.Config(live: false, flip: false, depth: false, drawTime: 20, testSize: (x: 1920, y: 1080), tests: [.fsTriangle, .fsQuadStrip])
			if let env = getenv("LIVE"), env[0] == UInt8(ascii: "1") || env[0] == UInt8(ascii: "y") || env[0] == UInt8(ascii: "Y") {
				config.live = true
			}
			if let env = getenv("FLIP"), env[0] == UInt8(ascii: "1") || env[0] == UInt8(ascii: "y") || env[0] == UInt8(ascii: "Y") {
				config.flip = true
			}
			if let env = getenv("DEPTH"), env[0] == UInt8(ascii: "1") || env[0] == UInt8(ascii: "y") || env[0] == UInt8(ascii: "Y") {
				config.depth = true
			}
			if let env = getenv("TIME"), let time = .some(atof(env)), time > 0 {
				config.drawTime = Float(time)
			}
			if let env = getenv("WIDTH"), let width = .some(atoi(env)), width > 0 {
				config.testSize.x = Int(width)
			}
			if let env = getenv("HEIGHT"), let height = .some(atoi(env)), height > 0 {
				config.testSize.y = Int(height)
			}
			if let env = getenv("TESTS") {
				let tests = String(cString: env).split(separator: ",").compactMap { testStr -> Test? in
					switch testStr.lowercased().filter({ $0.isLetter || $0.isNumber }) {
					case "0", "fstriangle":
						return .fsTriangle
					case "1", "quadstrip", "quad":
						return .fsQuadStrip
					case "2", "quadmulti", "quad2draws":
						return .fsQuadTwoDraws
					default:
						print("Unrecognized test \(testStr)")
						return nil
					}
				}
				if !tests.isEmpty {
					config.tests = tests
				}
			}
			return config
		}
	}

	let gpu: MTLDevice
	let config: Config
	let recordTextures: [MTLTexture]
	let replayTextures: [MTLTexture]
	let atomic: MTLBuffer
	let barrier0: MTLFence
	let barrier1: MTLFence
	let recordPipe: MTLRenderPipelineState
	let replayPipe: MTLRenderPipelineState
	let outputPipe: MTLRenderPipelineState
	let queue: MTLCommandQueue
	let recordRPDesc: MTLRenderPassDescriptor
	let replayRPDesc: MTLRenderPassDescriptor
	let dss: MTLDepthStencilState
	let startTime: Date

	init(_ gpu: MTLDevice, config: Config, drawableFmt: MTLPixelFormat) {
		self.gpu = gpu
		self.config = config
		barrier0 = gpu.makeFence()!
		barrier1 = gpu.makeFence()!
		queue = gpu.makeCommandQueue()!
		recordRPDesc = MTLRenderPassDescriptor()
		if config.depth {
			recordRPDesc.depthAttachment.loadAction = .clear
			recordRPDesc.depthAttachment.clearDepth = 0x1p-32 // In case there's any special cases for 0 depth
			recordRPDesc.depthAttachment.storeAction = .store
		} else {
			recordRPDesc.colorAttachments[0].loadAction = .clear
			recordRPDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
			recordRPDesc.colorAttachments[0].storeAction = .store
		}
		replayRPDesc = MTLRenderPassDescriptor()
		replayRPDesc.colorAttachments[0].loadAction = .clear
		replayRPDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
		replayRPDesc.colorAttachments[0].storeAction = .store

		let dssdesc = MTLDepthStencilDescriptor()
		dssdesc.depthCompareFunction = .greater
		dssdesc.isDepthWriteEnabled = true
		dss = gpu.makeDepthStencilState(descriptor: dssdesc)!

		let tdesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .rgba8Unorm,
			width: config.testSize.x,
			height: config.testSize.y,
			mipmapped: false
		)
		tdesc.usage = [.renderTarget, .shaderRead]
		tdesc.storageMode = .private
		replayTextures = config.tests.map { _ in gpu.makeTexture(descriptor: tdesc)! }
		if (config.depth) { tdesc.pixelFormat = .depth32Float }
		recordTextures = config.tests.map { _ in gpu.makeTexture(descriptor: tdesc)! }
		atomic = gpu.makeBuffer(length: 4 * config.tests.count, options: [.storageModePrivate, .hazardTrackingModeUntracked])!

		let lib = gpu.makeDefaultLibrary()!
		let rpdesc = MTLRenderPipelineDescriptor()
		rpdesc.vertexFunction = lib.makeFunction(name: "vs")!
		if config.depth {
			rpdesc.colorAttachments[0].pixelFormat = .invalid
			rpdesc.depthAttachmentPixelFormat = .depth32Float
			rpdesc.fragmentFunction = lib.makeFunction(name: "fs_record_depth")!
		} else {
			rpdesc.colorAttachments[0].pixelFormat = .rgba8Unorm
			rpdesc.fragmentFunction = lib.makeFunction(name: "fs_record")!
		}
		recordPipe = try! gpu.makeRenderPipelineState(descriptor: rpdesc)
		rpdesc.colorAttachments[0].pixelFormat = .rgba8Unorm
		rpdesc.depthAttachmentPixelFormat = .invalid
		rpdesc.vertexFunction = lib.makeFunction(name: "vs_fullscreen")!
		rpdesc.fragmentFunction = lib.makeFunction(name: config.depth ? "fs_replay_depth" : "fs_replay")!
		replayPipe = try! gpu.makeRenderPipelineState(descriptor: rpdesc)
		rpdesc.colorAttachments[0].pixelFormat = drawableFmt
		rpdesc.vertexFunction = lib.makeFunction(name: "vs_stretch")!
		rpdesc.fragmentFunction = lib.makeFunction(name: "fs_stretch")!
		outputPipe = try! gpu.makeRenderPipelineState(descriptor: rpdesc)
		startTime = Date()
		super.init()
		if !config.live {
			let cb = queue.makeCommandBuffer()!
			record(cb)
			cb.commit()
		}
	}

	func record(_ cb: MTLCommandBuffer) {
		let clear = cb.makeBlitCommandEncoder()!
		clear.waitForFence(barrier1)
		clear.fill(buffer: atomic, range: 0..<(4 * config.tests.count), value: 0)
		clear.updateFence(barrier0)
		clear.endEncoding()
		for idx in 0..<config.tests.count {
			if config.depth {
				recordRPDesc.depthAttachment.texture = recordTextures[idx]
			} else {
				recordRPDesc.colorAttachments[0].texture = recordTextures[idx]
			}
			let render = cb.makeRenderCommandEncoder(descriptor: recordRPDesc)!
			if config.depth {
				render.setDepthStencilState(dss)
			}
			render.waitForFence(barrier0, before: .fragment)
			render.setRenderPipelineState(recordPipe)
			render.setFragmentBuffer(atomic, offset: 4 * idx, index: 0)
			let flip: Float = config.flip ? -1 : 1
			switch config.tests[idx] {
			case .fsTriangle:
				render.setVertexBytes([SIMD4<Float>(-1, flip, 0, 1), SIMD4<Float>(3, flip, 0, 1), SIMD4<Float>(-1, flip * -3, 0, 1)], index: 0)
				render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			case .fsQuadStrip:
				render.setVertexBytes([SIMD4<Float>(-1, flip, 0, 1), SIMD4<Float>(1, flip, 0, 1), SIMD4<Float>(-1, -flip, 0, 1), SIMD4<Float>(1, -flip, 0, 1)], index: 0)
				render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
			case .fsQuadTwoDraws:
				render.setVertexBytes([SIMD4<Float>(-1, flip, 0, 1), SIMD4<Float>(1, flip, 0, 1), SIMD4<Float>(-1, -flip, 0, 1)], index: 0)
				render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
				render.setVertexBytes([SIMD4<Float>(1, flip, 0, 1), SIMD4<Float>(-1, -flip, 0, 1), SIMD4<Float>(1, -flip, 0, 1)], index: 0)
				render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			}
			render.updateFence(barrier1, after: .fragment)
			render.endEncoding()
		}
	}

	func replay(_ cb: MTLCommandBuffer, threshold: UInt32) {
		for (record, replay) in zip(recordTextures, replayTextures) {
			replayRPDesc.colorAttachments[0].texture = replay
			let render = cb.makeRenderCommandEncoder(descriptor: replayRPDesc)!
			render.setRenderPipelineState(replayPipe)
			withUnsafeBytes(of: threshold) { render.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
			render.setFragmentTexture(record, index: 0)
			render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			render.endEncoding()
		}
	}

	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
	}

	func draw(in view: MTKView) {
		let cb = queue.makeCommandBuffer()!
		if config.live { record(cb) }
		let elapsed = -startTime.timeIntervalSinceNow
		var threshold = (elapsed / Double(config.drawTime)) * Double(config.testSize.x * config.testSize.y)
		if (threshold > Double(UInt32.max)) { threshold = Double(UInt32.max) }
		replay(cb, threshold: UInt32(threshold.rounded()))
		if let rdesc = view.currentRenderPassDescriptor {
			let render = cb.makeRenderCommandEncoder(descriptor: rdesc)!
			render.setRenderPipelineState(outputPipe)
			let step = 2 / Float(config.tests.count)
			for (idx, replay) in replayTextures.enumerated() {
				let x0 = Float(idx) * step - 1
				let x1 = Float(idx + 1) * step - 1
				render.setFragmentTexture(replay, index: 0)
				render.setVertexBytes([SIMD4<Float>(x0, 1, 0, 0), SIMD4<Float>(x1, 1, 1, 0), SIMD4<Float>(x0, -1, 0, 1), SIMD4<Float>(x1, -1, 1, 1)], index: 0)
				render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
			}
			render.endEncoding()
			cb.present(view.currentDrawable!)
		}
		cb.commit()
	}
}
