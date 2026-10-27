import Foundation

/// Sugestões para o comando da prova (FRA-579), pelo que existe na pasta do projeto.
/// `{suite}` é trocado pelo teste que o card pede.
public enum SugestaoProva {
    public struct Item: Equatable, Hashable, Sendable {
        public let titulo: String
        public let comando: String
        public init(_ titulo: String, _ comando: String) { self.titulo = titulo; self.comando = comando }
    }

    public static let padrao = "python3 {suite}"

    /// Exemplos para quando nada é reconhecido na pasta.
    public static let exemplos: [Item] = [
        Item("Swift", "swift test --filter {suite}"),
        Item("Python (unittest)", "python3 -m unittest {suite}"),
        Item("Python (pytest)", "python3 -m pytest {suite}"),
        Item("Node", "npm test -- {suite}"),
        Item("Rust", "cargo test {suite}"),
        Item("Go", "go test ./... -run {suite}"),
        Item(String(localized: "Arquivo de teste direto"), "python3 {suite}"),
    ]

    /// Sugestões reconhecidas pelos arquivos da raiz (e de `scripts/`). Vazio = nada reconhecido.
    public static func para(pasta: URL, listar: (URL) -> [String] = {
        (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
    }) -> [Item] {
        let raiz = Set(listar(pasta))
        var saida: [Item] = []
        for s in listar(pasta.appendingPathComponent("scripts")).sorted()
        where s.lowercased().contains("test") && (s.hasSuffix(".sh") || !s.contains(".")) {
            saida.append(Item(String(localized: "Script do projeto (\(s))"), "./scripts/\(s) {suite}"))
        }
        if raiz.contains("Package.swift") { saida.append(Item("Swift", "swift test --filter {suite}")) }
        if let ws = raiz.sorted().first(where: { $0.hasSuffix(".xcworkspace") }) {
            let nome = String(ws.dropLast(".xcworkspace".count))
            saida.append(Item("Xcode", "xcodebuild test -workspace \(ws) -scheme \(nome) -only-testing:{suite}"))
        } else if let pj = raiz.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) {
            let nome = String(pj.dropLast(".xcodeproj".count))
            saida.append(Item("Xcode", "xcodebuild test -project \(pj) -scheme \(nome) -only-testing:{suite}"))
        }
        if raiz.contains("package.json") { saida.append(Item("Node", "npm test -- {suite}")) }
        if raiz.contains("Cargo.toml") { saida.append(Item("Rust", "cargo test {suite}")) }
        if raiz.contains("go.mod") { saida.append(Item("Go", "go test ./... -run {suite}")) }
        let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "tests"].contains(where: raiz.contains)
        if raiz.contains("pytest.ini") || raiz.contains("conftest.py") {
            saida.append(Item("Python (pytest)", "python3 -m pytest {suite}"))
        } else if python {
            saida.append(Item("Python (unittest)", "python3 -m unittest {suite}"))
        }
        var vistos = Set<String>()
        return saida.filter { vistos.insert($0.comando).inserted }
    }
}
