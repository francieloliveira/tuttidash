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
    /// o novo carregou e foi confirmado (heartbeat real no dispatcher); senão volta ao plist solto.
    public func migrar(_ a: AgenteApp) -> ResultadoMigracao {
        if registro.status(a.plist) == .ativo && carregado(a.novo).0 { aposentarAntigo(a); return .jaNoApp }
        guard sistema.existe(legadoURL(a.antigo)) else { return .semLegado }
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
        for _ in 0..<5 {
            if sistema.launchctl(["bootstrap", dominio, legadoURL(a.antigo).path]).0 == 0 || carregado(a.antigo).0 { break }
            esperar(1)
        }
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

    /// Liga pelo app; se o macOS recusar e ainda houver o plist solto, carrega o solto.
    public func ligar(_ a: AgenteApp) throws {
        do { try registro.registrar(a.plist) } catch {
            guard sistema.existe(legadoURL(a.antigo)) else { throw error }
            _ = sistema.launchctl(["enable", "\(dominio)/\(a.antigo)"])
            _ = sistema.launchctl(["bootstrap", dominio, legadoURL(a.antigo).path])
        }
    }

    public func desligar(_ a: AgenteApp) throws {
        if carregado(a.antigo).0 { _ = sistema.launchctl(["bootout", "\(dominio)/\(a.antigo)"]) }
        let st = registro.status(a.plist)
        if st == .ativo || st == .precisaAprovacao { try registro.desregistrar(a.plist) }
    }
}
