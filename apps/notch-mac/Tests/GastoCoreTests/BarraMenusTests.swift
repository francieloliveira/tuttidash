import XCTest
@testable import GastoCore

final class BarraMenusTests: XCTestCase {
    func testUltimaLinhaIgnoraVazias() {
        XCTAssertEqual(ResumoBarra.ultimaLinha("a\nb  \n\n  \n"), "b")
        XCTAssertNil(ResumoBarra.ultimaLinha("\n \n"))
    }
    func testTextoPct() {
        XCTAssertEqual(ResumoBarra.textoPct(36.6), "37%")
        XCTAssertEqual(ResumoBarra.textoPct(nil), "–")
    }
    func testSemSnapshotFicaCompacto() {
        let r = ResumoBarra.montar(nil)
        XCTAssertTrue(r.compacto)
        XCTAssertTrue(r.itens.isEmpty)
    }
    func testPreferenciaNotchDesligadaPorPadrao() {
        let d = UserDefaults(suiteName: "fra522-\(UUID())")!
        XCTAssertFalse(PreferenciaNotch.mostrar(d, argumentos: []))
        XCTAssertTrue(PreferenciaNotch.mostrar(d, argumentos: ["--expandido"]))
        d.set(true, forKey: PreferenciaNotch.chave)
        XCTAssertTrue(PreferenciaNotch.mostrar(d, argumentos: []))
    }
    func testSnapshotComLaneRodando() {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: ["opencode"])
        entrada.habilitadas = ["opencode"]
        entrada.provas = [ProvaBruta(lane: "opencode", card: "FRA-399", descricao: "tela",
                                     pedidoEm: data("2026-10-16T17:58:00"), log: "x\n", saida: nil,
                                     esperandoLock: false, historico: false)]
        let snap = MontadorPainel.montar(entrada: entrada, execucoes: [], agora: data("2026-10-16T18:00:00"),
                                         calendario: calendarioFixo())
        let r = ResumoBarra.montar(snap)
        XCTAssertEqual(r.itens.map(\.lane), ["opencode"])
        XCTAssertEqual(r.rodando, 1)
        XCTAssertEqual(r.texto, "1 rodando")
        XCTAssertFalse(r.compacto)
        XCTAssertTrue(ResumoBarra.montar(snap, limite: 0).compacto)
    }

    /// A pílula padrão é a da barra (`PreferenciaNotch` desligada). Com as cinco lanes
    /// ligadas, inclusive o Grok CLI, o resumo não compacta e o menu cita o nome claro.
    /// `cursor` (SuperGrok) não entra: não é lane de desenvolvimento.
    func testCincoLanesLigadasMostramGrokNaBarraENoMenu() {
        let nomes = ["claude", "codex", "opencode", "opencode-go", "grok"]
        XCTAssertEqual(LanesPainel.ordem, nomes)
        let snap = snapLanes(Set(nomes + ["cursor"]))
        let r = ResumoBarra.montar(snap)
        XCTAssertEqual(r.itens.map(\.lane), nomes)
        XCTAssertEqual(r.itens.last?.titulo, "Grok CLI")
        XCTAssertFalse(r.compacto)
        XCTAssertEqual(r.rodando, 0)
        XCTAssertTrue(ResumoBarra.rotuloAcessivel(r).contains("Grok CLI"))
        XCTAssertEqual(snap.notch.pontos.first { $0.lane == "grok" }?.aceso, true)
        XCTAssertFalse(snap.notch.pontos.contains { $0.lane == "cursor" })
        let menu = ResumoBarra.linhasMenu(snap)
        XCTAssertEqual(menu.map(\.lane), nomes)
        XCTAssertEqual(menu.last?.titulo, "Grok CLI")
        XCTAssertEqual(menu.last?.acesa, true)
        XCTAssertEqual(menu.last?.texto, "Grok CLI · livre · –")
        XCTAssertFalse(menu.contains { $0.lane == "cursor" })
        XCTAssertTrue(ResumoBarra.montar(snap, limite: 4).compacto)
        XCTAssertTrue(ResumoBarra.linhasMenu(snap).contains { $0.lane == "grok" })
        XCTAssertGreaterThan(ResumoBarra.larguraMaximaBarra, 260)
    }

    func testGrokDesligadaSomeDaBarraEDoMenu() {
        let snap = snapLanes(["claude", "codex", "opencode", "opencode-go"])
        let r = ResumoBarra.montar(snap)
        XCTAssertEqual(r.itens.map(\.lane), ["claude", "codex", "opencode", "opencode-go"])
        XCTAssertEqual(snap.notch.pontos.first { $0.lane == "grok" }?.aceso, false)
        XCTAssertFalse(ResumoBarra.linhasMenu(snap).contains { $0.lane == "grok" })
        XCTAssertFalse(ResumoBarra.rotuloAcessivel(r).contains("Grok CLI"))
    }

    private func snapLanes(_ habilitadas: Set<String>) -> SnapshotPainel {
        var entrada = EntradaPainel.vazia
        entrada.heartbeat = .init(at: "2026-10-16 17:59:50", dryRun: false, habilitadas: Array(habilitadas))
        entrada.habilitadas = habilitadas
        return MontadorPainel.montar(entrada: entrada, execucoes: [], agora: data("2026-10-16T18:00:00"),
                                     calendario: calendarioFixo())
    }
}
