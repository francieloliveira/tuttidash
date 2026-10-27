// swift-tools-version:5.9
// TuttiDash: app de notch (macOS) que mostra o gasto e o estado das lanes de agentes.
// Sem dependências externas. GastoCore = leitura/agregação (só Foundation, testável);
// NotchGasto = app SwiftUI/AppKit de barra de menus.
//
// `Privado/` (fora deste repositório) traz leituras de uso que não usam APIs oficiais.
// Sem a pasta, o pacote compila só com as fontes oficiais e locais.
import Foundation
import PackageDescription

let raiz = Context.packageDirectory
let comPrivado = FileManager.default.fileExists(atPath: raiz + "/Privado/Sources/GastoPrivado")

var produtos: [Product] = [
    .executable(name: "TuttiDash", targets: ["NotchGasto"]),
    .library(name: "GastoCore", targets: ["GastoCore"]),
]
var alvos: [Target] = [
    .target(name: "GastoCore", path: "Sources/GastoCore"),
    .testTarget(name: "GastoCoreTests", dependencies: ["GastoCore"], path: "Tests/GastoCoreTests"),
]
var dependenciasApp: [Target.Dependency] = ["GastoCore"]

if comPrivado {
    produtos.append(.library(name: "GastoPrivado", targets: ["GastoPrivado"]))
    alvos.append(.target(name: "GastoPrivado", dependencies: ["GastoCore"], path: "Privado/Sources/GastoPrivado"))
    if FileManager.default.fileExists(atPath: raiz + "/Privado/Tests/GastoPrivadoTests") {
        alvos.append(.testTarget(name: "GastoPrivadoTests", dependencies: ["GastoCore", "GastoPrivado"],
                                 path: "Privado/Tests/GastoPrivadoTests"))
    }
    dependenciasApp.append("GastoPrivado")
}
alvos.append(.executableTarget(name: "NotchGasto", dependencies: dependenciasApp, path: "Sources/NotchGasto"))

let package = Package(
    name: "NotchGasto",
    platforms: [.macOS(.v14)],
    products: produtos,
    targets: alvos
)
