import Foundation

/// Lanes habilitadas (`enabled`): quem pode assumir cards. Lido e gravado de forma
/// atômica; só entram nomes do registry (`Agentes.ordem`). O dispatcher ignora
/// lane sem execução real e registra no log; a janela tmux segue o mesmo arquivo.
public enum LanesHabilitadas {
    /// Erro tipado quando o dispatcher não existe no Mac.
    public struct DispatcherNaoEncontrado: Error, LocalizedError {
        public var errorDescription: String? { "dispatcher não encontrado" }
    }

    public static func arquivo(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("enabled")
    }

    /// Verifica se o dispatcher existe no Mac (pasta ~/.transcentia/lanes/dispatcher.py).
    public static func dispatcherExiste(stateDir: URL) -> Bool {
        let dispatcher = stateDir.appendingPathComponent("dispatcher.py")
        return FileManager.default.fileExists(atPath: dispatcher.path)
    }

    public static func ler(stateDir: URL) -> Set<String> {
        guard let texto = try? String(contentsOf: arquivo(stateDir: stateDir), encoding: .utf8) else {
            return []
        }
        let conhecidos = Set(Agentes.ordem)
        return Set(texto.split(whereSeparator: \.isWhitespace).map(String.init).filter { conhecidos.contains($0) })
    }

    public static func gravar(_ lanes: Set<String>, stateDir: URL) throws {
        // FRA-421: não criar ~/.transcentia/lanes se o dispatcher não existe.
        guard dispatcherExiste(stateDir: stateDir) else {
            throw DispatcherNaoEncontrado()
        }
        let conhecidos = Set(Agentes.ordem)
        let lista = Agentes.ordem.filter { lanes.contains($0) && conhecidos.contains($0) }
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try (lista.joined(separator: " ") + "\n").write(to: arquivo(stateDir: stateDir),
                                                        atomically: true, encoding: .utf8)
    }
}
