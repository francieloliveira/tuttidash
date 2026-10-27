import XCTest
@testable import GastoCore

/// Cadastro de projetos que o dispatcher e o vigia enxergam. O que o Swift lê
/// e o que o `gasto_lanes/projetos.py` lê têm que ser o mesmo formato — o Python
/// é quem o dispatcher usa de verdade, então os defaults aqui são o contrato.
final class ProjetosConfigTests: XCTestCase {
    let ios = "AAAAAAAA-0000-4000-8000-000000000001"
    let notch = "AAAAAAAA-0000-4000-8000-000000000002"

    // MARK: - Leitura

    func testSemChaveNaoHaProjeto() {
        XCTAssertEqual(ProjetosConfig.ler([:]).map(\.projetoID), [])
        XCTAssertNil(ProjetosConfig.padrao(ProjetosConfig.ler([:])))
    }

    func testLeDoisProjetosNaOrdem() {
        let d: [String: Any] = ["projetos": [
            ["id": ios, "nome": "App exemplo", "repo": "~/Developer/app-exemplo",
             "prova": "./scripts/testar.sh {suite}", "prova_tentativas": 2],
            ["id": notch, "nome": "TuttiDash", "ativo": true, "padrao": true,
             "repo": "~/Developer/tuttidash", "prova": "python3 {suite}"],
        ]]
        let ps = ProjetosConfig.ler(d)
        XCTAssertEqual(ps.map(\.projetoID), [ios, notch])
        XCTAssertEqual(ps.map(\.nome), ["App exemplo", "TuttiDash"])
        XCTAssertEqual(ps[1].prova, "python3 {suite}")
        XCTAssertEqual(ps[1].provaTentativas, 1)
    }

    func testRegistroInvalidoFicaVazio() {
        XCTAssertEqual(ProjetosConfig.ler(["projetos": [[String: Any]()]]).map(\.projetoID), [])
        XCTAssertEqual(ProjetosConfig.ler(["projetos": []]).map(\.projetoID), [])
    }

    func testItemSemIdOuComIdRepetidoSome() {
        let d: [String: Any] = ["projetos": [
            ["repo": "~/x"],                                   // sem id
            ["id": ios, "repo": ""],                           // sem repo
            ["id": notch, "repo": "~/Developer/tuttidash"],
            ["id": notch, "repo": "~/outro"],                  // id repetido
        ]]
        XCTAssertEqual(ProjetosConfig.ler(d).map(\.projetoID), [notch])
    }

    func testAtivoAusentePresumeAtivoEAtivoFalseRespeita() {
        let d: [String: Any] = ["projetos": [
            ["id": notch, "repo": "~/x"],
            ["id": ios, "repo": "~/y", "ativo": false],
        ]]
        let ps = ProjetosConfig.ler(d)
        XCTAssertTrue(ps[0].ativo)
        XCTAssertFalse(ps[1].ativo)
    }

    // MARK: - Grava��ão

    func testGravaNoFormatoQueOPYthonLe() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, nome: "TuttiDash",
                                               repo: "~/Developer/tuttidash")], em: &d)
        let lista = d["projetos"] as? [[String: Any]]
        XCTAssertEqual(lista?.count, 1)
        XCTAssertEqual(lista?[0]["id"] as? String, notch)
        XCTAssertEqual(lista?[0]["repo"] as? String, "~/Developer/tuttidash")
        XCTAssertEqual(lista?[0]["prova"] as? String, "python3 {suite}")
        XCTAssertEqual(lista?[0]["ativo"] as? Bool, true)
        // worktrees vazio não vai para o arquivo: o Python deriva do repo
        XCTAssertNil(lista?[0]["worktrees"])
        XCTAssertNil(lista?[0]["protegidos"])
        XCTAssertNil(lista?[0]["copiar_para_worktree"])
    }

    /// Arquivo fora do git que vai para o worktree da lane: o app não pode perder ao salvar.
    func testCopiarParaWorktreeVaiEVolta() {
        var d: [String: Any] = [:]
        let p = ProjetoCadastro(projetoID: notch, repo: "~/r", copiarParaWorktree: ["AGENTS.md"])
        ProjetosConfig.gravar([p], em: &d)
        let lista = d["projetos"] as? [[String: Any]]
        XCTAssertEqual(lista?[0]["copiar_para_worktree"] as? [String], ["AGENTS.md"])
        XCTAssertEqual(ProjetosConfig.ler(d).first?.copiarParaWorktree, ["AGENTS.md"])
    }

    func testNuncaDoisProjetosPadrao() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([
            ProjetoCadastro(projetoID: ios, nome: "iOS", padrao: true, repo: "~/a"),
            ProjetoCadastro(projetoID: notch, nome: "Notch", padrao: true, repo: "~/b"),
        ], em: &d)
        let lista = d["projetos"] as? [[String: Any]] ?? []
        XCTAssertEqual(lista.filter { ($0["padrao"] as? Bool) == true }.count, 1)
    }

    func testIdaEVoltaPeloArquivo() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchl-projetos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let m = ModeloAjustes(home: home)
        let ps = [
            ProjetoCadastro(projetoID: ios, nome: "App exemplo",
                            repo: "~/Developer/app-exemplo"),
            ProjetoCadastro(projetoID: notch, nome: "TuttiDash", padrao: true,
                            repo: "~/Developer/tuttidash", prova: "python3 {suite}",
                            protegidos: ["agents.d/*"], copiarParaWorktree: ["AGENTS.md"]),
        ]
        try m.definirProjetos(ps)
        let outro = ModeloAjustes(home: home)
        XCTAssertEqual(ProjetosConfig.ler(outro.dados), ps)
        XCTAssertEqual(outro.dados["version"] as? Int, Configuracao.versaoAtual,
                       "gravar projetos não pode perder o version")
    }

    // MARK: - Default

    func testPadraoMarcaUmEDesligaInativos() {
        let ps = [
            ProjetoCadastro(projetoID: ios, nome: "iOS", ativo: false, padrao: true, repo: "~/a"),
            ProjetoCadastro(projetoID: notch, nome: "Notch", repo: "~/b"),
        ]
        XCTAssertEqual(ProjetosConfig.padrao(ps)?.projetoID, notch,
                       "padrão inativo não vale")
    }

    func testPadraoSemNinguemMarcadoValeOPrimeiroAtivo() {
        let ps = [
            ProjetoCadastro(projetoID: notch, nome: "Notch", ativo: false, repo: "~/b"),
            ProjetoCadastro(projetoID: ios, nome: "iOS", repo: "~/a"),
        ]
        XCTAssertEqual(ProjetosConfig.padrao(ps)?.projetoID, ios)
    }

    func testWorktreesEfetivoDerivaDoRepo() {
        let p = ProjetoCadastro(projetoID: notch, repo: "~/Developer/tuttidash")
        XCTAssertEqual(p.worktreesEfetivo, "~/Developer/tuttidash-worktrees")
        let declarado = ProjetoCadastro(projetoID: notch, repo: "~/r",
                                        worktrees: "~/meus-worktrees")
        XCTAssertEqual(declarado.worktreesEfetivo, "~/meus-worktrees")
    }

    func testFreioPadraoQuandoNaoDeclara() {
        let p = ProjetoCadastro(projetoID: notch, repo: "~/r")
        XCTAssertEqual(p.protegidosEfetivos, ProjetoCadastro.protegidosPadrao)
        let declarado = ProjetoCadastro(projetoID: notch, repo: "~/r", protegidos: ["agents.d/*"])
        XCTAssertEqual(declarado.protegidosEfetivos, ["agents.d/*"])
    }

    // MARK: - Validação

    func testProblemaApontaCadaAusencia() {
        XCTAssertNotNil(ProjetoCadastro(projetoID: "", repo: "~/a").problema())
        XCTAssertNotNil(ProjetoCadastro(projetoID: "nao-e-uuid", repo: "~/a").problema())
        XCTAssertNotNil(ProjetoCadastro(projetoID: ios, repo: "").problema())
        XCTAssertNotNil(ProjetoCadastro(projetoID: ios, repo: "Developer/App").problema(),
                        "repo sem ~ nem / é caminho relativo e trava o worktree")
        XCTAssertNotNil(ProjetoCadastro(projetoID: ios, repo: "~/a", prova: "swift test").problema(),
                        "prova sem {suite} nunca roda a suíte pedida")
    }

    func testCadastroValidoNaoTemProblema() {
        XCTAssertNil(ProjetoCadastro(projetoID: ios, repo: "~/Developer/app-exemplo",
                                     prova: "./scripts/testar.sh {suite}", provaTentativas: 2).problema())
        XCTAssertNil(ProjetoCadastro(projetoID: notch, repo: "~/Developer/tuttidash",
                                     prova: "python3 {suite}").problema())
    }

    func testConfiguracaoExposeOCadastro() {
        let cfg = Configuracao.resolver(ambiente: [:],
                                        home: URL(fileURLWithPath: "/nao/existe"))
        XCTAssertEqual(cfg.projetos.map(\.projetoID), [], "sem config, sem projeto (FRA-565)")
        XCTAssertNil(cfg.projetoPadrao)
    }
}