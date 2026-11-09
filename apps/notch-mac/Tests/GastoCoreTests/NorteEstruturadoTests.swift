import XCTest
@testable import GastoCore

final class NorteEstruturadoTests: XCTestCase {
    private func rascunho() throws -> NorteRascunho.Rascunho {
        try XCTUnwrap(NorteRascunho.ler("""
        NORTE:
        ## 1. Objetivo
        Painel para quem roda agentes em lanes (fonte: README.md)
        ## 2. Restrições inegociáveis
        - R1: Nada pessoal no repositório público (fonte: README.md)
        - R2: palpite: Leitura não oficial ligada por padrão
        ## 3. Desempate
        1. Freios vencem concluir o card (fonte: lanes/README.md)
        2. Segurança vence velocidade
        ## 4. O que nunca se faz
        (a definir pelo dono)
        ## 5. Glossário
        - lane: fila de um agente
        PERGUNTAS:
        - [§4] O que nunca pode acontecer num card?
          sugestão: Merge sem prova verde (fonte: lanes/README.md)
        - Quem é o público?
          sugestão: palpite: qualquer dev com projeto no Linear
        """))
    }

    func testRascunhoViraPassosComItensEOrigem() throws {
        let n = NorteEstruturado.de(try rascunho())
        XCTAssertEqual(n.objetivo, "Painel para quem roda agentes em lanes.")
        XCTAssertEqual(n.itens[1].map(\.texto), ["Nada pessoal no repositório público.", "Leitura não oficial ligada por padrão"])
        XCTAssertEqual(n.itens[1][0].fonte, "README.md")
        XCTAssertTrue(n.itens[1][0].marcado)
        XCTAssertTrue(n.itens[1][1].palpite)
        XCTAssertFalse(n.itens[1][1].marcado, "palpite começa desmarcado: o dono confere")
        XCTAssertEqual(n.itens[2].map(\.texto), ["Freios vencem concluir o card.", "Segurança vence velocidade"])
        XCTAssertEqual(n.itens[3], [], "a definir não vira item")
        XCTAssertEqual(n.itens[4].map(\.texto), ["lane: fila de um agente"])
        XCTAssertEqual(n.perguntas.map(\.passo), [3, 0], "[§4] vai para o passo 4; sem marca, para o Objetivo")
        XCTAssertEqual(n.perguntas[0].texto, "O que nunca pode acontecer num card?")
    }

    func testProntidaoEPrimeiroPendente() throws {
        var n = NorteEstruturado.de(try rascunho())
        XCTAssertNil(n.pendencia(0))
        XCTAssertNil(n.pendencia(1))
        XCTAssertNotNil(n.pendencia(3))
        XCTAssertNil(n.pendencia(4), "glossário é opcional")
        XCTAssertEqual(n.primeiroPendente, 3)
        n.responder(n.perguntas[0].id, com: n.perguntas[0].sugestao)
        XCTAssertEqual(n.itens[3].map(\.texto), ["Merge sem prova verde."])
        XCTAssertTrue(n.perguntas[0].resolvida)
        XCTAssertNil(n.primeiroPendente)
    }

    func testRespostaDoObjetivoEntraNoTexto() throws {
        var n = NorteEstruturado.de(try rascunho())
        n.responder(n.perguntas[1].id, com: "Para qualquer dev com projeto no Linear.")
        XCTAssertEqual(n.objetivo, "Painel para quem roda agentes em lanes. Para qualquer dev com projeto no Linear.")
        XCTAssertTrue(n.objetivoEditado)
    }

    func testMarkdownSoComOMarcadoESemOrigem() throws {
        var n = NorteEstruturado.de(try rascunho())
        n.responder(n.perguntas[0].id, com: "Merge sem prova verde")
        let md = n.markdown(nome: "TuttiDash")
        XCTAssertTrue(md.contains("## §2 Restrições inegociáveis\n\n- R1: Nada pessoal no repositório público."))
        XCTAssertFalse(md.contains("Leitura não oficial"), "palpite desmarcado não entra")
        XCTAssertTrue(md.contains("1. Freios vencem concluir o card.\n2. Segurança vence velocidade"))
        XCTAssertTrue(md.contains("## §4 O que nunca se faz\n\n- Merge sem prova verde"))
        XCTAssertFalse(md.contains("fonte:"))
        XCTAssertNil(NorteProjeto.problema(md), "o arquivo montado passa na trava do instalador")
    }

    func testSugerirDeNovoNaoMexeNoQueODonoMarcouOuEditou() throws {
        var n = NorteEstruturado.de(try rascunho())
        n.itens[1].append(.init(texto: "Minha regra", marcado: true, editado: true))
        var novo = NorteEstruturado()
        novo.itens[1] = [.init(texto: "Nada pessoal no repositório público."), .init(texto: "Regra nova")]
        novo.perguntas = [.init(passo: 1, texto: "Nova?", sugestao: "")]
        n.mesclar(passo: 1, com: novo)
        XCTAssertEqual(n.itens[1].map(\.texto), ["Nada pessoal no repositório público.", "Minha regra", "Regra nova"],
                       "o palpite desmarcado sai; o marcado e o editado ficam; repetido não duplica")
        XCTAssertTrue(n.perguntas.contains { $0.texto == "Nova?" })
        n.objetivoEditado = true
        var obj = NorteEstruturado(); obj.objetivo = "Outro"
        n.mesclar(passo: 0, com: obj)
        XCTAssertEqual(n.objetivo, "Painel para quem roda agentes em lanes.")
    }

    func testSemAgenteComecaVazioEPendente() {
        let n = NorteEstruturado()
        XCTAssertEqual(n.primeiroPendente, 0)
        XCTAssertEqual(NorteEstruturado.ajuda(4).isEmpty, false)
    }
}
