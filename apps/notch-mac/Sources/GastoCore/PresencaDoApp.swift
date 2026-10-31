import Foundation

/// Ciclo de vida compartilhado entre o app e os agentes de `~/.transcentia`.
///
/// O app grava `app.pid` ao abrir e o remove ao sair. O dispatcher, o vigia e a
/// chave só trabalham enquanto o PID estiver vivo: no boot, sem o app aberto,
/// eles saem sem assumir card. No `Sair`, o app também interrompe as lanes e os
/// agentes que ainda estiverem rodando.
public enum PresencaDoApp {
    public static func arquivo(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".transcentia/lanes/app.pid")
    }

    /// Chamado no `applicationDidFinishLaunching`.
    public static func marcarAberta(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let url = arquivo(home: home)
        let pasta = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: pasta, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let quando = ISO8601DateFormatter().string(from: Date())
        let texto = "\(pid) \(quando)\n"
        try? texto.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func fechar(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        try? FileManager.default.removeItem(at: arquivo(home: home))
    }

    /// Chamado no `applicationWillTerminate`: «Sair» do app interrompe tudo.
    /// Fechar a janela do painel não passa por aqui; o app continua na barra.
    public static func pararTudo(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // Primeiro os agentes; depois as sessões tmux que eles abriram.
        for padrao in ["tuttidash-agente", "lanes/dispatcher.py", "bots/watch.py", "tools/bots-chave"] {
            _ = rodar("/usr/bin/pkill", ["-f", padrao])
        }
        matarLanes()
        fechar(home: home)
    }

    private static func matarLanes() {
        guard let tmux = tmuxURL() else { return }
        let saida = rodar(tmux.path, ["list-sessions", "-F", "#{session_name}"])
        for nome in saida.split(separator: "\n").map(String.init) where nome.hasPrefix("lane-") {
            _ = rodar(tmux.path, ["kill-session", "-t", nome])
        }
    }

    private static func tmuxURL() -> URL? {
        for caminho in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: caminho) {
                return URL(fileURLWithPath: caminho)
            }
        }
        return nil
    }

    @discardableResult
    private static func rodar(_ executavel: String, _ argumentos: [String]) -> String {
        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: executavel)
        processo.arguments = argumentos
        let saida = Pipe()
        processo.standardOutput = saida
        processo.standardError = FileHandle.nullDevice
        do { try processo.run() } catch { return "" }
        processo.waitUntilExit()
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: dados, as: UTF8.self)
    }
}
