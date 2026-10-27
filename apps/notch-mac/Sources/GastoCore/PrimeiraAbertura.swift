import Foundation

/// Primeira abertura guiada (FRA-299): só quando não há config nenhuma nem marcador.
public enum PrimeiraAbertura {
    public static func marcador(home: URL) -> URL {
        Configuracao.arquivoNovo(home: home).deletingLastPathComponent().appendingPathComponent(".primeira-abertura-concluida")
    }

    public static func precisa(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               ambiente: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: marcador(home: home).path) { return false }
        if let p = ambiente[Configuracao.envConfig], !p.isEmpty { return false }
        let configs = [Configuracao.arquivoNovo(home: home), Configuracao.arquivoLanekeeper(home: home),
                       Configuracao.arquivoIntermedio(home: home),
                       Configuracao.arquivoLegado(home: home)]
        return !configs.contains { fm.fileExists(atPath: $0.path) }
    }

    /// Grava a config (com as escolhas já feitas) e o marcador.
    public static func concluir(_ modelo: ModeloAjustes) throws {
        try modelo.salvar()
        try Data().write(to: marcador(home: modelo.home), options: .atomic)
    }
}

/// Dependências opcionais. Nunca bloqueiam: só mostram como instalar.
public struct Dependencia: Identifiable, Equatable, Sendable {
    public var id: String { nome }
    public let nome: String
    public let encontrada: String?
    public let comoInstalar: String
    public let link: URL

    public static func verificar(existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [Dependencia] {
        let brew = URL(string: "https://brew.sh")!
        func primeiro(_ l: [String]) -> String? { l.first(where: existe) }
        return [
            Dependencia(nome: "tmux", encontrada: primeiro(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]),
                        comoInstalar: "brew install tmux", link: brew),
            Dependencia(nome: "python3", encontrada: primeiro(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]),
                        comoInstalar: "xcode-select --install", link: brew),
        ]
    }
}
