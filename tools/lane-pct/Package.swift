// swift-tools-version:5.9
import Foundation
import PackageDescription

// Usa o pacote do app (mesmas fontes de uso). Com `Privado/`, também as leituras do build pessoal.
// O install.sh compila a cópia instalada com TUTTIDASH_APP apontando para o app do repositório.
let ambiente = ProcessInfo.processInfo.environment["TUTTIDASH_APP"] ?? ""
let app = ambiente.isEmpty ? Context.packageDirectory + "/../../apps/notch-mac" : ambiente
let comPrivado = FileManager.default.fileExists(atPath: app + "/Privado/Sources/GastoPrivado")
var deps: [Target.Dependency] = [.product(name: "GastoCore", package: "notch-mac")]
if comPrivado { deps.append(.product(name: "GastoPrivado", package: "notch-mac")) }

let package = Package(name: "lanepct", platforms: [.macOS(.v14)],
  dependencies: [.package(path: app)],
  targets: [.executableTarget(name: "lanepct", dependencies: deps)])
