import XCTest
@testable import GastoCore

/// Leituras não oficiais no código aberto, desligadas conta a conta; OpenCode Go e DeepSeek.
final class UsoNaoOficialTests: XCTestCase {

    // MARK: OpenCode Go (Console)

    /// Formato real de 08/11/2026: micro-cents como texto.
    static let respostaGo = #"""
    {"product":"go","useBalance":false,"access":{"meters":{
      "fiveHour":{"startsAt":null,"resetsAt":null,"limitMicroCents":"1200000000","usedMicroCents":"0"},
      "week":{"resetsAt":"2026-11-09T00:00:00.000Z","limitMicroCents":"3000000000","usedMicroCents":"0"},
      "month":{"resetsAt":"2026-11-18T00:10:06.000Z","limitMicroCents":"6000000000","usedMicroCents":"6000000000"}}}}
    """#

    func testOpenCodeGoAceitaMicroCentsComoTexto() throws {
        let janelas = try ParserUsoOpenCode.ler(Data(Self.respostaGo.utf8)).get()
        XCTAssertEqual(janelas.map(\.chave), ["fiveHour", "week", "month"])
        XCTAssertEqual(janelas.map(\.pct), [0, 0, 100])
        XCTAssertNotNil(janelas[2].resetEm)
    }

    func testOpenCodeGoAceitaNumero() throws {
        let corpo = #"{"product":"go","access":{"meters":{"week":{"limitMicroCents":200,"usedMicroCents":50}}}}"#
        XCTAssertEqual(try ParserUsoOpenCode.ler(Data(corpo.utf8)).get().first?.pct, 25)
    }

    func testOpenCodeGoTextoInvalidoNaoViraNumero() {
        let corpo = #"{"product":"go","access":{"meters":{"week":{"limitMicroCents":"abc","usedMicroCents":"1"}}}}"#
        XCTAssertEqual(ParserUsoOpenCode.ler(Data(corpo.utf8)), .failure(.semJanelas))
    }

    // MARK: DeepSeek

    func testDeepSeekSomaRecargaEBonusEmUSD() {
        let corpo = #"""
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
          "normal_wallets":[{"currency":"USD","balance":"2.5100941310000000","token_estimation":"0"},
                            {"currency":"CNY","balance":"9"}],
          "bonus_wallets":[{"currency":"USD","balance":"0.5","token_estimation":"0"}],
          "total_costs":[{"currency":"USD","amount":"2.48"}]}}}
        """#
        guard case .failure(.apenasSaldo(let v)) = ParserUsoDeepSeek.ler(Data(corpo.utf8)) else {
            return XCTFail("esperava saldo")
        }
        XCTAssertEqual(v, 3.0100941310, accuracy: 1e-9)
    }

    func testDeepSeekAutorizacaoInvalida() {
        XCTAssertEqual(ParserUsoDeepSeek.ler(Data(#"{"code":40003,"msg":"x"}"#.utf8)), .failure(.naoAutorizado))
        let biz = #"{"code":0,"data":{"biz_code":40003,"biz_data":null}}"#
        XCTAssertEqual(ParserUsoDeepSeek.ler(Data(biz.utf8)), .failure(.naoAutorizado))
    }

    func testDeepSeekSemUSDOuIlegivel() {
        let cny = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"1"}]}}}"#
        XCTAssertEqual(ParserUsoDeepSeek.ler(Data(cny.utf8)), .failure(.motivo("DeepSeek sem carteira em USD")))
        let ruim = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"NaN?"}]}}}"#
        XCTAssertEqual(ParserUsoDeepSeek.ler(Data(ruim.utf8)), .failure(.respostaIlegivel))
        XCTAssertEqual(ParserUsoDeepSeek.ler(Data("nada".utf8)), .failure(.respostaIlegivel))
    }

    func testCredencialDeepSeekSoDoRegistroDaConta() throws {
        let yaml = """
        version: 1
        records:
          client-connection/browser-session:
            kind: x
            payload:
              version: 1
              secret: nao-e-este
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: "tok-123"
              issuer: https://platform.deepseek.com
          outro/registro:
            payload:
              token: errado
        """
        XCTAssertEqual(try CredenciaisDeepSeek.ler(Data(yaml.utf8)).get().valor, "tok-123")
        let sem = "records:\n  deepseek-account-platform/default:\n    payload:\n      issuer: x\n  outro:\n    token: errado\n"
        XCTAssertEqual(CredenciaisDeepSeek.ler(Data(sem.utf8)), .failure(.semCredencial("dsh")))
    }

    // MARK: Código tipado

    func testCodigosDosMotivosSemJanela() {
        XCTAssertEqual(ErroUso.semJanelas.codigo, "sem_janelas")
        XCTAssertEqual(ErroUso.semLimiteIncluido.codigo, "sem_limite_incluido")
        XCTAssertEqual(ErroUso.cotaCompartilhada.codigo, "cota_compartilhada")
        XCTAssertEqual(ErroUso.apenasSaldo(1).codigo, "saldo")
        XCTAssertEqual(ErroUso.apenasSaldo(1.234).saldoUSD, 1.234)
        XCTAssertEqual(ErroUso.naoAutorizado.codigo, "token_recusado")
        XCTAssertEqual(ErroUso.naoOficialDesligado.codigo, "nao_oficial_desligado")
    }

    // MARK: Opt-in por conta

    private func cfg(_ contas: [ContaUso]) throws -> (Configuracao, PastaTemp) {
        let temp = try PastaTemp()
        var c = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": "1"], home: temp.url)
        c.contas = contas
        return (c, temp)
    }

    func testNaoOficialDesligadoNaoLeCredencialNemChamaARede() async throws {
        let (c, temp) = try cfg([ContaUso(id: "deepseek", tipo: "deepseek", rotulo: "DeepSeek")])
        let t = TransporteFalso([:])
        let lido = Lido()
        let usos = await ColetorUso(transporte: t, ler: { _ in lido.marcar(); return nil },
                                    fontes: [FonteDeepSeek()]).coletar(config: c)
        XCTAssertEqual(usos.first?.codigo, "nao_oficial_desligado")
        XCTAssertTrue(t.chamadas.isEmpty)
        XCTAssertFalse(lido.foi)
        _ = temp
    }

    func testNaoOficialLigadoLeOSaldo() async throws {
        var conta = ContaUso(id: "deepseek", tipo: "deepseek", rotulo: "DeepSeek")
        conta.naoOficial = true
        let (c, temp) = try cfg([conta])
        let yaml = "records:\n  deepseek-account-platform/default:\n    payload:\n      token: tok-9\n"
        let corpo = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"2.51"}],"bonus_wallets":[]}}}"#
        let t = TransporteFalso(json: ["platform.deepseek.com": corpo])
        let usos = await ColetorUso(transporte: t, ler: { _ in Data(yaml.utf8) },
                                    fontes: [FonteDeepSeek()]).coletar(config: c)
        let u = try XCTUnwrap(usos.first)
        XCTAssertEqual(u.codigo, "saldo")
        XCTAssertEqual(try XCTUnwrap(u.saldoUSD), 2.51, accuracy: 1e-9)
        XCTAssertEqual(u.motivo, "saldo US$ 2.51")
        XCTAssertNotNil(u.atualizadoEm)
        XCTAssertEqual(t.cabecalhos("platform.deepseek.com")?["x-dsh-auth-token"], "tok-9")
        _ = temp
    }

    func testOpenCodeZenNaoTemMedidorMasTemFolga() async throws {
        let (c, temp) = try cfg([ContaUso(id: "opencode", tipo: "opencode", rotulo: "OpenCode")])
        let t = TransporteFalso([:])
        let usos = await ColetorUso(transporte: t, fontes: [FonteOpenCodeZen()]).coletar(config: c)
        XCTAssertEqual(usos.first?.codigo, "sem_limite_incluido")
        XCTAssertTrue(t.chamadas.isEmpty)
        _ = temp
    }

    func testContaGravaNaoOficialSoQuandoLigado() throws {
        var conta = try XCTUnwrap(ContaUso(dict: ["id": "codex", "tipo": "codex", "nao_oficial": true]))
        XCTAssertTrue(conta.naoOficial)
        XCTAssertEqual(conta.dict["nao_oficial"] as? Bool, true)
        conta.naoOficial = false
        XCTAssertNil(conta.dict["nao_oficial"])
        XCTAssertFalse(try XCTUnwrap(ContaUso(dict: ["id": "codex", "tipo": "codex"])).naoOficial)
    }
}

extension UsoNaoOficialTests {
    /// A conta `opencode-go` (tipo = nome do agente) entra na medição e usa o medidor do plano Go.
    func testContaOpenCodeGoEhMedidaPeloPlanoGo() async throws {
        let conta = try XCTUnwrap(ContaUso(dict: ["id": "opencode-go", "tipo": "opencode-go", "nao_oficial": true]))
        let temp = try PastaTemp()
        var c = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USO_CONTAS": "1"], home: temp.url)
        c.contas = [conta]
        let t = TransporteFalso(json: ["opencode.ai": Self.respostaGo])
        let fonte = FonteOpenCodeConsole()
        XCTAssertEqual(fonte.tipo, "opencode-go")
        let usos = await ColetorUso(transporte: t, ler: { _ in Data(#"{"token":"a"}"#.utf8) },
                                    fontes: [fonte]).coletar(config: c)
        _ = temp
        let u = try XCTUnwrap(usos.first)
        XCTAssertEqual(u.conta, "opencode-go")
        XCTAssertEqual(u.critica?.pct, 100, "o mês do Go em 100%: \(u.motivo ?? "")")
    }
}
