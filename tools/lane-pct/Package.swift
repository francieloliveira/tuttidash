// swift-tools-version:5.9
import Foundation
import PackageDescription

// Usa o pacote do app (mesmas fontes de uso, as não oficiais ligadas conta a conta).
// O install.sh compila a cópia instalada com TUTTIDASH_APP apontando para o app do repositório.
let ambiente = ProcessInfo.processInfo.environment["TUTTIDASH_APP"] ?? ""
let app = ambiente.isEmpty ? Context.packageDirectory + "/../../apps/notch-mac" : ambiente
let package = Package(name: "lanepct", platforms: [.macOS(.v14)],
  dependencies: [.package(path: app)],
  targets: [.executableTarget(name: "lanepct", dependencies: [.product(name: "GastoCore", package: "notch-mac")])])
