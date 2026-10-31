import Foundation

/// Agendamentos do launchd gerados pelo app (FRA-298, FRA-604). O `~/` vira caminho
/// absoluto na hora de instalar. O plist chama o interpretador por argv: não há lançador
/// em shell, então `$()` e crase no script não executam.
public struct Trabalho: Identifiable, Equatable, Sendable {
    public var id: String { label }
    public let label: String
    /// Nome do lançador em ~/Library/Application Support/AgentesLocais/<nome> (aparece nos Itens de Login).
    public let nome: String
    /// Chave curta usada em `agendas.<chave>_s` e `agendas.env.<chave>`.
    public let chave: String
    public let intervaloPadrao: Int
    public let runAtLoad: Bool
    /// Interpretador absoluto (`/usr/bin/python3`). Entra no argv, sem shell.
    public let interpretador: String
    /// Script. `~/` expande para o home na instalação; tem de ficar sob o home.
    public let script: String
    public let argumentos: [String]
    /// Log do job (aceita `~/`). Vira StandardOutPath e StandardErrorPath.
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
    /// `modo` é o permissionamento POSIX do arquivo (o plist da agenda é 0600).
    func escrever(_ dados: Data, em url: URL, modo: UInt16) throws
    func criarPasta(_ url: URL) throws
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
    public func escrever(_ dados: Data, em url: URL, modo: UInt16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dados.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: modo)], ofItemAtPath: url.path)
    }
    public func criarPasta(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

public enum ErroAgenda: Error, Equatable {
    case labelInvalido(String)
    case caminhoForaDaCasa(String)
    case interpretadorInvalido(String)
    case nomeInvalido(String)
}

public final class GerenciadorAgendas {
    public let home: URL
    public let sistema: SistemaAgendas
    public var config: [String: Any]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                sistema: SistemaAgendas = SistemaReal(), config: [String: Any]) {
        self.home = home; self.sistema = sistema; self.config = config
    }

    public func plistURL(_ t: Trabalho) throws -> URL {
        guard Self.labelValido(t.label) else { throw ErroAgenda.labelInvalido(t.label) }
        let base = home.appendingPathComponent("Library/LaunchAgents")
        let url = base.appendingPathComponent("\(t.label).plist")
        guard url.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path else {
            throw ErroAgenda.labelInvalido(t.label)
        }
        return url
    }

    /// Caminho do lançador zsh antigo, só para apagar na atualização. nil se o nome sairia da pasta.
    public func lancadorURL(_ t: Trabalho) -> URL? {
        guard Self.nomeSeguro(t.nome) else { return nil }
        let base = home.appendingPathComponent("Library/Application Support/AgentesLocais")
        let url = base.appendingPathComponent(t.nome)
        guard url.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path else { return nil }
        return url
    }

    /// Lista do que o app criou; desinstalar só apaga o que está aqui.
    public var manifestoURL: URL { Configuracao.pastaApp(home: home).appendingPathComponent("agendas.json") }

    /// Jobs da config que passam na validação (label, script e log sob o home).
    public var trabalhos: [Trabalho] { Trabalho.lista(config: config).filter { (try? plano($0)) != nil } }

    public func intervalo(_ t: Trabalho) -> Int {
        Int(Configuracao.numero("agendas.\(t.chave)_s", padrao: Double(t.intervaloPadrao), em: config))
    }

    /// Variáveis extras do job (`agendas.env.<chave>`), ex.: SKIP_PREFLIGHT=1 do teste de estresse.
    public func ambiente(_ t: Trabalho) -> [String: String] {
        guard let d = Configuracao.valor("agendas.env.\(t.chave)", em: config) as? [String: Any] else { return [:] }
        return d.mapValues { "\($0)" }
    }

    /// Plist 0600: o launchd lê, o resto da máquina não.
    public static let modoPlist: UInt16 = 0o600

    public func plist(_ t: Trabalho) throws -> Data {
        let p = try plano(t)
        var args = [p.interpretador, p.script]
        args.append(contentsOf: p.argumentos)
        var d: [String: Any] = [
            "Label": t.label,
            "ProgramArguments": args,
            "StandardOutPath": p.log,
            "StandardErrorPath": p.log,
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
        try sistema.escrever(try JSONSerialization.data(withJSONObject: s.sorted()), em: manifestoURL, modo: Self.modoPlist)
    }

    /// Instala ou atualiza só este job: grava o plist (0600) e recarrega (bootout + bootstrap).
    /// Não grava lançador. Apaga o lançador zsh de uma instalação antiga, se o caminho for seguro.
    public func instalar(_ t: Trabalho) throws {
        let p = try plano(t)
        let destino = try plistURL(t)
        try sistema.criarPasta(URL(fileURLWithPath: p.log).deletingLastPathComponent())
        try sistema.escrever(try plist(t), em: destino, modo: Self.modoPlist)
        if let antigo = lancadorURL(t) { try sistema.apagar(antigo) }
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        let (c, s) = sistema.launchctl(["bootstrap", dominio, destino.path])
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
        guard Self.labelValido(t.label) else { throw ErroAgenda.labelInvalido(t.label) }
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        try sistema.apagar(try plistURL(t))
        if let antigo = lancadorURL(t) { try sistema.apagar(antigo) }
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

    struct Plano {
        var interpretador: String
        var script: String
        var argumentos: [String]
        var log: String
    }

    /// Label do launchd e nome do arquivo em LaunchAgents. Sem `/` e sem `..`.
    static func labelValido(_ label: String) -> Bool {
        guard label != ".", label != ".." else { return false }
        return label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Nome do lançador antigo. Espaço cabe ("Exemplo Dispatcher"); `/` e `..` não.
    static func nomeSeguro(_ nome: String) -> Bool {
        !nome.isEmpty && !nome.contains("/") && !nome.contains("..") && !nome.contains("\0")
            && !nome.contains("$") && !nome.contains("`")
    }

    static func interpretadorValido(_ s: String) -> Bool {
        s.range(of: #"^/[A-Za-z0-9._/+-]+$"#, options: .regularExpression) != nil
    }

    /// `~/...` ou absoluto, já normalizado, e dentro do home. Meta de shell recusa o job.
    func expandirSobHome(_ bruto: String) -> String? {
        if bruto.isEmpty || Self.temMetaShell(bruto) { return nil }
        let base = home.standardizedFileURL
        let abs: URL
        if bruto.hasPrefix("~/") {
            abs = home.appendingPathComponent(String(bruto.dropFirst(2)))
        } else if bruto.hasPrefix("/") {
            abs = URL(fileURLWithPath: bruto)
        } else {
            return nil
        }
        let pad = abs.standardizedFileURL
        let casa = base.path
        let caminho = pad.path
        guard caminho == casa || caminho.hasPrefix(casa.hasSuffix("/") ? casa : casa + "/") else { return nil }
        return caminho
    }

    static func temMetaShell(_ s: String) -> Bool {
        s.contains { c in
            c == "$" || c == "`" || c == ";" || c == "|" || c == "&" || c == "<" || c == ">"
                || c == "\\" || c == "!" || c == "(" || c == ")" || c == "\n" || c == "\r" || c == "\0"
        }
    }

    func plano(_ t: Trabalho) throws -> Plano {
        guard Self.labelValido(t.label) else { throw ErroAgenda.labelInvalido(t.label) }
        guard Self.nomeSeguro(t.nome) else { throw ErroAgenda.nomeInvalido(t.nome) }
        guard Self.interpretadorValido(t.interpretador) else { throw ErroAgenda.interpretadorInvalido(t.interpretador) }
        guard let script = expandirSobHome(t.script) else { throw ErroAgenda.caminhoForaDaCasa(t.script) }
        guard let log = expandirSobHome(t.log) else { throw ErroAgenda.caminhoForaDaCasa(t.log) }
        // Argumentos vão no vetor do launchd, um por elemento. Não passam por shell.
        return Plano(interpretador: t.interpretador, script: script, argumentos: t.argumentos, log: log)
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
        guard Self.labelValido(t.label) else { throw ErroAgenda.labelInvalido(t.label) }
        let destino = try plistURL(t)
        _ = sistema.launchctl(["enable", "\(dominio)/\(t.label)"])
        if sistema.existe(destino) {
            let (c, s) = sistema.launchctl(["bootstrap", dominio, destino.path])
            if c != 0 && sistema.launchctl(["print", "\(dominio)/\(t.label)"]).0 != 0 {
                throw NSError(domain: "launchctl", code: Int(c), userInfo: [NSLocalizedDescriptionKey: s])
            }
        } else {
            try instalar(t)
        }
    }

    /// Desliga: descarrega e marca como disabled (continua desligado depois do login). Não apaga arquivos.
    public func desligar(_ t: Trabalho) {
        guard Self.labelValido(t.label) else { return }
        _ = sistema.launchctl(["bootout", "\(dominio)/\(t.label)"])
        _ = sistema.launchctl(["disable", "\(dominio)/\(t.label)"])
    }
}
