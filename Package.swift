// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Buds",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Buds", targets: ["Buds"])],
    targets: [
        .executableTarget(name: "Buds", resources: [.copy("Resources")], linkerSettings: [.linkedFramework("IOBluetooth")])
    ],
    swiftLanguageModes: [.v5]
)
