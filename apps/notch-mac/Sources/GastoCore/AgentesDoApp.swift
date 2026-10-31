import Foundation

/// Estado do registro no SMAppService (espelha SMAppService.Status sem importar ServiceManagement).
public enum StatusRegistro: Equatable, Sendable { case naoRegistrado, ativo, precisaAprovacao, naoEncontrado }

/// Registro dos agentes que vivem dentro do app; trocável por um falso nos testes.
public protocol RegistroAgentes: AnyObject {
    func status(_ plist: String) -> StatusRegistro
    func registrar(_ plist: String) throws
    func desregistrar(_ plist: String) throws
}

public enum ResultadoMigracao: Equatable, Sendable {
    case jaNoApp, migrado, semLegado, revertido(String)
}

/// Um agente do app: Label novo (SMAppService) e o Label antigo do plist solto que ele substitui.
public struct AgenteApp: Equatable, Sendable {
    public let novo: String
    public let antigo: String
    public var plist: String { "\(novo).plist" }
}

/// Os três agentes (Vigia, Chave, Dispatcher) registrados pelo app com SMAppService.
/// Ligar/desligar só mexe no serviço do launchd; nunca em `enabled` nem em PAUSE.
public final class AgentesDoApp {
    public static let dispatcher = AgenteApp(novo: "app.tuttidash.agente.dispatcher", antigo: "com.transcentia.lanes.dispatcher")
    public static let todos = [dispatcher,
        AgenteApp(novo: "app.tuttidash.agente.vigia", antigo: "com.transcentia.bots.watch"),
        AgenteApp(novo: "app.tuttidash.agente.chave", antigo: "com.transcentia.bots.chave")]
    public static func agente(antigo: String) -> AgenteApp? { todos.first { $0.antigo == antigo } }

    public let home: URL
    public let sistema: SistemaAgendas
    public let registro: RegistroAgentes
    let esperar: (TimeInterval) -> Void
    let tentativas: Int
    /// Confirmação extra antes de apagar o plist solto (o dispatcher exige heartbeat em modo real).
    let confirmar: (AgenteApp, Date) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, sistema: SistemaAgendas = SistemaReal(),
                registro: RegistroAgentes, tentativas: Int = 15,
                esperar: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                confirmar: ((AgenteApp, Date) -> Bool)? = nil) {
        self.home = home; self.sistema = sistema; self.registro = registro
        self.tentativas = tentativas; self.esperar = esperar
        let h = home
        self.confirmar = confirmar ?? { a, desde in
            a != AgentesDoApp.dispatcher || AgentesDoApp.heartbeatReal(home: h, desde: desde)
        }
    }

    /// heartbeat.json do dispatcher: gravado depois de `desde` e com dry_run=false.
    public static func heartbeatReal(home: URL, desde: Date, dados: Data? = nil) -> Bool {
        let url = home.appendingPathComponent(".transcentia/lanes/heartbeat.json")
        guard let d = dados ?? (try? Data(contentsOf: url)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let at = o["at"] as? String, (o["dry_run"] as? Bool) == false else { return false }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let t = f.date(from: at) else { return false }
        return t >= desde.addingTimeInterval(-1)
    }

    var dominio: String { "gui/\(sistema.uid)" }
    public func legadoURL(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    public func reservaURL(_ label: String) -> URL {
        Configuracao.pastaApp(home: home).appendingPathComponent("launchagents-antigos/\(label).plist")
    }
    /// Labels cujo plist solto o app gravou. Mesmo critério de `GerenciadorAgendas.gerenciados`.
    var manifestoURL: URL { Configuracao.pastaApp(home: home).appendingPathComponent("agentes-do-app.json") }

    /// Plist solto que o app geraria para este agente. Não lê a config: ela é gravável.
    func plistGerado(_ a: AgenteApp) throws -> Data {
        guard let spec = Self.legadoFixo[a.antigo] else {
            throw NSError(domain: "AgentesDoApp", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "agente sem plist do app"])
        }
        let script = home.appendingPathComponent(spec.script).path
        var args = ["/usr/bin/python3", script]
        args.append(contentsOf: spec.extra)
        let d: [String: Any] = [
            "Label": a.antigo,
            "ProgramArguments": args,
            "StartInterval": spec.intervalo,
            "RunAtLoad": spec.aoCarregar,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "AssociatedBundleIdentifiers": ["app.tuttidash.mac"],
        ]
        return try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    /// Grava o plist do app e anota o label no manifesto. É o único jeito de o fallback carregar.
    func gravarLegadoDoApp(_ a: AgenteApp) throws {
        guard let url = urlLegadoSeguro(a.antigo) else {
            throw NSError(domain: "AgentesDoApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "label fora de LaunchAgents"])
        }
        try sistema.escrever(try plistGerado(a), em: url, executavel: false)
        var m = gerenciados(); m.insert(a.antigo); try gravarManifesto(m)
    }

    func gerenciados() -> Set<String> {
        guard let d = sistema.ler(manifestoURL),
              let l = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return Set(l.filter { Self.labelSeguro($0) })
    }

    private static let legadoFixo: [String: (script: String, intervalo: Int, aoCarregar: Bool, extra: [String])] = [
        "com.transcentia.lanes.dispatcher": (".transcentia/lanes/dispatcher.py", 60, true, ["--real"]),
        "com.transcentia.bots.watch": (".transcentia/bots/watch.py", 180, false, []),
        "com.transcentia.bots.chave": (".transcentia/tools/bots-chave", 600, true, []),
    ]

    private static func labelSeguro(_ label: String) -> Bool {
        label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && !label.contains("..")
    }

    /// Filho direto de ~/Library/LaunchAgents. `..` e barra não passam.
    func urlLegadoSeguro(_ label: String) -> URL? {
        guard Self.labelSeguro(label), !label.contains("/"), !label.contains("\\") else { return nil }
        let pasta = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let url = legadoURL(label)
        let base = pasta.standardizedFileURL.path
        let alvo = url.standardizedFileURL.path
        let prefixo = base.hasSuffix("/") ? base : base + "/"
        guard alvo.hasPrefix(prefixo) else { return nil }
        return url
    }

    private func gravarManifesto(_ s: Set<String>) throws {
        let nomes = s.filter { Self.labelSeguro($0) }.sorted()
        try sistema.escrever(try JSONSerialization.data(withJSONObject: nomes), em: manifestoURL, executavel: false)
    }

    private func plistIgual(_ a: Data, _ b: Data) -> Bool {
        guard let da = try? PropertyListSerialization.propertyList(from: a, options: [], format: nil) as? NSDictionary,
              let db = try? PropertyListSerialization.propertyList(from: b, options: [], format: nil) as? NSDictionary else {
            return false
        }
        return da == db
    }

    /// O arquivo no disco é o plist que o app geraria para este label.
    private func conteudoEhDoApp(_ a: AgenteApp) -> Bool {
        guard let url = urlLegadoSeguro(a.antigo),
              let noDisco = sistema.ler(url),
              let gerado = try? plistGerado(a) else { return false }
        return plistIgual(noDisco, gerado)
    }

    /// Anota o label se o plist já é o do app. Não reescreve um arquivo plantado.
    private func anotarLegadoSeForDoApp(_ a: AgenteApp) {
        guard conteudoEhDoApp(a), !gerenciados().contains(a.antigo) else { return }
        var m = gerenciados(); m.insert(a.antigo); try? gravarManifesto(m)
    }

    /// Bootstrap só com as duas condições: manifesto que o app gravou e conteúdo igual ao gerado.
    func podeCarregarLegado(_ a: AgenteApp) -> Bool {
        guard urlLegadoSeguro(a.antigo) != nil, gerenciados().contains(a.antigo) else { return false }
        return conteudoEhDoApp(a)
    }

    private func reverterParaLegado(_ a: AgenteApp) {
        guard podeCarregarLegado(a), let url = urlLegadoSeguro(a.antigo) else { return }
        for _ in 0..<5 {
            if sistema.launchctl(["bootstrap", dominio, url.path]).0 == 0 || carregado(a.antigo).0 { break }
            esperar(1)
        }
    }
    func carregado(_ label: String) -> (Bool, String) {
        let (c, s) = sistema.launchctl(["print", "\(dominio)/\(label)"]); return (c == 0, s)
    }

    private func mover(_ de: URL, _ para: URL) throws {
        guard let d = sistema.ler(de) else { return }
        try sistema.escrever(d, em: para, executavel: false); try sistema.apagar(de)
    }

    private func aposentarAntigo(_ a: AgenteApp) {
        if carregado(a.antigo).0 { _ = sistema.launchctl(["bootout", "\(dominio)/\(a.antigo)"]) }
        if sistema.existe(legadoURL(a.antigo)) { try? mover(legadoURL(a.antigo), reservaURL(a.antigo)) }
    }

    /// Troca o plist solto (Label antigo) pelo agente do app (Label novo). Nunca roda os dois ao mesmo
    /// tempo: o antigo sai do launchd antes de registrar o novo. O plist solto só é apagado depois que
    /// o novo carregou e foi confirmado (heartbeat real no dispatcher). Se o registro falha, volta ao
    /// plist antigo só quando o app o gravou (manifesto) e o conteúdo ainda é o que o app geraria.
    public func migrar(_ a: AgenteApp) -> ResultadoMigracao {
        if registro.status(a.plist) == .ativo && carregado(a.novo).0 { aposentarAntigo(a); return .jaNoApp }
        guard sistema.existe(legadoURL(a.antigo)) else { return .semLegado }
        anotarLegadoSeForDoApp(a)
        _ = sistema.launchctl(["bootout", "\(dominio)/\(a.antigo)"])
        for _ in 0..<5 where carregado(a.antigo).0 { esperar(1) }   // bootout é assíncrono
        let inicio = Date()
        var motivo = ""
        do {
            try registro.registrar(a.plist)
            var carregou = false
            for _ in 0..<tentativas {
                if registro.status(a.plist) == .precisaAprovacao { motivo = "precisa de aprovação nos Itens de Login"; break }
                if registro.status(a.plist) == .ativo && carregado(a.novo).0 { carregou = true; break }
                esperar(1)
            }
            if carregou {
                for _ in 0..<(tentativas * 6) {
                    if confirmar(a, inicio) { try? mover(legadoURL(a.antigo), reservaURL(a.antigo)); return .migrado }
                    esperar(1)
                }
                motivo = "sem heartbeat em modo real"
            } else if motivo.isEmpty { motivo = "o agente do app não carregou" }
        } catch { motivo = error.localizedDescription }
        try? registro.desregistrar(a.plist)
        _ = sistema.launchctl(["bootout", "\(dominio)/\(a.novo)"])
        reverterParaLegado(a)
        return .revertido(motivo)
    }

    public func status(_ a: AgenteApp) -> StatusAgente {
        if registro.status(a.plist) == .precisaAprovacao { return .precisaAprovacao }
        for l in [a.novo, a.antigo] {
            let (ok, s) = carregado(l)
            if ok { return StatusAgente.de(print: s, desativado: false) }
        }
        return .desligado
    }

    /// Liga pelo app. Falha do SMAppService não carrega um plist solto arbitrário:
    /// só o que está no manifesto e cujo conteúdo ainda é o que o app geraria.
    public func ligar(_ a: AgenteApp) throws {
        do { try registro.registrar(a.plist) } catch {
            guard podeCarregarLegado(a), let url = urlLegadoSeguro(a.antigo) else { throw error }
            _ = sistema.launchctl(["enable", "\(dominio)/\(a.antigo)"])
            _ = sistema.launchctl(["bootstrap", dominio, url.path])
        }
    }

    public func desligar(_ a: AgenteApp) throws {
        if carregado(a.antigo).0 { _ = sistema.launchctl(["bootout", "\(dominio)/\(a.antigo)"]) }
        let st = registro.status(a.plist)
        if st == .ativo || st == .precisaAprovacao { try registro.desregistrar(a.plist) }
    }
}
