import SwiftImage
import Foundation

if CommandLine.arguments.count <= 2 {
	print("Usage: \(CommandLine.arguments[0]) input.png output.png")
} else {
	let image = Image<RGBA<UInt8>>(contentsOfFile: CommandLine.arguments[1])!
	var output = Image<UInt8>(width: image.width, height: image.height, pixel: 0)
	let tileWidth = 32
	let tileHeight = 32
	for y in stride(from: 0, to: image.height, by: tileHeight) {
		let yRange = (y..<(y+tileHeight)).clamped(to: image.yRange)
		for x in stride(from: 0, to: image.width, by: tileWidth) {
			let xRange = (x..<(x+tileWidth)).clamped(to: image.xRange)
			var pixels = [(x: Int, y: Int, value: UInt32)]()
			for ty in yRange {
				for tx in xRange {
					let pixel = image[tx, ty]
					let pixelVal = UInt32(pixel.red) | UInt32(pixel.green) << 8 | UInt32(pixel.blue) << 16
					pixels.append((tx, ty, pixelVal))
				}
			}
			pixels.sort(by: { $0.value < $1.value })
			for (idx, (x, y, _)) in pixels.enumerated() {
				let grayscale = UInt8((idx << 8) / pixels.count)
				output[x, y] = grayscale
			}
		}
	}
	try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), atomically: true, format: .png)
}

