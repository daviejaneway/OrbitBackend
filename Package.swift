import PackageDescription

let package = Package(
    name: "OrbitBackend",
    targets: [],
    dependencies: [
		.Package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", majorVersion: 3),
		.Package(url: "https://github.com/trill-lang/LLVMSwift", majorVersion: 0),
        //.Package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", versions: Version(1,0,0)..<Version(3, .max, .max)),
		//.Package(url: "https://github.com/trill-lang/LLVMSwift", versions: Version(0, 1, 10)..<Version(0, .max, .max)),
		.Package(url: "https://github.com/daviejaneway/OrbitCompilerUtils.git", majorVersion: 0),
		.Package(url: "https://github.com/daviejaneway/OrbitFrontend.git", majorVersion: 0)
    ]
)
