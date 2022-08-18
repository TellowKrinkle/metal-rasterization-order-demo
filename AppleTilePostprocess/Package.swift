// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "AppleTilePostprocess",
	dependencies: [
		// Dependencies declare other packages that this package depends on.
		.package(url: "https://github.com/koher/swift-image.git", .upToNextMinor(from: "0.7.1")),
	],
	targets: [
		// Targets are the basic building blocks of a package. A target can define a module or a test suite.
		// Targets can depend on other targets in this package, and on products in packages this package depends on.
		.executableTarget(
			name: "AppleTilePostprocess",
			dependencies: [.product(name: "SwiftImage", package: "swift-image")]),
	]
)
