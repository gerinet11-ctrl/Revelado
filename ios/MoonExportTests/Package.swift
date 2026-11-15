// swift-tools-version: 5.9
import PackageDescription

// Pruebas automáticas del guardado de video rápido. Se ejecutan en un Mac con «swift test»
// (las corre GitHub en el flujo «Probar guardado nativo»). No forma parte de la app.
let package = Package(
    name: "MoonExportTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MoonExport", path: "Sources/MoonExport"),
        .testTarget(name: "MoonExportTests", dependencies: ["MoonExport"], path: "Tests")
    ]
)
