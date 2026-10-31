import XCTest
@testable import GastoCore

/// Registry único de agentes (FRA-372/373/FRA-410): deriva de `agents.d/*.json`,
/// lido também pelo Python. Os testes abaixo NÃO repetem a lista de nomes de
/// propósito — a lista mora nos manifests; os testes checam a consistência entre
/// os manifests, o registry embutido e as consultas derivadas.
final class AgentesTests: XCTestCase {

    // MARK: - Catálogo em disco

    /// `agents.d/` versionado na raiz do repo (fonte da verdade, E13).
    private var repoAgentsD: URL {
        URL(fileURLWithPath: #filePath)          // Tests/GastoCoreTests/AgentesTests.swift
            .deletingLastPathComponent()          // Tests/GastoCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // apps/notch-mac
            .deletingLastPathComponent()          // apps
            .deletingLastPathComponent()          // raiz do repo
            .appendingPathComponent("agents.d")
    }

    private func pastaTemporaria() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents.d-teste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    func testCatalogoNoRepoTemOsMesmosNomesDoFallback() throws {
        let lidos = try CatalogoAgentes.ler(diretorio: repoAgentsD)
        XCTAssertEqual(lidos.map(\.nome), Agentes.embutidos.map(\.nome))
        XCTAssertEqual(Set(lidos.map(\.nome)).count, lidos.count, "nomes repetidos nos manifests")
    }

    func testManifestoRuimNaoDerrubaOsOutros() throws {
        let tmp = try pastaTemporaria()
        let bom = """
        {"schema":1,"nome":"x","rotulo":"X","cli":"x","ordem":1,"painel":true,
         "cor":{"base":"#112233","gradiente":"#112233","claro":"#112233"}}
        """
        try bom.write(to: tmp.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try #"{"schema": 99, "nome": "y", "rotulo": "Y"}"#
            .write(to: tmp.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        try "{ nao e json".write(to: tmp.appendingPathComponent("c.json"), atomically: true, encoding: .utf8)

        let lidos = try CatalogoAgentes.ler(diretorio: tmp)
        XCTAssertEqual(lidos.map(\.nome), ["x"], "schema futuro ou JSON quebrado é ignorado")
    }

    func testSchemaFuturoSemManifestoValidoFalha() throws {
        let tmp = try pastaTemporaria()
        try #"{"schema": 2, "nome": "y", "rotulo": "Y"}"#
            .write(to: tmp.appendingPathComponent("y.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CatalogoAgentes.ler(diretorio: tmp))
    }

    /// Manifesto forjado em `~/.transcentia/agents.d` não substitui o bundle, e `cli` com shell não cola.
    func testManifestoForjadoNaoEntra() throws {
        let t = try PastaTemp()
        let bundle = t.url.appendingPathComponent("bundle")
        let inst = t.url.appendingPathComponent("inst")
        let bom = #"{"schema":1,"nome":"grok","rotulo":"Grok","cli":"grok","ordem":1}"#
        let mau = #"{"schema":1,"nome":"grok","rotulo":"Grok","cli":"x; touch /tmp/pwn","ordem":1}"#
        try t.escrever("bundle/grok.json", bom)
        try t.escrever("inst/grok.json", mau)
        func caminhos(_ dirs: [URL]) -> [String] { dirs.map { $0.standardizedFileURL.path } }
        let soBundle = CatalogoAgentes.diretorios(instalado: inst, fallback: bundle, bundleAssinado: true)
        XCTAssertEqual(caminhos(soBundle), [bundle.standardizedFileURL.path])
        XCTAssertEqual(CatalogoAgentes.carregar(caminhos: soBundle).compactMap(\.cli), ["grok"])
        try t.escrever("inst/grok.json", bom)
        try t.escrever("inst/evil.json", mau)
        let extra = CatalogoAgentes.diretorios(instalado: inst, fallback: bundle, bundleAssinado: true)
        XCTAssertEqual(caminhos(extra), [bundle.standardizedFileURL.path], "arquivo a mais na cópia não entra")
        try FileManager.default.removeItem(at: inst.appendingPathComponent("evil.json"))
        let confere = CatalogoAgentes.diretorios(instalado: inst, fallback: bundle, bundleAssinado: true)
        XCTAssertEqual(caminhos(confere), [inst.standardizedFileURL.path, bundle.standardizedFileURL.path])
        let uid = try XCTUnwrap(ArquivoConfianca.dono(inst))
        let donoErrado = CatalogoAgentes.diretorios(instalado: inst, fallback: bundle, bundleAssinado: true,
                                                    uid: uid, dono: { _ in uid &+ 1 })
        XCTAssertEqual(caminhos(donoErrado), [bundle.standardizedFileURL.path])
        XCTAssertTrue(CatalogoAgentes.diretorios(instalado: inst, fallback: bundle, bundleAssinado: false).isEmpty)
        try t.escrever("solto/mau.json", mau)
        let comMau = try CatalogoAgentes.ler(diretorio: t.url.appendingPathComponent("solto"))
        XCTAssertEqual(comMau.map(\.nome), ["grok"])
        XCTAssertNil(comMau.first?.cli)
        let link = inst.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inst.appendingPathComponent("grok.json"))
        XCTAssertNil(ArquivoConfianca.dono(link))
    }

    func testPastaInexistenteVazio() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agents.d-inexistente-\(UUID().uuidString)")
        XCTAssertEqual(CatalogoAgentes.carregar(caminhos: [tmp]), [])
    }

    // MARK: - Estrutura

    func testManifestosTemOsCamposObrigatorios() {
        for d in Agentes.todos {
            XCTAssertFalse(d.nome.isEmpty, "manifesto sem nome")
            XCTAssertFalse(d.rotulo.isEmpty, "\(d.nome): rotulo vazio")
            XCTAssertFalse(d.sigla.isEmpty, "\(d.nome): sigla vazia")
            XCTAssertTrue(d.corBase.hasPrefix("#"), "\(d.nome): cor base sem #")
        }
        XCTAssertEqual(Set(Agentes.todos.map(\.nome)).count, Agentes.todos.count)
        XCTAssertEqual(Agentes.todos.map(\.ordem), Agentes.todos.map(\.ordem).sorted())
    }

    func testLanesDoPainelSaoAsMarcadasNoManifesto() {
        XCTAssertEqual(LanesPainel.ordem, Agentes.todos.filter(\.painel).map(\.nome))
        XCTAssertFalse(LanesPainel.ordem.isEmpty)
        // cursor e conta de uso, nao lane do painel.
        XCTAssertFalse(LanesPainel.ordem.contains("cursor"))
        XCTAssertFalse(LanesPainel.ordem.contains("gemini"))
        XCTAssertFalse(LanesPainel.ordem.contains("copilot"))
        XCTAssertNotNil(Agentes.def("cursor"))
    }

    func testAgenteComCliTemResume() {
        for d in Agentes.todos where d.cli != nil {
            XCTAssertNotNil(d.resumeCLI, "\(d.nome): CLI sem resume")
        }
    }

    // MARK: - Consultas

    func testCustoOrdemResumeTipos() {
        XCTAssertEqual(Agentes.custoEstimado, Set(Agentes.todos.filter(\.custoEstimado).map(\.nome)))
        XCTAssertTrue(Agentes.ordemLane("claude", "grok"))
        XCTAssertTrue(Agentes.ordemLane("cursor", "umanova"))
        XCTAssertTrue(Agentes.ordemLane("outranova", "umanova"))
        XCTAssertEqual(Agentes.cliResume(lane: "codex"), Agentes.def("codex")!.resumeCLI!)
        XCTAssertEqual(Agentes.cliResume(lane: "cursor"), "claude")
        XCTAssertEqual(Agentes.cliResume(lane: "umanova"), "claude")
        XCTAssertEqual(ContaUso.tipos, Agentes.tiposConta)
    }

    func testTiposContaNaoRepetemQuandoDuasLanesMedemOMesma() {
        let brutos = Agentes.todos.map(\.tipoUso).filter { !$0.isEmpty }
        var vistos = Set<String>()
        XCTAssertEqual(Agentes.tiposConta, brutos.filter { vistos.insert($0).inserted })
        XCTAssertEqual(Set(Agentes.tiposConta).count, Agentes.tiposConta.count)
    }

    func testPesoFontesDocumentamOFallback() {
        let mapa = Dictionary(uniqueKeysWithValues: Agentes.todos.map { ($0.nome, $0.pesoFontes) })
        XCTAssertFalse(mapa.isEmpty)
        for (nome, fontes) in mapa {
            XCTAssertFalse(fontes.isEmpty, "\(nome): sem fonte de peso")
        }
    }

    func testContasUmaPorTipoComAgenteNoCatalogo() {
        XCTAssertEqual(ContaUso.todas.map(\.tipo), Agentes.ordem)
        XCTAssertEqual(ContaUso.padrao.map(\.tipo), Agentes.todos.filter { !$0.optIn }.map(\.nome))
        XCTAssertEqual(Set(ContaUso.todas.map(\.sigla)).count, ContaUso.todas.count)
        for conta in ContaUso.todas {
            XCTAssertNotNil(Agentes.def(conta.tipo), "conta \(conta.tipo) sem agente no catalogo")
        }
    }
}