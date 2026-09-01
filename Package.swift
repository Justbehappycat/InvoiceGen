// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InvoiceGen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "InvoiceGen",
            path: "Sources/InvoiceGen"
        )
    ]
)
