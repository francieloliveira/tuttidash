import XCTest
@testable import GastoCore

final class RegistroFalso: RegistroAgentes {
    var estado: [String: StatusRegistro] = [:]
    var aoRegistrar: StatusRegistro = .ativo
    var falhar = false
    func status(_ p: String) -> StatusRegistro { estado[p] ?? .naoRegistrado }
    func registrar(_ p: String) throws {
        if falhar { throw NSError(domain: "t", code: 1) }
        estado[p] = aoRegistrar
    }
    func desregistrar(_ p: String) throws { estado[p] = .naoRegistrado }
}

/// launchctl falso que lembra quais labels estão carregados.
final class LaunchdFalso: SistemaAgendas {
    var arquivos: [String: Data] = [:]
    var carregados: Set<String> = []
    var chamadas: [[String]] = []
    var registro: RegistroFalso?
    var uid: UInt32 { 501 }
    func escrever(_ d: Data, em u: URL, executavel: Bool) throws { arquivos[u.path] = d }
    func apagar(_ u: URL) throws { arquivos[u.path] = nil }
    func existe(_ u: URL) -> Bool { arquivos[u.path] != nil }
    func ler(_ u: URL) -> Data? { arquivos[u.path] }
    func launchctl(_ a: [String]) -> (Int32, String) {
        chamadas.append(a)
        let label = a.count > 1 ? String(a.last!.split(separator: "/").last!).replacingOccurrences(of: ".plist", with: "") : ""
        switch a.first {
        case "print":
            if label.hasPrefix("app.tuttidash"), registro?.status("\(label).plist") == .ativo { carregados.insert(label) }
            return carregados.contains(label) ? (0, "state = not running") : (113, "")
        case "bootout": carregados.remove(label); return (0, "")
        case "bootstrap": carregados.insert(label); return (0, "")
        default: return (0, "")
        }
    }
    /// Nunca dois dispatchers: verifica em cada passo.
    var doisDispatchers: Bool { carregados.contains("com.transcentia.lanes.dispatcher") && carregados.contains("app.tuttidash.agente.dispatcher") }
}

final class AgentesDoAppTests: XCTestCase {
    let casa = URL(fileURLWithPath: "/tmp/casa-agentes")
    let d = AgentesDoApp.dispatcher

    func montar(_ r: RegistroFalso, heartbeat: Bool = true) -> (AgentesDoApp, LaunchdFalso) {
        let s = LaunchdFalso(); s.registro = r
        let a = AgentesDoApp(home: casa, sistema: s, registro: r, tentativas: 3, esperar: { _ in XCTAssertFalse(s.doisDispatchers) },
                             confirmar: { _, _ in heartbeat })
        s.arquivos[a.legadoURL(d.antigo).path] = Data("velho".utf8); s.carregados.insert(d.antigo)
        return (a, s)
    }

    func testMigraEApagaSoleDepoisDoHeartbeat() {
        let r = RegistroFalso(); let (a, s) = montar(r)
        XCTAssertEqual(a.migrar(d), .migrado)
        XCTAssertNil(s.arquivos[a.legadoURL(d.antigo).path])
        XCTAssertNotNil(s.arquivos[a.reservaURL(d.antigo).path])
        XCTAssertFalse(s.carregados.contains(d.antigo)); XCTAssertTrue(s.carregados.contains(d.novo))
    }

    func testSemHeartbeatReverte() {
        let r = RegistroFalso(); let (a, s) = montar(r, heartbeat: false)
        XCTAssertEqual(a.migrar(d), .revertido("sem heartbeat em modo real"))
        XCTAssertNotNil(s.arquivos[a.legadoURL(d.antigo).path])
        XCTAssertTrue(s.carregados.contains(d.antigo)); XCTAssertFalse(s.carregados.contains(d.novo))
        XCTAssertEqual(r.status(d.plist), .naoRegistrado)
    }

    func testRegistroRecusadoReverte() {
        let r = RegistroFalso(); r.falhar = true; let (a, s) = montar(r)
        guard case .revertido = a.migrar(d) else { return XCTFail() }
        XCTAssertTrue(s.carregados.contains(d.antigo))
    }

    func testAprovacaoPendenteReverte() {
        let r = RegistroFalso(); r.aoRegistrar = .precisaAprovacao; let (a, s) = montar(r)
        XCTAssertEqual(a.migrar(d), .revertido("precisa de aprovação nos Itens de Login"))
        XCTAssertTrue(s.carregados.contains(d.antigo))
    }

    func testJaNoAppAposentaOAntigo() {
        let r = RegistroFalso(); r.estado[d.plist] = .ativo; let (a, s) = montar(r)
        XCTAssertEqual(a.migrar(d), .jaNoApp)
        XCTAssertFalse(s.carregados.contains(d.antigo))
        XCTAssertNil(s.arquivos[a.legadoURL(d.antigo).path])
    }

    func testSemLegadoNaoRegistra() {
        let r = RegistroFalso(); let (a, s) = montar(r)
        s.arquivos = [:]
        XCTAssertEqual(a.migrar(d), .semLegado)
        XCTAssertEqual(r.status(d.plist), .naoRegistrado)
    }

    func testStatusLigarDesligar() throws {
        let r = RegistroFalso(); let (a, s) = montar(r)
        XCTAssertEqual(a.status(d), .aguardando)            // plist solto carregado
        try a.desligar(d); XCTAssertEqual(a.status(d), .desligado)
        r.falhar = true; try a.ligar(d)                      // recusa: volta o solto
        XCTAssertTrue(s.carregados.contains(d.antigo))
        r.falhar = false; try a.desligar(d); try a.ligar(d)
        XCTAssertEqual(r.status(d.plist), .ativo)
        r.estado[d.plist] = .precisaAprovacao
        XCTAssertEqual(a.status(d), .precisaAprovacao)
        XCTAssertFalse(s.arquivos.keys.contains { $0.contains("PAUSE") || $0.contains("config.json") })
    }

    func testHeartbeat() {
        let desde = Date(timeIntervalSince1970: 1_800_000_000)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        let depois = f.string(from: desde.addingTimeInterval(5)), antes = f.string(from: desde.addingTimeInterval(-60))
        func hb(_ at: String, _ dry: Bool) -> Data { Data("{\"at\": \"\(at)\", \"dry_run\": \(dry)}".utf8) }
        XCTAssertTrue(AgentesDoApp.heartbeatReal(home: casa, desde: desde, dados: hb(depois, false)))
        XCTAssertFalse(AgentesDoApp.heartbeatReal(home: casa, desde: desde, dados: hb(depois, true)))
        XCTAssertFalse(AgentesDoApp.heartbeatReal(home: casa, desde: desde, dados: hb(antes, false)))
    }

    func testMapaDeLabels() {
        XCTAssertEqual(AgentesDoApp.agente(antigo: "com.transcentia.bots.watch")?.novo, "app.tuttidash.agente.vigia")
        XCTAssertEqual(Set(AgentesDoApp.todos.map(\.novo)).count, 3)
    }
}
