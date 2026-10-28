import Foundation
import XCTest
@testable import GastoCore

/// FRA-581: leituras puxadas por FSEvents em vez do timer de 30 s.
final class ObservadorArquivosTests: XCTestCase {
    // MARK: Agenda

    /// Rajada de escritas vira uma leitura só, e escrita contínua não adia a leitura.
    func testAgendaJuntaRajadaSemAdiar() {
        var a = AgendaDisparo(debounce: 0.5)
        XCTAssertTrue(a.evento(agora: 100, intervaloMinimo: 30))
        XCTAssertEqual(a.proximo, 100.5)
        XCTAssertFalse(a.evento(agora: 100.2, intervaloMinimo: 30))
        XCTAssertFalse(a.evento(agora: 100.4, intervaloMinimo: 2))
        XCTAssertEqual(a.proximo, 100.5)
    }

    /// Depois de uma leitura, log que cresce só relê no fim do intervalo mínimo dele.
    func testAgendaRespeitaIntervaloDesdeALeituraAnterior() {
        var a = AgendaDisparo(debounce: 0.5)
        a.disparou(agora: 100)
        XCTAssertNil(a.proximo)
        XCTAssertTrue(a.evento(agora: 101, intervaloMinimo: 30))
        XCTAssertEqual(a.proximo, 130)
        XCTAssertFalse(a.evento(agora: 110, intervaloMinimo: 30))
        XCTAssertEqual(a.proximo, 130)
    }

    /// Mudança no estado das lanes adianta a leitura que esperava pelos logs.
    func testAgendaEstadoAdiantaLeituraDosLogs() {
        var a = AgendaDisparo(debounce: 0.5)
        a.disparou(agora: 100)
        XCTAssertTrue(a.evento(agora: 101, intervaloMinimo: 30))
        XCTAssertTrue(a.evento(agora: 101, intervaloMinimo: 2))
        XCTAssertEqual(a.proximo, 102)
    }

    /// Depois de um tempo parado, a primeira mudança relê já no debounce.
    func testAgendaDepoisDeSilencioReageNoDebounce() {
        var a = AgendaDisparo(debounce: 0.5)
        a.disparou(agora: 100)
        XCTAssertTrue(a.evento(agora: 200, intervaloMinimo: 30))
        XCTAssertEqual(a.proximo, 200.5)
    }

    // MARK: Caminhos

    func testIntervaloSoParaCaminhosVigiados() {
        let alvos: [(caminho: String, intervalo: TimeInterval)] = [
            ("/users/x/.transcentia/lanes", 2),
            ("/users/x/library/logs/transcentia/lanes", 30),
            ("/users/x/library/logs/transcentia/lanes-dispatcher.log", 30),
        ]
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/Users/x/.transcentia/lanes/heartbeat.json", alvos: alvos), 2)
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/Users/x/.transcentia/lanes", alvos: alvos), 2)
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/Users/x/.transcentia/lanes/", alvos: alvos), 2)
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/Users/x/Library/Logs/TranscentIA/lanes/claude-FRA-1.log",
                                                    alvos: alvos), 30)
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/Users/x/Library/Logs/TranscentIA/lanes-dispatcher.log",
                                                    alvos: alvos), 30)
        // Outro arquivo na pasta do log do dispatcher e pasta com o mesmo começo: fora.
        XCTAssertNil(ObservadorArquivos.intervalo(evento: "/Users/x/Library/Logs/TranscentIA/tuttidash-agentes.log",
                                                  alvos: alvos))
        XCTAssertNil(ObservadorArquivos.intervalo(evento: "/Users/x/.transcentia/lanes-velhas/a.json", alvos: alvos))
        XCTAssertNil(ObservadorArquivos.intervalo(evento: "/Users/x/.transcentia/tools/ledger.jsonl", alvos: alvos))
    }

    func testIntervaloDeCaminhosAninhadosEhOMenor() {
        let alvos: [(caminho: String, intervalo: TimeInterval)] = [("/a", 30), ("/a/b", 2)]
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/a/b/c.json", alvos: alvos), 2)
        XCTAssertEqual(ObservadorArquivos.intervalo(evento: "/a/c.json", alvos: alvos), 30)
    }

    /// O FSEvents manda o caminho com os links resolvidos, mesmo para o que ainda não existe.
    func testRealResolveLinkEAindaNaoExistente() throws {
        let t = try PastaTemp()
        let alvo = t.url.appendingPathComponent("alvo")
        try FileManager.default.createDirectory(at: alvo, withIntermediateDirectories: true)
        let link = t.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: alvo)
        let realAlvo = ObservadorArquivos.real(alvo.path)
        XCTAssertEqual(ObservadorArquivos.real(link.path), realAlvo)
        XCTAssertEqual(ObservadorArquivos.real(link.appendingPathComponent("novo/estado.json").path),
                       realAlvo + "/novo/estado.json")
    }

    /// Arquivo é vigiado pela pasta dele, salvo se a pasta for a home (aí só o próprio arquivo).
    func testRaizDoStream() throws {
        let t = try PastaTemp()
        let casa = t.url.appendingPathComponent("casa")
        let r = ObservadorArquivos.real(casa.path)
        let ledger = CaminhoObservado(arquivo: casa.appendingPathComponent(".transcentia/tools/ledger.jsonl"),
                                      intervaloMinimo: 30)
        XCTAssertEqual(ledger.raiz(home: casa), r + "/.transcentia/tools")
        let lanes = CaminhoObservado(pasta: casa.appendingPathComponent(".transcentia/lanes"), intervaloMinimo: 2)
        XCTAssertEqual(lanes.raiz(home: casa), r + "/.transcentia/lanes")
        let naHome = CaminhoObservado(arquivo: casa.appendingPathComponent("ledger.jsonl"), intervaloMinimo: 30)
        XCTAssertEqual(naHome.raiz(home: casa), r + "/ledger.jsonl")
        let acima = CaminhoObservado(arquivo: t.url.appendingPathComponent("ledger.jsonl"), intervaloMinimo: 30)
        XCTAssertEqual(acima.raiz(home: casa), ObservadorArquivos.real(t.url.path) + "/ledger.jsonl")
    }

    // MARK: Observador

    /// Sem stream (aqui: nada para vigiar), o timer de polling faz as leituras.
    func testSemStreamCaiNoPolling() {
        let leu = expectation(description: "polling")
        leu.expectedFulfillmentCount = 2
        leu.assertForOverFulfill = false
        let obs = ObservadorArquivos(caminhos: [], fallback: 0.1) { leu.fulfill() }
        XCTAssertFalse(obs.iniciar())
        XCTAssertTrue(obs.emFallback)
        XCTAssertFalse(obs.observando)
        wait(for: [leu], timeout: 5)
        obs.parar()
        XCTAssertFalse(obs.emFallback)
    }

    /// Escrita de verdade na pasta vigiada chega bem antes dos 30 s do polling antigo.
    func testReageAEscritaNaPastaVigiada() throws {
        let t = try PastaTemp()
        let lanes = t.url.appendingPathComponent("lanes")
        try FileManager.default.createDirectory(at: lanes, withIntermediateDirectories: true)
        let leu = expectation(description: "evento")
        leu.assertForOverFulfill = false
        let obs = ObservadorArquivos(caminhos: [CaminhoObservado(pasta: lanes, intervaloMinimo: 0)],
                                     debounce: 0.05, fallback: 600) { leu.fulfill() }
        XCTAssertTrue(obs.iniciar())
        XCTAssertTrue(obs.observando)
        XCTAssertFalse(obs.emFallback)
        // O stream pode levar um instante para valer: escreve até o evento chegar.
        let escritor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            try? "{\"em\": \(Date().timeIntervalSince1970)}".write(to: lanes.appendingPathComponent("lane-claude.json"),
                                                                    atomically: true, encoding: .utf8)
        }
        wait(for: [leu], timeout: 10)
        escritor.invalidate()
        obs.parar()
        XCTAssertFalse(obs.observando)
    }

    /// Evento fora dos caminhos não relê; perda de eventos no FSEvents relê.
    func testEventoForaNaoReleEPerdaRele() throws {
        let t = try PastaTemp()
        let lanes = t.url.appendingPathComponent("lanes")
        var leituras = 0
        let obs = ObservadorArquivos(caminhos: [CaminhoObservado(pasta: lanes, intervaloMinimo: 0)],
                                     debounce: 0.05, fallback: 600) { leituras += 1 }
        obs.iniciar()
        obs.receber(caminhos: [t.url.appendingPathComponent("outra/x.json").path], flags: [0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(leituras, 0)
        obs.receber(caminhos: ["/qualquer"], flags: [ObservadorArquivos.flagsPerda])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(leituras, 1)
        obs.receber(caminhos: [ObservadorArquivos.real(lanes.path) + "/lane-claude.json"], flags: [0])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(leituras, 2)
        obs.parar()
    }

    /// `parar()` cancela a leitura que estava marcada.
    func testPararCancelaLeituraMarcada() throws {
        let t = try PastaTemp()
        var leituras = 0
        let obs = ObservadorArquivos(caminhos: [CaminhoObservado(pasta: t.url, intervaloMinimo: 0)],
                                     debounce: 0.1, fallback: 600) { leituras += 1 }
        obs.iniciar()
        obs.receber(caminhos: [ObservadorArquivos.real(t.url.path) + "/a.json"], flags: [0])
        obs.parar()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(leituras, 0)
    }

    /// Stream e timer não seguram o observador: soltou, ele vai embora (e o stream junto).
    func testObservadorLiberado() throws {
        let t = try PastaTemp()
        weak var comStream: ObservadorArquivos?
        weak var comTimer: ObservadorArquivos?
        do {
            let a = ObservadorArquivos(caminhos: [CaminhoObservado(pasta: t.url, intervaloMinimo: 0)]) {}
            XCTAssertTrue(a.iniciar())
            let b = ObservadorArquivos(caminhos: [], fallback: 0.1) {}
            XCTAssertFalse(b.iniciar())
            comStream = a
            comTimer = b
        }
        XCTAssertNil(comStream)
        XCTAssertNil(comTimer)
    }
}
