import Foundation

/// Uso do Gemini CLI pelo endpoint interno do Cloud Code
/// (`POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`).
///
/// ```json
/// { "buckets": [
///     { "modelId": "gemini-2.5-pro", "tokenType": "REQUESTS",
///       "remainingFraction": 0.75, "resetTime": "2026-10-25T03:00:00Z" } ] }
/// ```
///
/// `remainingFraction` é o que **sobra** (1 = cheio). O painel mostra o que já foi
/// usado: `(1 - remainingFraction) * 100`. Balde sem fração não entra — nunca vira 0%.
/// Dois baldes do mesmo modelo ficam com o mais apertado.
///
/// Antes da cota, `loadCodeAssist` diz se a conta consumer (Google AI Pro/Ultra)
/// foi barrada (`ineligibleTiers[].reasonCode == UNSUPPORTED_CLIENT`, sem tier
/// em serviço). Nesse caso a cota não é chamada.
public enum ParserUsoGemini {
    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        guard let buckets = obj["buckets"] as? [Any] else { return .failure(.semJanelas) }
        var porChave: [String: JanelaUso] = [:]
        var ordem: [String: Int] = [:]
        for item in buckets {
            guard let m = item as? [String: Any],
                  let frac = JV.numero(m["remainingFraction"]),
                  frac.isFinite, frac >= 0, frac <= 1 else { continue }
            let modelo = JV.texto(m["modelId"])
            let chave = modelo ?? JV.texto(m["tokenType"]) ?? "cota"
            let janela = JanelaUso(chave: chave, rotulo: rotulo(modelo), pct: (1 - frac) * 100,
                                   resetEm: JV.texto(m["resetTime"]).flatMap { Datas.lerISO8601($0) })
            if let atual = porChave[chave], atual.pct >= janela.pct { continue }
            porChave[chave] = janela
            ordem[chave] = familia(modelo)
        }
        let saida = porChave.values.sorted { a, b in
            let oa = ordem[a.chave] ?? 3
            let ob = ordem[b.chave] ?? 3
            if oa != ob { return oa < ob }
            return a.chave < b.chave
        }
        return saida.isEmpty ? .failure(.semJanelas) : .success(saida)
    }

    /// Projeto da cota, ou erro quando a conta consumer está barrada.
    /// Sucesso com `nil` = sem `cloudaicompanionProject`; a cota segue com corpo `{}`.
    public static func classificarAssist(_ dados: Data) -> Result<String?, ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        if consumerBarrada(obj) { return .failure(.contaConsumerBarrada) }
        return .success(JV.texto(obj["cloudaicompanionProject"]))
    }

    /// HTTP 200 sem tier em serviço e com `UNSUPPORTED_CLIENT`. Um `currentTier`
    /// ou `paidTier.name` significa que a conta ainda é atendida.
    static func consumerBarrada(_ obj: [String: Any]) -> Bool {
        let tiers = obj["ineligibleTiers"] as? [Any] ?? []
        let barrada = tiers.contains { item in
            guard let d = item as? [String: Any] else { return false }
            return JV.texto(d["reasonCode"]) == "UNSUPPORTED_CLIENT"
        }
        guard barrada else { return false }
        if let atual = obj["currentTier"] as? [String: Any],
           JV.texto(atual["id"]) != nil || JV.texto(atual["name"]) != nil {
            return false
        }
        if let pago = obj["paidTier"] as? [String: Any], JV.texto(pago["name"]) != nil {
            return false
        }
        return true
    }

    /// Corpo do `loadCodeAssist`. `ideType` é o enum que esse endpoint documenta
    /// para a cota do Gemini CLI. O `User-Agent` da chamada é o do TuttiDash,
    /// não o de um cliente Google.
    public static func corpoLoad() -> Data {
        let obj: [String: Any] = [
            "metadata": [
                "ideType": "GEMINI_CLI",
                "pluginType": "GEMINI",
                "ideName": Produto.nome,
                "pluginVersion": Produto.versao,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    public static func corpoCota(projeto: String?) -> Data {
        var obj: [String: Any] = [:]
        if let projeto, !projeto.isEmpty { obj["project"] = projeto }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static func rotulo(_ modelo: String?) -> String {
        guard let modelo else { return "cota" }
        return modelo.hasPrefix("gemini-") ? String(modelo.dropFirst("gemini-".count)) : modelo
    }

    /// Pro antes de Flash, Flash Lite por último. O resto fica depois, em ordem alfabética.
    static func familia(_ modelo: String?) -> Int {
        let m = (modelo ?? "").lowercased()
        if m.contains("flash") && m.contains("lite") { return 2 }
        if m.contains("flash") { return 1 }
        if m.contains("pro") { return 0 }
        return 3
    }
}

/// As duas chamadas do Gemini: `loadCodeAssist` e, se a conta for atendida, a cota.
/// Nenhum dos dois renova token nem grava em `~/.gemini`.
public enum ConsultaGemini {
    public static func cabecalhos(_ t: TokenConta) -> [String: String] {
        [
            "Authorization": "Bearer \(t.valor)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": Produto.userAgent,
        ]
    }

    public static func preparar(transporte: TransporteHTTP, token: TokenConta) async -> Result<Data?, ErroUso> {
        let resposta: RespostaHTTP
        do {
            resposta = try await transporte.enviar(
                FontesNaoOficiais.urlGeminiAssist, metodo: "POST",
                cabecalhos: cabecalhos(token), corpo: ParserUsoGemini.corpoLoad())
        } catch {
            let detalhe = (error as? URLError).map { "\($0.code.rawValue)" } ?? "\(error)"
            return .failure(.rede(detalhe))
        }
        switch resposta.status {
        case 200:
            break
        case 401, 403:
            return .failure(.naoAutorizado)
        case 429:
            return .failure(.limitado)
        default:
            return .failure(.http(resposta.status))
        }
        switch ParserUsoGemini.classificarAssist(resposta.corpo) {
        case .failure(let e):
            return .failure(e)
        case .success(let projeto):
            return .success(ParserUsoGemini.corpoCota(projeto: projeto))
        }
    }
}
