// swift-tools-version:5.9
// TuttiDash: app de notch (macOS) que mostra o gasto e o estado das lanes de agentes.
// Sem dependências externas. GastoCore = leitura/agregação (só Foundation, testável);
// NotchGasto = app SwiftUI/AppKit de barra de menus.
//
// Todas as leituras de uso estão no GastoCore. As não oficiais ficam desligadas por conta
// (`"nao_oficial": true` liga). Dados pessoais do build (assinatura, perfil) ficam em `.env`.
import PackageDescription

let package = Package(
    name: "NotchGasto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TuttiDash", targets: ["NotchGasto"]),
        .library(name: "GastoCore", targets: ["GastoCore"]),
    ],
    targets: [
        .target(name: "GastoCore", path: "Sources/GastoCore"),
        .testTarget(name: "GastoCoreTests", dependencies: ["GastoCore"], path: "Tests/GastoCoreTests"),
        .executableTarget(name: "NotchGasto", dependencies: ["GastoCore"], path: "Sources/NotchGasto"),
    ]
)
