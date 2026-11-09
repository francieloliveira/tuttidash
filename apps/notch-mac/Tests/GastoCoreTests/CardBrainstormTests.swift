import XCTest
@testable import GastoCore

final class CardBrainstormTests: XCTestCase {
    private let etiquetas = [BrainstormCLI.EtiquetaLane(nome: "claude", esforcos: ["baixo", "medio", "alto"])]

    func testLeHistoriaNoFormatoNovo() throws {
        let bruto = """
        HISTORIA:
        titulo: Linha Norte no cadastro
        objetivo: O cadastro mostra se o projeto tem norte.
        norte: > §2 R1: nenhuma lane edita o norte.
        Esta história deixa o estado visível.
        descricao: Como dono, quero ver o norte, para saber se os cards se ancoram.
        aceite:
        - A linha mostra ativo, importável, aguardando merge ou falta.
        prova: NorteProjetoTests
        fora:
        - Criar o norte (é da história do wizard).
        arquivos:
        - apps/notch-mac/Sources/NotchGasto/SecaoProjetos.swift — linha nova
        depende:
        - nenhuma
        prioridade: 2
        estimativa: 3
        esforco: baixo
        lane: claude
        """
        let h = try XCTUnwrap(BrainstormCLI.historias(de: bruto, etiquetas: etiquetas).first)
        XCTAssertEqual(h.objetivo, "O cadastro mostra se o projeto tem norte.")
        XCTAssertEqual(h.norteServido, "> §2 R1: nenhuma lane edita o norte.\nEsta história deixa o estado visível.")
        XCTAssertEqual(h.criterios, ["A linha mostra ativo, importável, aguardando merge ou falta."])
        XCTAssertEqual(h.prova, "NorteProjetoTests")
        XCTAssertEqual(h.foraDeEscopo, ["Criar o norte (é da história do wizard)."])
        XCTAssertEqual(h.arquivos, ["apps/notch-mac/Sources/NotchGasto/SecaoProjetos.swift — linha nova"])
        XCTAssertEqual(h.dependencias, [], "nenhuma não é dependência")
    }

    func testFormatoAntigoContinuaLendoCriterios() throws {
        let bruto = "HISTORIA:\ntitulo: X\ndescricao: Como a, quero b, para c.\ncriterios:\n- um\n- dois\nesforco: medio\nlane: claude"
        let h = try XCTUnwrap(BrainstormCLI.historias(de: bruto, etiquetas: etiquetas).first)
        XCTAssertEqual(h.criterios, ["um", "dois"])
        XCTAssertEqual(h.foraDeEscopo, [])
    }

    func testItemDeListaNaoVazaParaOAceite() throws {
        let bruto = "HISTORIA:\ntitulo: X\naceite:\n- ok\nfora:\n- não mexe no y\n- nem no z\nesforco: medio\nlane: claude"
        let h = try XCTUnwrap(BrainstormCLI.historias(de: bruto, etiquetas: etiquetas).first)
        XCTAssertEqual(h.criterios, ["ok"])
        XCTAssertEqual(h.foraDeEscopo, ["não mexe no y", "nem no z"])
    }

    func testFaltandoTravaObjetivoAceiteEFora() {
        XCTAssertEqual(CardBrainstorm.faltando(objetivo: " ", aceite: [""], foraDeEscopo: []),
                       [.objetivo, .aceite, .foraDeEscopo])
        XCTAssertEqual(CardBrainstorm.faltando(objetivo: "x", aceite: ["a"], foraDeEscopo: ["f"]), [])
    }

    func testCorpoNoFormatoDoPRD() {
        let c = CardBrainstorm.corpo(objetivo: "Resultado.", norteServido: "§2 R1: não editar o norte.",
                                     historia: "Como dono, quero x, para y.", aceite: ["observável"],
                                     prova: "NorteProjetoTests", foraDeEscopo: ["o wizard"],
                                     arquivos: ["a.swift — por quê"], dependencias: ["nenhuma"],
                                     esforco: "baixo", lane: "claude")
        XCTAssertEqual(c, """
        ## Objetivo
        Resultado.

        ## Norte servido
        > §2 R1: não editar o norte.

        ## História
        Como dono, quero x, para y.

        ## Aceite
        - [ ] observável
        - [ ] Prova: NorteProjetoTests

        ## Fora de escopo
        - o wizard

        ## Arquivos / módulos prováveis
        - a.swift — por quê

        ## Dependências
        - nenhuma

        _Etiquetas do processo: baixo · claude_
        """)
    }

    func testPromptLevaNorteEMapaEFormato() {
        let p = BrainstormCLI.promptHistorias(ideia: "x", etiquetas: etiquetas, norte: "## §1 Objetivo\nUm app.", mapa: "## Módulos\n- `a/`")
        XCTAssertTrue(p.contains("## §1 Objetivo\nUm app."))
        XCTAssertTrue(p.contains("- `a/`"))
        for campo in ["objetivo:", "norte:", "aceite:", "prova:", "fora:", "arquivos:", "depende:"] {
            XCTAssertTrue(p.contains(campo), campo)
        }
        let sem = BrainstormCLI.promptHistorias(ideia: "x", etiquetas: etiquetas)
        XCTAssertTrue(sem.contains("o projeto não tem norte"))
        XCTAssertTrue(BrainstormCLI.sistemaHistorias.contains("Não invente caminho"))
    }

    func testHistoriasPensamMaisQueOChat() throws {
        let c = try XCTUnwrap(BrainstormCLI.chamada(cli: "claude", prompt: "p", sessao: nil, saidaCodex: nil, papel: .historias))
        XCTAssertEqual(c.argumentos[c.argumentos.firstIndex(of: "--effort")! + 1], "medium")
    }

    func testContextoLeNorteSemGlossarioEMapa() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs/produto"), withIntermediateDirectories: true)
        try "# Norte\n\n## §1 Objetivo\n\nUm app.\n\n## §5 Glossário\n\n- x: y\n"
            .write(to: repo.appendingPathComponent("docs/produto/caminho.md"), atomically: true, encoding: .utf8)
        try "# Mapa\n- `a/`\n".write(to: repo.appendingPathComponent("docs/produto/mapa.md"), atomically: true, encoding: .utf8)
        let semGit: (String, [String]) -> Subprocesso.Resultado = { _, _ in Subprocesso.Resultado(codigo: 128, saida: Data()) }
        let c = CardBrainstorm.contexto(repo: repo, norte: "docs/produto/caminho.md", git: semGit)
        XCTAssertEqual(c.norte, "# Norte\n\n## §1 Objetivo\n\nUm app.")
        XCTAssertEqual(c.mapa, "# Mapa\n- `a/`")
        // Da origin/main quando o git tem: vale mais que o disco (que pode estar atrasado).
        let daMain = CardBrainstorm.contexto(repo: repo, norte: "docs/produto/caminho.md", git: { _, args in
            let pedido = args.last ?? ""
            let texto = pedido.hasSuffix("caminho.md") ? "## §1 Objetivo\nDa main." : "# Mapa da main"
            return Subprocesso.Resultado(codigo: 0, saida: Data(texto.utf8))
        })
        XCTAssertEqual(daMain.norte, "## §1 Objetivo\nDa main.")
        XCTAssertEqual(daMain.mapa, "# Mapa da main")
        let semNada = CardBrainstorm.contexto(repo: repo.appendingPathComponent("vazio"), norte: "")
        XCTAssertNil(semNada.norte)
        XCTAssertNil(semNada.mapa)
    }
}
