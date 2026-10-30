import XCTest
@testable import GastoCore

/// Linhas reais do `lanes-dispatcher.log` (29/10) viram frases claras no menu da barra.
final class MensagemLogTests: XCTestCase {
    private let cicloComFreios = """
    2026-10-29 19:52:14 vigia: fila vazia: 8 lane(s) ociosa(s) e nenhum card pronto no Todo nem no Backlog (precisa de esforço e bloqueios em Done); precisa de card pronto
    2026-10-29 19:55:19 vigia: freio: FRA-464 não sobe do Backlog — decisão aberta: «Decisão pendente (antes de puxar)»
    2026-10-29 19:55:19 vigia: freio: FRA-461 não sobe do Backlog — decisão aberta: «Decisão pendente (antes de puxar)»
    2026-10-29 19:55:19 vigia: freio: FRA-458 não sobe do Backlog — decisão aberta: «Decisão pendente (antes de puxar)»
    2026-10-29 19:55:19 vigia: freio: FRA-391 não sobe do Backlog — sem aceite observável (nenhuma linha de aceite nem checkbox)
    2026-10-29 19:55:19 vigia: freio: FRA-389 não sobe do Backlog — sem aceite observável (nenhuma linha de aceite nem checkbox)
    """

    func testFreiosSaoRuidoEViramResumo() {
        let m = MensagemLog.resumir(cicloComFreios)
        XCTAssertEqual(m?.tipo, .fila)
        XCTAssertEqual(m?.texto, "Sem cards prontos no Todo nem no Backlog")
        XCTAssertEqual(m?.detalhe, "5 cards parados no Backlog: 3 esperam decisão sua, 2 sem critério de aceite")
        XCTAssertFalse(m?.texto.contains("2026") ?? true, "a data não aparece no texto")
    }

    func testFreiosDeCicloAntigoNaoContam() {
        let log = cicloComFreios + "\n2026-10-29 19:56:00 vigia: freio: FRA-464 não sobe do Backlog — decisão aberta: «x»"
        // Só o último ciclo de freios conta, e cada card uma vez.
        XCTAssertEqual(MensagemLog.resumir(log)?.detalhe, "1 card parado no Backlog: 1 espera decisão sua")
    }

    func testSoFreiosViramAMensagem() {
        let log = "2026-10-29 19:55:19 vigia: freio: FRA-464 não sobe do Backlog — decisão aberta: «x»"
        let m = MensagemLog.resumir(log)
        XCTAssertEqual(m?.texto, "1 card parado no Backlog: 1 espera decisão sua")
        XCTAssertNil(m?.detalhe)
    }

    func testEventosDasLanes() {
        let casos: [(String, MensagemBarra.Tipo, String)] = [
            ("lane:claude → ASSUME FRA-443 (esforço alto: --model opus --effort xhigh; branch x)", .trabalho, "começou FRA-443"),
            ("lane:claude FECHOU FRA-581 → In Review (https://github.com/x/y/pull/9)", .entrega, "entregou FRA-581 para revisão"),
            ("lane:claude FRA-581: agente terminou; prova do dispatcher em andamento", .trabalho, "terminou FRA-581; testando a entrega"),
            ("lane:claude FRA-581 prova: \t Executed 12 tests, with 2 failures (0 unexpected) in 1.2 (1.3) seconds", .alerta, "Testes de FRA-581 falharam (2 falhas)"),
            ("lane:claude FRA-581 prova: \t Executed 12 tests, with 0 failures (0 unexpected) in 1.2 (1.3) seconds", .entrega, "Testes de FRA-581 passaram"),
            ("lane:opencode em limite da conta até 21:30 (aguardando: FRA-1)", .alerta, "no limite da conta até 21:30"),
            ("lane:opencode-go FECHOU FRA-12 → devolvido à fila até 22:10 (limite de uso, sem falha)", .alerta, "FRA-12 volta para a fila às 22:10"),
            ("lane:codex segura FRA-77: conta em 91% (3 dias); card `alto` só entra abaixo de 80%", .alerta, "segurou FRA-77: conta em 91%"),
            ("vigia: conflito: FRA-5 PR #7 DIRTY → main juntada no worktree (conflito em app)", .alerta, "PR #7 de FRA-5 tem conflito com a main"),
            ("vigia: needs FRA-443: análise feita por ollama/qwen2.5-coder:7b", .info, "FRA-443 analisado: a decisão está em Esperando você"),
            ("vigia: worktree fora da pasta de branches: /private/tmp/pr19 (detached d7996cf); o lugar é /x", .alerta, "Checkout fora da pasta de branches: /private/tmp/pr19"),
            ("vigia: conta Claude sem cota mensal de gasto; vigia tenta de novo às 04:48 (para voltar antes, suba o limite em claude.ai/settings/usage)", .alerta, "Claude sem cota mensal de gasto"),
            ("vigia: conta Claude no limite de uso; vigia pausa a IA até 22:44 e tenta de novo (paradas e revisões ficam pendentes, não perdidas)", .alerta, "Claude no limite até 22:44"),
            ("vigia: conta Claude saiu do limite; vigia volta a analisar paradas e revisar PRs", .info, "Claude voltou"),
            ("vigia: PR #23: segunda opinião APROVADO guardada; esperando a confirmação do Claude (sem cota até 22:44)", .info, "PR #23 aprovado na segunda opinião; falta a confirmação do Claude"),
            ("vigia: PR #23: revisão espera o Claude (sem cota); a segunda opinião roda quando ele voltar", .info, "PR #23 espera o Claude"),
            ("vigia: PR #22 sem card está APROVADO há 6 h; o vigia não mergeia PR sem card: mergeie à mão", .alerta, "PR #22 aprovado e sem card: mergeie à mão"),
            ("vigia: PR #22 sem card está sem APROVADO há 7 h; revise ou mergeie à mão", .alerta, "PR #22 sem card e sem aprovação há 7 h"),
            ("lane:grok livre → fila vazia: precisa de card pronto (In Progress com lane ou x)", .fila, "Sem cards prontos no Todo nem no Backlog"),
        ]
        for (msg, tipo, trecho) in casos {
            let m = MensagemLog.resumir("2026-10-29 19:00:00 " + msg)
            XCTAssertEqual(m?.tipo, tipo, msg)
            XCTAssertTrue(m?.texto.contains(trecho) ?? false, "\(msg) → \(m?.texto ?? "nil")")
        }
    }

    func testRuidoPulaParaOUltimoEvento() {
        let log = """
        2026-10-29 19:00:00 lane:claude FECHOU FRA-581 → In Review (https://github.com/x/y/pull/9)
        2026-10-29 19:01:00 mantendo acordado: caffeinate 123 por 300 s, renovado a cada ciclo
        2026-10-29 19:01:00 lane:claude ocupada com FRA-590
        2026-10-29 19:01:00 fora: FRA-1 (label lane:falhou)
        2026-10-29 19:01:00 FRA-581: 3 proof* antigos arquivados em /tmp/x
        2026-10-29 19:01:00 lane:claude FRA-581 prova: [prova] PoliticaAtualizacaoTests
        2026-10-29 19:01:00 vigia: revisor-app-1: revisão feita por opencode-go (o escolhido, opencode, não respondeu)
        """
        let m = MensagemLog.resumir(log)
        XCTAssertEqual(m?.tipo, .entrega)
        XCTAssertTrue(m?.texto.hasSuffix("entregou FRA-581 para revisão") ?? false)
        XCTAssertNotNil(m?.quando)
    }

    func testLinhaDesconhecidaSaiLimpa() {
        let m = MensagemLog.resumir("2026-10-29 19:00:00 vigia: algo novo aconteceu")
        XCTAssertEqual(m?.tipo, .info)
        XCTAssertEqual(m?.texto, "Algo novo aconteceu")
    }

    func testLogVazioOuSemData() {
        XCTAssertNil(MensagemLog.resumir(""))
        XCTAssertNil(MensagemLog.resumir("\n  \n"))
        XCTAssertEqual(MensagemLog.resumir("linha sem data")?.texto, "Linha sem data")
    }
}
