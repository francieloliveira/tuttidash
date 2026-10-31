import Darwin
import Foundation

/// Proxy local do token do Linear (FRA-607). O processo é o `proxy_linear.py`.
/// O token vai na entrada padrão, nunca nos argumentos, no ambiente ou no log.
public enum ProxyDoLinear {
    public static let nomeSocket = "linear-proxy.sock"
    public static let nomeAuditoria = "linear-proxy-audit.log"
    public static let nomePid = "linear-proxy.pid"

    public static func pasta(home: URL) -> URL {
        home.appendingPathComponent(".transcentia/lanes")
    }

    public static func socket(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomeSocket) }
    public static func auditoria(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomeAuditoria) }
    public static func arquivoPid(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomePid) }

    /// O token não entra nesta lista.
    public static func argumentos(python: String = "/usr/bin/python3", script: String) -> [String] {
        [python, script, "--servir"]
    }

    public static func primeiroLegivel(_ candidatos: [URL]) -> URL? {
        candidatos.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    public static func candidatosScript(home: URL, recursos: URL?, executavel: URL?) -> [URL] {
        var lista: [URL] = []
        if let recursos { lista.append(recursos.appendingPathComponent("proxy_linear.py")) }
        lista.append(home.appendingPathComponent(".transcentia/lanes/proxy_linear.py"))
        lista.append(home.appendingPathComponent(".transcentia/bots/proxy_linear.py"))
        if var dir = executavel?.deletingLastPathComponent() {
            for _ in 0..<8 {
                lista.append(dir.appendingPathComponent("gasto_lanes/proxy_linear.py"))
                let pai = dir.deletingLastPathComponent()
                if pai.path == dir.path { break }
                dir = pai
            }
        }
        return lista
    }

    public static func acharScript(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   recursos: URL? = Bundle.main.resourceURL,
                                   executavel: URL? = Bundle.main.bundleURL) -> URL? {
        primeiroLegivel(candidatosScript(home: home, recursos: recursos, executavel: executavel))
    }
}

/// Sobe e derruba o proxy. O token é lido do Keychain do app e escrito na entrada do processo.
public final class ServicoProxyLinear: @unchecked Sendable {
    public static let compartilhado = ServicoProxyLinear()
    private let lock = NSLock()
    private var processo: Process?

    public func ligar(tokens: TokenLinear = TokenLinear(),
                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      script: URL? = nil) {
        let token = tokens.ler()
        let programa = script ?? ProxyDoLinear.acharScript(home: home)
        lock.lock()
        defer { lock.unlock() }
        let pidAntigo = Self.lerPid(home)
        encerrarProcesso()
        guard let token, !token.isEmpty, !token.contains(where: { $0 == "\n" || $0 == "\r" }),
              let programa else {
            Self.encerrarPid(pidAntigo)
            Self.apagarArquivos(home)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [programa.path, "--servir"]
        let entrada = Pipe()
        p.standardInput = entrada
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        entrada.fileHandleForWriting.write(Data((token + "\n").utf8))
        try? entrada.fileHandleForWriting.close()
        processo = p
        if let pidAntigo, pidAntigo != p.processIdentifier, Self.parecePython(pidAntigo) {
            Self.encerrarPid(pidAntigo)
        }
    }

    public func parar(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        lock.lock()
        defer { lock.unlock() }
        encerrarProcesso()
        Self.encerrarPid(Self.lerPid(home))
        Self.apagarArquivos(home)
    }

    private func encerrarProcesso() {
        if let processo, processo.isRunning { processo.terminate() }
        processo = nil
    }

    private static func lerPid(_ home: URL) -> Int32? {
        guard let texto = try? String(contentsOf: ProxyDoLinear.arquivoPid(home: home), encoding: .utf8) else { return nil }
        return Int32(texto.split(whereSeparator: \.isWhitespace).first ?? "")
    }

    private static func parecePython(_ pid: Int32) -> Bool {
        if pid <= 1 { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "comm="]
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let texto = String(data: saida.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return texto.lowercased().contains("python")
    }

    private static func encerrarPid(_ pid: Int32?) {
        guard let pid, pid > 1 else { return }
        Darwin.kill(pid, SIGTERM)
    }

    private static func apagarArquivos(_ home: URL) {
        for url in [ProxyDoLinear.socket(home: home), ProxyDoLinear.arquivoPid(home: home)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
