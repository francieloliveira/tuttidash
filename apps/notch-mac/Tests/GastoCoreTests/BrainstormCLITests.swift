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
