import XCTest
@testable import GastoCore

final class BrainstormCLITests: XCTestCase {
    func testSistemaNaoMandaVarrerORepositorio() {
        XCTAssertTrue(BrainstormCLI.sistema.contains("Não percorra o repositório"))
        XCTAssertTrue(BrainstormCLI.sistema.contains("Não edite arquivos"))
        XCTAssertFalse(BrainstormCLI.sistema.contains("Leia o código"))
        XCTAssertFalse(BrainstormCLI.sistema.contains("leia os docs"))
    }

    func testPromptFrioTrazAConversaEOretomadoNaoRele() {
        let historico: [(agente: Bool, texto: String)] = [(agente: true, texto: "olá"), (agente: false, texto: "e o furo?")]
        let frio = BrainstormCLI.prompt(mensagem: "simplificar", ideia: "um painel", historias: ["Card [medio/claude]"],
                                        historico: historico, retomando: false)
        XCTAssertTrue(frio.contains("Ideia:\num painel"))
        XCTAssertTrue(frio.contains("Pedido:\nsimplificar"))
        XCTAssertTrue(frio.contains("Card [medio/claude]"))
        XCTAssertTrue(frio.contains("Agente: olá"))
        XCTAssertTrue(frio.contains("Pessoa: e o furo?"))

        let cheio = (0..<9).map { (agente: false, texto: "m\($0)") }
        let cortado = BrainstormCLI.prompt(mensagem: "de novo", ideia: "", historias: [],
                                            historico: cheio, retomando: false)
        XCTAssertFalse(cortado.contains("m0"))
        XCTAssertTrue(cortado.contains("m1"))
        XCTAssertTrue(cortado.contains("m8"))

        let seguido = BrainstormCLI.prompt(mensagem: "de novo", ideia: "um painel", historias: [],
                                            historico: historico, retomando: true)
        XCTAssertFalse(seguido.contains("Conversa:"))
        XCTAssertFalse(seguido.contains("olá"))
        XCTAssertTrue(seguido.contains("sem reler o repositório"))
        XCTAssertTrue(seguido.contains("de novo"))
        XCTAssertTrue(seguido.contains("ITENS:"))
        XCTAssertTrue(frio.contains("ITENS:"))
    }

    func testSeparaItensELimpaAReescrita() {
        let bruto = """
        O furo é a fila.

        ITENS:
        - Mostrar a fila vazia
        - Limitar a três histórias
        nota solta
        """
        let fala = BrainstormCLI.separarItens(bruto)
        XCTAssertEqual(fala.texto, "O furo é a fila.")
        XCTAssertEqual(fala.itens, ["Mostrar a fila vazia", "Limitar a três histórias"])

        let sem = BrainstormCLI.separarItens("só conversa")
        XCTAssertEqual(sem.texto, "só conversa")
        XCTAssertTrue(sem.itens.isEmpty)

        let pedido = BrainstormCLI.promptReescrita(ideia: "um painel", conversa: "Pessoa: e a fila?", itens: ["fila vazia"])
        XCTAssertTrue(pedido.contains("um painel"))
        XCTAssertTrue(pedido.contains("fila vazia"))
        XCTAssertTrue(pedido.contains("e a fila?"))
        XCTAssertTrue(pedido.contains("acrescente"))
        XCTAssertTrue(pedido.contains("só o texto novo"))
        XCTAssertTrue(BrainstormCLI.promptReescrita(ideia: "  ", conversa: "", itens: ["fila"]).contains("ainda vazia"))

        let limpo = BrainstormCLI.textoReescrito("```\nIdéia: painel com fila vazia\n```")
        XCTAssertEqual(limpo, "painel com fila vazia")
        XCTAssertEqual(BrainstormCLI.textoReescrito("\"painel\""), "painel")
    }

    func testReescritaNaoAbreFerramentaEMantemASessaoPropria() {
        let fria = BrainstormCLI.chamada(cli: "claude", prompt: "incorpore", sessao: nil,
                                          saidaCodex: nil, papel: .reescrita)
        let args = fria?.argumentos ?? []
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args.last, BrainstormCLI.sistemaReescrita)
        XCTAssertTrue(BrainstormCLI.sistemaReescrita.contains("Não percorra o repositório"))
        XCTAssertTrue(BrainstormCLI.sistemaReescrita.contains("Não edite arquivos"))
        XCTAssertFalse(BrainstormCLI.sistemaReescrita.contains("ITENS:"))

        let seguida = BrainstormCLI.chamada(cli: "claude", prompt: "de novo", sessao: "abc-123",
                                             saidaCodex: nil, papel: .reescrita)
        let retomada = seguida?.argumentos ?? []
        XCTAssertEqual(seguida?.retomando, true)
        XCTAssertEqual(retomada[retomada.firstIndex(of: "--resume")! + 1], "abc-123")
        XCTAssertEqual(retomada[retomada.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertFalse(retomada.contains("--append-system-prompt"))
        XCTAssertFalse(retomada.contains("Read,Grep,Glob"))
    }

    func testHistoriasSaemDaIdeiaComParDoCatalogo() {
        let etiquetas = [
            BrainstormCLI.EtiquetaLane(nome: "claude", esforcos: ["baixo", "medio", "alto"]),
            BrainstormCLI.EtiquetaLane(nome: "opencode", esforcos: ["baixo", "medio"]),
        ]
        let soLigadas = BrainstormCLI.etiquetas(
            lanes: [("claude", ["baixo", "medio", "alto"]), ("opencode", ["baixo", "medio"]), ("cursor", [])],
            habilitadas: ["opencode"])
        XCTAssertEqual(soLigadas.map(\.nome), ["opencode"])
        XCTAssertEqual(BrainstormCLI.etiquetas(
            lanes: [("claude", ["baixo", "medio"])], habilitadas: []).map(\.nome), ["claude"])

        let pedido = BrainstormCLI.promptHistorias(ideia: "três larguras no dashboard", etiquetas: etiquetas)
        XCTAssertTrue(pedido.contains("três larguras no dashboard"))
        XCTAssertTrue(pedido.contains("claude: baixo, medio, alto"))
        XCTAssertTrue(pedido.contains("opencode: baixo, medio"))
        XCTAssertTrue(pedido.contains("pedaço diferente"))
        XCTAssertTrue(BrainstormCLI.sistemaHistorias.contains("Não percorra o repositório"))
        XCTAssertTrue(BrainstormCLI.sistemaHistorias.contains("Não edite arquivos"))
        XCTAssertFalse(BrainstormCLI.sistemaHistorias.contains("ITENS:"))

        let chamada = BrainstormCLI.chamada(cli: "claude", prompt: pedido, sessao: nil,
                                             saidaCodex: nil, papel: .historias)
        let args = chamada?.argumentos ?? []
        XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "1")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args.last, BrainstormCLI.sistemaHistorias)

        let bruto = """
        Texto solto que não é card.

        ```
        HISTORIA:
        titulo: Três larguras
        descricao: Como quem usa
        Eu quero celular, tablet e desktop
        Para que cada largura defina o que fica
        criterios:
        - Celular empilha
        - Desktop guarda a preferência
        prioridade: 2
        estimativa: 5
        esforco: medio
        lane: claude

        HISTORIA:
        titulo: Span que não empurra o vizinho
        descricao: Como quem monta o quadro Eu quero mínimo e máximo Para que o card não abra buraco
        criterios:
        - Span com mínimo e máximo
        esforco: baixo
        lane: inventada

        HISTORIA:
        titulo: Span que não empurra o vizinho
        descricao: repetida
        esforco: alto
        lane: claude
        ```
        """
        let lista = BrainstormCLI.historias(de: bruto, etiquetas: etiquetas)
        XCTAssertEqual(lista.count, 2)
        XCTAssertEqual(lista[0].titulo, "Três larguras")
        XCTAssertEqual(lista[0].esforco, "medio")
        XCTAssertEqual(lista[0].lane, "claude")
        XCTAssertEqual(lista[0].prioridade, 2)
        XCTAssertEqual(lista[0].criterios, ["Celular empilha", "Desktop guarda a preferência"])
        XCTAssertTrue(lista[0].descricao.contains("Para que cada largura"))
        XCTAssertEqual(lista[1].esforco, "baixo")
        XCTAssertEqual(lista[1].lane, "claude")
        XCTAssertEqual(lista[1].estimativa, 3)

        let fora = """
        HISTORIA:
        titulo: Miolo
        esforco: xhigh
        lane: grok
        HISTORIA:
        titulo: Outro miolo
        esforco: medio
        lane: nenhuma
        """
        let ajustadas = BrainstormCLI.historias(de: fora, etiquetas: etiquetas)
        XCTAssertEqual(ajustadas.map(\.lane), ["claude", "opencode"])
        XCTAssertEqual(ajustadas.map(\.esforco), ["medio", "medio"])
    }

    func testFilaNaoEncadeiaOSegundoCLIQuandoJaHaUm() {
        XCTAssertEqual(BrainstormCLI.fila(preferida: "claude", escolhida: nil, claudeFora: false),
                       ["claude", "opencode"])
        XCTAssertEqual(BrainstormCLI.fila(preferida: "claude", escolhida: nil, claudeFora: true),
                       ["opencode"])
        XCTAssertEqual(BrainstormCLI.fila(preferida: "claude", escolhida: "opencode", claudeFora: false),
                       ["opencode", "claude"])
        XCTAssertEqual(BrainstormCLI.fila(preferida: "opencode", escolhida: nil, claudeFora: false),
                       ["opencode"])
        XCTAssertEqual(BrainstormCLI.fila(preferida: "grok", escolhida: "grok", claudeFora: false),
                       ["grok", "opencode"])
    }

    func testClaudeDeChatNaoEntraEmPlanERetomaASessao() {
        let primeira = BrainstormCLI.chamada(cli: "claude", prompt: "oi", sessao: nil, saidaCodex: nil)
        let args = primeira?.argumentos ?? []
        XCTAssertEqual(primeira?.stdin, "oi")
        XCTAssertEqual(primeira?.retomando, false)
        XCTAssertTrue(args.contains("--permission-mode"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertFalse(args.contains("plan"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "Read,Grep,Glob")
        XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "3")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "low")
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertEqual(args.last, BrainstormCLI.sistema)

        let seguida = BrainstormCLI.chamada(cli: "claude", prompt: "e agora", sessao: "abc-123", saidaCodex: nil)
        let retomada = seguida?.argumentos ?? []
        XCTAssertEqual(seguida?.retomando, true)
        XCTAssertEqual(seguida?.stdin, "e agora")
        XCTAssertEqual(retomada[retomada.firstIndex(of: "--resume")! + 1], "abc-123")
        XCTAssertEqual(retomada[retomada.firstIndex(of: "--max-turns")! + 1], "2")
        XCTAssertFalse(retomada.contains("--append-system-prompt"))
        XCTAssertFalse(retomada.contains("Edit"))
        XCTAssertFalse(retomada.contains("Bash"))
    }

    func testSessaoInvalidaNaoVaiParaOArgv() {
        let c = BrainstormCLI.chamada(cli: "claude", prompt: "oi", sessao: "a;rm -rf", saidaCodex: nil)
        XCTAssertFalse(c?.argumentos.contains("--resume") == true)
        XCTAssertEqual(c?.retomando, false)
    }

    func testOpenCodeRapidoRetomaPeloIdENaoRepeteOSistema() {
        let primeira = BrainstormCLI.chamada(cli: "opencode", prompt: "oi", sessao: nil, saidaCodex: nil)
        let args = primeira?.argumentos ?? []
        XCTAssertEqual(args[args.firstIndex(of: "-m")! + 1], "opencode/glm-5.3-flash-free")
        XCTAssertEqual(args[args.firstIndex(of: "--agent")! + 1], "plan")
        XCTAssertFalse(args.contains("--session"))
        XCTAssertTrue(args.last?.contains("Não percorra o repositório") == true)
        XCTAssertNil(primeira?.stdin)

        let seguida = BrainstormCLI.chamada(cli: "opencode", prompt: "só isso", sessao: "ses_abc", saidaCodex: nil)
        let retomada = seguida?.argumentos ?? []
        XCTAssertEqual(retomada[retomada.firstIndex(of: "--session")! + 1], "ses_abc")
        XCTAssertEqual(retomada.last, "só isso")
        XCTAssertEqual(seguida?.retomando, true)
    }

    func testGrokDeChatNaoUsaEsforcoAlto() {
        let c = BrainstormCLI.chamada(cli: "grok", prompt: "oi", sessao: nil, saidaCodex: nil)
        let args = c?.argumentos ?? []
        XCTAssertEqual(args[args.firstIndex(of: "-m")! + 1], "grok-4.7-build-fast")
        XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "4")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "read_file,grep,list_dir")
        XCTAssertFalse(args.contains("--effort"))
        XCTAssertFalse(args.contains("high"))
        XCTAssertTrue(args.last?.contains("Não percorra o repositório") == true)
    }

    func testCodexContinuaSoLeitura() {
        let c = BrainstormCLI.chamada(cli: "codex", prompt: "oi", sessao: "s1", saidaCodex: "/tmp/saida.txt")
        let args = c?.argumentos ?? []
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(args[args.firstIndex(of: "--output-last-message")! + 1], "/tmp/saida.txt")
        XCTAssertEqual(args[args.firstIndex(of: "-c")! + 1], "model_reasoning_effort=low")
        XCTAssertEqual(args.last, "-")
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertTrue(c?.stdin?.contains("Não percorra o repositório") == true)
        XCTAssertNil(BrainstormCLI.chamada(cli: "codex", prompt: "oi", sessao: nil, saidaCodex: nil))
        XCTAssertNil(BrainstormCLI.chamada(cli: "cursor", prompt: "oi", sessao: nil, saidaCodex: nil))
    }

    func testSoCaiNoProximoCLISemSessaoOuSemFlag() {
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "not logged in", codigo: 1, semLogin: true, tinhaSessao: false),
                       .proximo)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "sem modo", codigo: 127, semLogin: false, tinhaSessao: false),
                       .proximo)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "error: unknown option '--max-turns'", codigo: 2,
                                              semLogin: false, tinhaSessao: false), .proximo)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "rate limit", codigo: 1, semLogin: false, tinhaSessao: false),
                       .parar)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "No conversation found", codigo: 1, semLogin: false, tinhaSessao: true),
                       .recomecar)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "session not found", codigo: 1, semLogin: false, tinhaSessao: false),
                       .parar)
        XCTAssertEqual(BrainstormCLI.seguinte(texto: "", codigo: nil, semLogin: false, tinhaSessao: false), .parar)
    }

    func testInterpretarClaudeEOpenCode() {
        let claude = """
        {"type":"system","subtype":"init","session_id":"sid-1"}
        {"type":"result","subtype":"success","is_error":false,"session_id":"sid-1","result":"O furo é a fila."}
        """
        let lido = BrainstormCLI.interpretar(cli: "claude", saida: claude)
        XCTAssertEqual(lido.texto, "O furo é a fila.")
        XCTAssertEqual(lido.sessao, "sid-1")
        XCTAssertFalse(lido.erro)

        let falha = #"{"type":"result","subtype":"error","is_error":true,"result":"not logged in"}"#
        XCTAssertTrue(BrainstormCLI.interpretar(cli: "claude", saida: falha).erro)

        let oc = """
        {"type":"step_start","sessionID":"ses_9","part":{}}
        {"type":"text","sessionID":"ses_9","part":{"text":"Uma proposta."}}
        {"type":"tool_use","sessionID":"ses_9","part":{"text":"não mostrar"}}
        """
        let resposta = BrainstormCLI.interpretar(cli: "opencode", saida: oc)
        XCTAssertEqual(resposta.texto, "Uma proposta.")
        XCTAssertEqual(resposta.sessao, "ses_9")
        XCTAssertFalse(resposta.erro)

        let cru = BrainstormCLI.interpretar(cli: "grok", saida: "  texto puro  ")
        XCTAssertEqual(cru.texto, "texto puro")
        XCTAssertNil(cru.sessao)
    }
}
