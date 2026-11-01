import Darwin
import Foundation

/// Proxy local do token do Linear (FRA-607). O processo é o `proxy_linear.py`.
/// O token vai na entrada padrão, nunca nos argumentos, no ambiente ou no log.
public enum ProxyDoLinear {
    public static let nomeSocket = "linear-proxy.sock"
    public static let nomeAuditoria = "linear-proxy-audit.log"
    public static let nomePid = "linear-proxy.pid"
    public static let nomeLog = "linear-proxy.log"

    public static func pasta(home: URL) -> URL {
        home.appendingPathComponent(".transcentia/lanes")
    }

    public static func socket(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomeSocket) }
    public static func auditoria(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomeAuditoria) }
    public static func arquivoPid(home: URL) -> URL { pasta(home: home).appendingPathComponent(nomePid) }
    public static func logProxy(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/TranscentIA").appendingPathComponent(nomeLog)
    }

    /// O token não entra nesta lista.
    public static func argumentos(python: String = "/usr/bin/python3", script: String) -> [String] {
        [python, script, "--servir"]
    }

    public static func primeiroLegivel(_ candidatos: [URL]) -> URL? {
        candidatos.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// Só o recurso do bundle. `~/.transcentia/lanes/proxy_linear.py` a lane troca,
    /// e o token iria no stdin desse arquivo.
    public static func candidatosScript(recursos: URL?) -> [URL] {
        guard let recursos else { return [] }
        return [recursos.appendingPathComponent("proxy_linear.py")]
    }

    public static func acharScript(recursos: URL? = Bundle.main.resourceURL) -> URL? {
        primeiroLegivel(candidatosScript(recursos: recursos))
    }

    /// `ps -o args=` tem de citar o script. `comm` com "python" também é o dispatcher.
    public static func deveSinalizar(args: String) -> Bool {
        args.contains("proxy_linear.py")
    }
}

/// Sobe e derruba o proxy. Quem chama guarda o protocolo, não o singleton.
public protocol ControleProxyLinear: AnyObject, Sendable {
    func ligar(tokens: TokenLinear, home: URL, script: URL?)
    func parar(home: URL)
}

extension ControleProxyLinear {
    public func ligar() {
        ligar(tokens: TokenLinear(), home: FileManager.default.homeDirectoryForCurrentUser, script: nil)
    }

    public func ligar(tokens: TokenLinear) {
        ligar(tokens: tokens, home: FileManager.default.homeDirectoryForCurrentUser, script: nil)
    }

    public func parar() {
        parar(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// Sobe e derruba o proxy. O token é lido do Keychain do app e escrito na entrada do processo.
public final class ServicoProxyLinear: ControleProxyLinear, @unchecked Sendable {
    public static let compartilhado = ServicoProxyLinear()
    private let lock = NSLock()
    private var processo: Process?
    private var stderrLog: FileHandle?
    /// Binário do processo. O padrão é o python do sistema; o teste troca.
    var binario = "/usr/bin/python3"
    /// Escrita do token no stdin. A padrão é `write(contentsOf:)`, que lança erro em vez de exceção.
    var escrever: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    /// Pid do filho encerrado porque a escrita do token falhou. 0 se não houve.
    private(set) var pidEncerradoPorFalha: Int32 = 0

    public func ligar(tokens: TokenLinear, home: URL, script: URL?) {
        let token = tokens.ler()
        let programa = script ?? ProxyDoLinear.acharScript()
        lock.lock()
        defer { lock.unlock() }
        let pidAntigo = Self.lerPid(home)
        encerrarProcesso()
        Self.encerrarSeForProxy(pidAntigo)
        guard let token, !token.isEmpty, !token.contains(where: { $0 == "\n" || $0 == "\r" }),
              let programa else {
            Self.apagarArquivos(home)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binario)
        p.arguments = [programa.path, "--servir"]
        let entrada = Pipe()
        p.standardInput = entrada
        p.standardOutput = FileHandle.nullDevice
        let erroLog = Self.abrirStderr(home)
        p.standardError = erroLog ?? FileHandle.nullDevice
        stderrLog = erroLog
        do {
            try p.run()
            try escrever(entrada.fileHandleForWriting, Data((token + "\n").utf8))
        } catch {
            if p.isRunning {
                pidEncerradoPorFalha = p.processIdentifier
                p.terminate()
                Self.esperar(p)
            }
            try? stderrLog?.close()
            stderrLog = nil
            Self.apagarArquivos(home)
            return
        }
        try? entrada.fileHandleForWriting.close()
        processo = p
    }

    public func parar(home: URL) {
        lock.lock()
        defer { lock.unlock() }
        let pid = Self.lerPid(home)
        encerrarProcesso()
        Self.encerrarSeForProxy(pid)
        Self.apagarArquivos(home)
    }

    private func encerrarProcesso() {
        guard let processo else {
            try? stderrLog?.close()
            stderrLog = nil
            return
        }
        if processo.isRunning {
            processo.terminate()
            Self.esperar(processo)
        }
        self.processo = nil
        try? stderrLog?.close()
        stderrLog = nil
    }

    private static func lerPid(_ home: URL) -> Int32? {
        guard let texto = try? String(contentsOf: ProxyDoLinear.arquivoPid(home: home), encoding: .utf8) else { return nil }
        return Int32(texto.split(whereSeparator: \.isWhitespace).first ?? "")
    }

    /// Sinaliza só se a linha de comando é o proxy. Espera sair antes de quem chama apagar o socket.
    private static func encerrarSeForProxy(_ pid: Int32?) {
        guard let pid, pid > 1 else { return }
        let args = Subprocesso.rodar("/bin/ps", ["-p", String(pid), "-o", "args="]).texto
        guard ProxyDoLinear.deveSinalizar(args: args) else { return }
        Darwin.kill(pid, SIGTERM)
        let limite = Date().addingTimeInterval(2)
        while Date() < limite {
            if saiu(pid) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Morto, ou zumbi (já saiu; o pai ainda não recolheu).
    private static func saiu(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) != 0 { return true }
        let stat = Subprocesso.rodar("/bin/ps", ["-p", String(pid), "-o", "stat="]).texto
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stat.hasPrefix("Z")
    }

    /// Espera o filho sem `waitUntilExit` na thread de quem chamou (isso reentra no SwiftUI).
    private static func esperar(_ p: Process) {
        let fim = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in fim.signal() }
        if !p.isRunning { return }
        _ = fim.wait(timeout: .now() + 2)
    }

    private static func apagarArquivos(_ home: URL) {
        for url in [ProxyDoLinear.socket(home: home), ProxyDoLinear.arquivoPid(home: home)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// stderr do proxy. O stdin (o token) não passa por aqui.
    private static func abrirStderr(_ home: URL) -> FileHandle? {
        let url = ProxyDoLinear.logProxy(home: home)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600]) else { return nil }
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            return h
        } catch {
            return nil
        }
    }
}
