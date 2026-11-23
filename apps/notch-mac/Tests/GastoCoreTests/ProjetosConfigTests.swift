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

    func testReposVaoEVoltam() {
        var d: [String: Any] = [:]
        let repos = [RepositorioCadastro(slug: "app", repo: "~/a", github: "dono/a"),
                     RepositorioCadastro(slug: "api", repo: "~/b", github: "dono/b", prova: "go test {suite}")]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, repo: "~/a", repos: repos)], em: &d)
        let lido = ProjetosConfig.ler(d)[0]
        XCTAssertEqual(lido.repos.map(\.slug), ["app", "api"])
        XCTAssertEqual(lido.repos.last?.repo, "~/b")
        XCTAssertEqual(lido.repos.last?.prova, "go test {suite}")
    }

    func testPlanejamentoVaiEVolta() {
        var d: [String: Any] = [:]
        let pl = PlanejamentoCadastro(objetivo: "entregar", situacao: "em dia",
                                      inicio: "2026-11-01", alvo: "2026-12-01",
                                      marcos: [MarcoCadastro(nome: "beta", data: "2026-11-20", feito: true)])
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, repo: "~/r", planejamento: pl)], em: &d)
        let lido = ProjetosConfig.ler(d)[0]
        XCTAssertEqual(lido.planejamento.objetivo, "entregar")
        XCTAssertEqual(lido.planejamento.situacao, "em dia")
        XCTAssertEqual(lido.planejamento.alvo, "2026-12-01")
        XCTAssertEqual(lido.planejamento.marcos.first?.nome, "beta")
    }

    /// Agenda e limites por projeto: o app não pode apagar o que o Python usa.
    func testPrioridadeEOperacaoVaoEVoltam() {
        var d: [String: Any] = [:]
        let p = ProjetoCadastro(projetoID: notch, repo: "~/r", prioridade: 3,
                                budgetUSD: ["medio": 5], laneTimeoutMin: 30,
                                proofTimeoutMin: 45, maxLanes: 2, maxTarefasPorLane: 1)
        ProjetosConfig.gravar([p], em: &d)
        let lista = d["projetos"] as? [[String: Any]] ?? []
        XCTAssertEqual(lista[0]["prioridade"] as? Int, 3)
        let op = lista[0]["operacao"] as? [String: Any] ?? [:]
        XCTAssertEqual((op["budget_usd"] as? [String: Double])?["medio"], 5)
        XCTAssertEqual(op["lane_timeout_min"] as? Int, 30)
        XCTAssertEqual(op["proof_timeout_min"] as? Int, 45)
        XCTAssertEqual(op["max_lanes"] as? Int, 2)
        XCTAssertEqual(op["max_tarefas_por_lane"] as? Int, 1)
        let lido = ProjetosConfig.ler(d)[0]
        XCTAssertEqual(lido.prioridade, 3)
        XCTAssertEqual(lido.budgetUSD["medio"], 5)
        XCTAssertEqual(lido.laneTimeoutMin, 30)
        XCTAssertEqual(lido.proofTimeoutMin, 45)
        XCTAssertEqual(lido.maxLanes, 2)
        XCTAssertEqual(lido.maxTarefasPorLane, 1)
    }

    /// Conferência antes do push: vai e volta, e vazio não vai para o arquivo.
    func testAntesDoPushVaiEVolta() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, repo: "~/r", antesDoPush: " bash tools/checar-publicacao.sh "),
                               ProjetoCadastro(projetoID: ios, repo: "~/a")], em: &d)
        let lista = d["projetos"] as? [[String: Any]]
        XCTAssertEqual(lista?[0]["antes_do_push"] as? String, "bash tools/checar-publicacao.sh")
        XCTAssertNil(lista?[1]["antes_do_push"])
        XCTAssertEqual(ProjetosConfig.ler(d).first?.antesDoPush, "bash tools/checar-publicacao.sh")
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

    // MARK: - Norte

    func testNorteSomaAoFreioPadraoEAoDeclarado() {
        let norte = "docs/produto/caminho.md"
        let semDeclarar = ProjetoCadastro(projetoID: notch, repo: "~/r", norte: norte)
        XCTAssertEqual(semDeclarar.protegidosEfetivos, ProjetoCadastro.protegidosPadrao + [norte])
        let declarado = ProjetoCadastro(projetoID: notch, repo: "~/r", protegidos: ["build/*"], norte: norte)
        XCTAssertEqual(declarado.protegidosEfetivos, ["build/*", norte])
        let repetido = ProjetoCadastro(projetoID: notch, repo: "~/r", protegidos: [norte], norte: norte)
        XCTAssertEqual(repetido.protegidosEfetivos, [norte])
    }

    func testNorteInvalidoFicaVazio() {
        for ruim in ["/etc/passwd", "~/caminho.md", "../fora.md", "docs/../x.md", "docs/",
                     "docs//x.md", "./x.md", "a\nb.md", "a\\b.md", ""] {
            XCTAssertEqual(ProjetoCadastro.norteValido(ruim), "", ruim)
        }
        XCTAssertEqual(ProjetoCadastro.norteValido(" docs/produto/caminho.md "), "docs/produto/caminho.md")
    }

    func testSalvarOCadastroGuardaONorte() {
        var d: [String: Any] = ["projetos": [["id": notch, "nome": "P", "repo": "~/r",
                                              "norte": "docs/produto/caminho.md"]]]
        let ps = ProjetosConfig.ler(d)
        XCTAssertEqual(ps.first?.norte, "docs/produto/caminho.md")
        ProjetosConfig.gravar(ps, em: &d)
        XCTAssertEqual((d["projetos"] as? [[String: Any]])?.first?["norte"] as? String, "docs/produto/caminho.md")
        // O freio efetivo não é gravado: o `protegidos` continua sendo só o declarado.
        XCTAssertNil((d["projetos"] as? [[String: Any]])?.first?["protegidos"])
    }

    func testSemNorteNaoGravaChave() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, repo: "~/r")], em: &d)
        XCTAssertNil((d["projetos"] as? [[String: Any]])?.first?["norte"])
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

    func testSalvarOCadastroGuardaAsSuites() {
        var d: [String: Any] = ["projetos": [["id": notch, "nome": "P", "repo": "~/Developer/tuttidash", "suites": ["tests.test_x", "GastoCoreTests"]]]]
        let ps = ProjetosConfig.ler(d)
        XCTAssertEqual(ps.first?.suites, ["tests.test_x", "GastoCoreTests"])
        ProjetosConfig.gravar(ps, em: &d)
        XCTAssertEqual((d["projetos"] as? [[String: Any]])?.first?["suites"] as? [String], ["tests.test_x", "GastoCoreTests"])
    }

    // MARK: - Entrega (FRA-698)

    func testEntregaVaiEVoltaPeloRegistro() {
        let instalacao = InstalacaoCadastro(classe: .artefato, instalar: "./scripts/instalar-app.sh",
                                     destino: "/Applications/TuttiDash.app")
        var d: [String: Any] = ["projetos": [["id": notch, "nome": "P", "repo": "~/Developer/tuttidash",
                                              "entrega": instalacao.dict() ?? [:]]]]
        let ps = ProjetosConfig.ler(d)
        XCTAssertEqual(ps.first?.instalacao.classe, .artefato)
        XCTAssertEqual(ps.first?.instalacao.instalar, "./scripts/instalar-app.sh")
        XCTAssertEqual(ps.first?.instalacao.destino, "/Applications/TuttiDash.app")
        ProjetosConfig.gravar(ps, em: &d)
        let deNovo = ProjetosConfig.ler(d)
        XCTAssertEqual(deNovo.first?.instalacao.dict()?["classe"] as? String, "artefato")
        XCTAssertEqual(deNovo.first?.instalacao.dict()?["destino"] as? String, "/Applications/TuttiDash.app")
    }

    func testEntregaVaziaNaoGravaChave() {
        var d: [String: Any] = [:]
        ProjetosConfig.gravar([ProjetoCadastro(projetoID: notch, repo: "~/r")], em: &d)
        let ps = ProjetosConfig.ler(d)
        XCTAssertNil((d["projetos"] as? [[String: Any]])?.first?["entrega"])
        XCTAssertTrue((ps.first?.instalacao.vazia) ?? false)
        XCTAssertNil(ps.first?.instalacao.dict())
    }

    func testEntregaServicoExigeSubirEValidaPorta() {
        let ok = InstalacaoCadastro(classe: .servico, subir: "python3 servidor.py", porta: "8080")
        XCTAssertNil(ok.problema())
        XCTAssertEqual(ok.dict()?["classe"] as? String, "servico")
        XCTAssertEqual(ok.dict()?["subir"] as? String, "python3 servidor.py")
        XCTAssertEqual(ok.dict()?["porta"] as? Int, 8080)
        XCTAssertNil(ok.dict()?["requer_admin"] as? NSNumber)
        XCTAssertNil(ok.dict()?["url"] as? String)
        XCTAssertNotNil(InstalacaoCadastro(classe: .servico, porta: "8080").problema(),
                         "serviço sem comando de subir não se entrega")
        XCTAssertNotNil(InstalacaoCadastro(classe: .servico, subir: "python3 servidor.py", porta: "abc",
                                       saude: "http://127.0.0.1:{porta}/saude").problema(),
                        "porta numérica exigida quando o endereço usa {porta}")
    }

    func testEntregaArtefatoExigeInstalarEDestino() {
        let ok = InstalacaoCadastro(classe: .artefato, instalar: "./tools/reinstalar-app.sh",
                                 destino: "/Applications/TuttiDash.app")
        XCTAssertEqual(ok.dict()?["instalar"] as? String, "./tools/reinstalar-app.sh")
        XCTAssertEqual(ok.dict()?["destino"] as? String, "/Applications/TuttiDash.app")
        XCTAssertNil(ok.problema())
        XCTAssertNotNil(InstalacaoCadastro(classe: .artefato, instalar: "", destino: "").problema(),
                        "artefato sem comando de instalar não se entrega")
        XCTAssertNotNil(InstalacaoCadastro(classe: .artefato, instalar: "./instalar.sh", destino: "").problema(),
                        "artefato sem destino não se entrega")
    }

    func testEntregaClasseDesconhecidaFicaParaCorrecao() {
        let e = InstalacaoCadastro(classeDesconhecida: "container")
        XCTAssertEqual(e.classe, .nenhuma)
        XCTAssertEqual(e.classeDesconhecida, "container")
        XCTAssertNotNil(e.problema())
    }

    func testEntregaAspasDesbalanceadasSinaChamadaProblema() {
        let cmd = InstalacaoCadastro(classe: .artefato, instalar: "./instalar.sh \"sem fechar", destino: "/tmp/a")
        XCTAssertFalse(InstalacaoCadastro.aspasBalanceadas(cmd.instalar))
        XCTAssertTrue(InstalacaoCadastro.aspasBalanceadas("./instalar.sh ok"))
    }
}
