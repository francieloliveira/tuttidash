import Foundation

/// Agendamentos do launchd gerados pelo app (FRA-298). Nenhum caminho de usuário fixo:
/// o home é resolvido em tempo de execução e os lançadores usam `$HOME`.
public struct Trabalho: Identifiable, Equatable, Sendable {
    public var id: String { label }
    public let label: String
    /// Nome do lançador em ~/Library/Application Support/AgentesLocais/<nome> (aparece nos Itens de Login).
    public let nome: String
    /// Chave curta usada em `agendas.<chave>_s` e `agendas.env.<chave>`.
    public let chave: String
    public let intervaloPadrao: Int
    public let runAtLoad: Bool
    /// Comando do lançador, relativo a `$HOME` quando começa com `~/`.
    public let interpretador: String
    public let script: String
    public let argumentos: [String]
    /// Arquivo de log do lançador (aceita `~/`).
    public let log: String

    public init(label: String, nome: String, chave: String, intervaloPadrao: Int, runAtLoad: Bool,
                interpretador: String, script: String, argumentos: [String], log: String) {
        self.label = label; self.nome = nome; self.chave = chave; self.intervaloPadrao = intervaloPadrao
        self.runAtLoad = runAtLoad; self.interpretador = interpretador; self.script = script
        self.argumentos = argumentos; self.log = log
    }

    /// Jobs vindos de `agendas.jobs` na config (padrões só no `cfg`). Sem config = nenhum job.
    public static func lista(config: [String: Any]) -> [Trabalho] {
        let l = Configuracao.valor("agendas.jobs", em: config) as? [[String: Any]] ?? []
        return l.compactMap { d in
            guard let label = d["label"] as? String, let nome = d["nome"] as? String, !nome.contains("/"),
                  let chave = d["chave"] as? String, let script = d["script"] as? String,
                  let log = d["log"] as? String else { return nil }
            return Trabalho(label: label, nome: nome, chave: chave,
                            intervaloPadrao: (d["intervalo_padrao"] as? NSNumber)?.intValue ?? 300,
                            runAtLoad: (d["run_at_load"] as? NSNumber)?.boolValue ?? false,
                            interpretador: d["interpretador"] as? String ?? "/usr/bin/python3",
                            script: script, argumentos: d["argumentos"] as? [String] ?? [], log: log)
        }
    }
}

public enum EstadoTrabalho: Equatable, Sendable {
    case ativo, parado, erro(String)
}

/// Operações de launchctl e arquivos, trocáveis por um falso nos testes.
public protocol SistemaAgendas: AnyObject {
    func escrever(_ dados: Data, em url: URL, executavel: Bool) throws
    func apagar(_ url: URL) throws
    func existe(_ url: URL) -> Bool
    func ler(_ url: URL) -> Data?
    /// Roda `launchctl <args>`; devolve (código de saída, saída).
    func launchctl(_ args: [String]) -> (Int32, String)
    var uid: UInt32 { get }
}

public final class SistemaReal: SistemaAgendas {
    public init() {}
    public var uid: UInt32 { getuid() }
    public func escrever(_ dados: Data, em url: URL, executavel: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dados.write(to: url, options: .atomic)
        if executavel { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    public func apagar(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func existe(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func ler(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    public func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
}

public final class GerenciadorAgendas {
    public let home: URL
    public let sistema: SistemaAgendas
    public var config: [String: Any]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                sistema: SistemaAgendas = SistemaReal(), config: [String: Any]) {
        self.home = home; self.sistema = sistema; self.config = config
    }

    public func plistURL(_ t: Trabalho) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(t.label).plist") }
    public func lancadorURL(_ t: Trabalho) -> URL {
        home.appendingPathComponent("Library/Application Support/AgentesLocais/\(t.nome)")
    }
    /// Lista do que o app criou; desinstalar só apaga o que está aqui.
    public var manifestoURL: URL { Configuracao.pastaApp(home: home).appendingPathComponent("agendas.json") }

    public var trabalhos: [Trabalho] { Trabalho.lista(config: config) }

    public func intervalo(_ t: Trabalho) -> Int {
        Int(Configuracao.numero("agendas.\(t.chave)_s", padrao: Double(t.intervaloPadrao), em: config))
    }

    /// Variáveis extras do job (`agendas.env.<chave>`), ex.: SKIP_PREFLIGHT=1 do teste de estresse.
    public func ambiente(_ t: Trabalho) -> [String: String] {
        guard let d = Configuracao.valor("agendas.env.\(t.chave)", em: config) as? [String: Any] else { return [:] }
        return d.mapValues { "\($0)" }
    }

    static func aspas(_ s: String) -> String {
        if s.hasPrefix("~/") { return "\"$HOME/" + s.dropFirst(2).replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "'" + s.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    /// Lançador nomeado; usa `$HOME` em tempo de execução e manda a saída para o log do job.
    public func lancador(_ t: Trabalho) -> String {
        let args = ([t.interpretador, t.script] + t.argumentos).map(Self.aspas).joined(separator: " ")
        return """
        #!/bin/zsh
        # Lançador de \(t.label) (gerado pelo app de ajustes; não editar à mão)
        mkdir -p \(Self.aspas((t.log as NSString).deletingLastPathComponent))
        exec >>\(Self.aspas(t.log)) 2>&1
        exec \(args) "$@"

        """
    }

    public func plist(_ t: Trabalho) throws -> Data {
        var d: [String: Any] = [
            "Label": t.label,
            "ProgramArguments": [lancadorURL(t).path],
            "StartInterval": intervalo(t),
            "RunAtLoad": t.runAtLoad,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            // Itens de Login: mostra o job sob o ícone do TuttiDash.
            "AssociatedBundleIdentifiers": ["app.tuttidash.mac"],
        ]
        let env = ambiente(t)
        if !env.isEmpty { d["EnvironmentVariables"] = env }
        return try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    var dominio: String { "gui/\(sistema.uid)" }

    public func instalado(_ t: Trabalho) -> Bool { gerenciados().contains(t.label) }

    public func gerenciados() -> Set<String> {
        guard let d = sistema.ler(manifestoURL),
              let l = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return Set(l)
    }

    private func gravarManifesto(_ s: Set<String>) throws {
        try sistema.escrever(try JSONSerialization.data(withJSONObject: s.sorted()), em: manifestoURL, executavel: false)
    }

    /// Instala ou atualiza só este job: grava lançador e plist e recarrega (bootout + bootstrap).
    public func instalar(_ t: Trabalho) throws {
        try sistema.escrever(Data(lancador(t).utf8), em: lancadorURL(t), executavel: true)
        try sistema.escrever(try plist(t), em: plistURL(t), executavel: false)
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        let (c, s) = sistema.launchctl(["bootstrap", dominio, plistURL(t).path])
        var m = gerenciados(); m.insert(t.label); try gravarManifesto(m)
        if c != 0 { throw NSError(domain: "launchctl", code: Int(c), userInfo: [NSLocalizedDescriptionKey: s]) }
    }

    /// Recarrega só o job cujo intervalo mudou, e só se foi o app que o instalou.
    public func intervaloMudou(chave: String) throws {
        guard let t = trabalhos.first(where: { "agendas.\($0.chave)_s" == chave }), instalado(t) else { return }
        try instalar(t)
    }

    /// Remove o job: bootout e apaga plist e lançador que o app criou.
    public func remover(_ t: Trabalho) throws {
        guard instalado(t) else { return }
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        try sistema.apagar(plistURL(t))
        try sistema.apagar(lancadorURL(t))
        var m = gerenciados(); m.remove(t.label); try gravarManifesto(m)
    }

    /// Desinstala tudo o que o app criou (e só isso).
    public func desinstalarTudo() throws {
        for t in trabalhos where instalado(t) { try remover(t) }
        try sistema.apagar(manifestoURL)
    }

    public func estado(_ t: Trabalho) -> EstadoTrabalho {
        let (c, s) = sistema.launchctl(["print", "\(dominio)/\(t.label)"])
        if c != 0 { return .parado }
        if let r = s.range(of: #"last exit code = (-?\d+)"#, options: .regularExpression) {
            let n = s[r].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "0"
            if n != "0" { return .erro(String(localized: "última saída \(n)")) }
        }
        return .ativo
    }
}

// MARK: - Chaves liga/desliga dos agentes nos Ajustes (FRA-524)

/// Estado mostrado ao lado de cada chave. Ligar/desligar só mexe no serviço do launchd,
/// nunca em `enabled` nem em PAUSE.
public enum StatusAgente: Equatable, Sendable {
    case rodando, aguardando, desligado, precisaAprovacao

    public var rotulo: String {
        switch self {
        case .rodando: return String(localized: "rodando")
        case .aguardando: return String(localized: "aguardando o próximo ciclo")
        case .desligado: return String(localized: "desligado")
        case .precisaAprovacao: return String(localized: "precisa de aprovação nos Ajustes do Sistema")
        }
    }
    public var ligado: Bool { self == .rodando || self == .aguardando }

    /// Lógica pura: `print` = saída de `launchctl print` (nil se o job não está carregado);
    /// `desativado` = o label aparece como disabled em `launchctl print-disabled`.
    public static func de(print: String?, desativado: Bool) -> StatusAgente {
        if let s = print {
            return s.range(of: #"(?m)^\s*state = running"#, options: .regularExpression) != nil ? .rodando : .aguardando
        }
        // Descarregado sem ter sido desligado por nós: o macOS está bloqueando (Itens de Login).
        return desativado ? .desligado : .precisaAprovacao
    }

    /// Lê a saída de `launchctl print-disabled gui/<uid>`.
    public static func desativado(_ label: String, printDisabled: String) -> Bool {
        printDisabled.contains("\"\(label)\" => disabled") || printDisabled.contains("\"\(label)\" => true")
    }
}

extension Trabalho {
    /// Texto curto de ajuda da chave, em pt-BR.
    public var ajuda: String {
        switch chave {
        case "dispatcher": return String(localized: "Distribui os cards prontos para as lanes, a cada minuto. Desligado, nenhuma lane começa trabalho novo.")
        case "watch": return String(localized: "Faz os merges, cuida da fila e das revisões quando o gestor não está.")
        case "chave": return String(localized: "Decide quem cuida das lanes, o gestor ou o vigia. Desligar congela a troca automática.")
        default: return String(localized: "Serviço em segundo plano do TuttiDash.")
        }
    }

    /// Nome curto na tela (FRA-531).
    public var nomeCurto: String {
        switch chave {
        case "dispatcher": return String(localized: "Dispatcher")
        case "watch": return String(localized: "Vigia")
        case "chave": return String(localized: "TuttiChave")
        default: return nome
        }
    }

    public var simbolo: String {
        switch chave {
        case "dispatcher": return "arrow.triangle.branch"
        case "watch": return "eye"
        case "chave": return "key.horizontal"
        default: return "gearshape.2"
        }
    }
}

extension GerenciadorAgendas {
    public func status(_ t: Trabalho) -> StatusAgente {
        let (c, s) = sistema.launchctl(["print", "\(dominio)/\(t.label)"])
        let (_, d) = sistema.launchctl(["print-disabled", dominio])
        return StatusAgente.de(print: c == 0 ? s : nil, desativado: StatusAgente.desativado(t.label, printDisabled: d))
    }

    /// Liga: tira o "disabled" e carrega o plist que já existe (ou grava um novo).
    public func ligar(_ t: Trabalho) throws {
        _ = sistema.launchctl(["enable", "\(dominio)/\(t.label)"])
        if sistema.existe(plistURL(t)) {
            let (c, s) = sistema.launchctl(["bootstrap", dominio, plistURL(t).path])
            if c != 0 && sistema.launchctl(["print", "\(dominio)/\(t.label)"]).0 != 0 {
                throw NSError(domain: "launchctl", code: Int(c), userInfo: [NSLocalizedDescriptionKey: s])
            }
        } else {
            try instalar(t)
        }
    }

    /// Desliga: descarrega e marca como disabled (continua desligado depois do login). Não apaga arquivos.
    public func desligar(_ t: Trabalho) {
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        _ = sistema.launchctl(["disable", "\(dominio)/\(t.label)"])
    }
}
