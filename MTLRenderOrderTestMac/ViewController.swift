import Cocoa
import MetalKit

class ViewController: NSViewController {

	var renderer: Renderer!

	override func viewDidLoad() {
		super.viewDidLoad()

		let mtk = self.view as! MTKView

		let devices = MTLCopyAllDevices()
		var device = MTLCreateSystemDefaultDevice()!
		if let env = getenv("GPU") {
			let str = String(cString: env)
			if let i = Int(str), (0..<devices.count).contains(i) {
				device = devices[i]
			} else if let dev = devices.first(where: { $0.name == str }) {
				device = dev
			}
		}

		renderer = Renderer(device, config: .fromEnv, drawableFmt: mtk.colorPixelFormat)

		mtk.device = device
		mtk.delegate = renderer
	}

	override var representedObject: Any? {
		didSet {
		// Update the view, if already loaded.
		}
	}
}

