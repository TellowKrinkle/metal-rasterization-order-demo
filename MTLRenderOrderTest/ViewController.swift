import UIKit
import MetalKit

class ViewController: UIViewController {
	var renderer: Renderer!

	override func viewDidLoad() {
		super.viewDidLoad()
		let mtk = self.view as! MTKView

		let device = MTLCreateSystemDefaultDevice()!

		renderer = Renderer(device, config: .fromEnv, drawableFmt: mtk.colorPixelFormat)

		mtk.device = device
		mtk.delegate = renderer
	}
}

