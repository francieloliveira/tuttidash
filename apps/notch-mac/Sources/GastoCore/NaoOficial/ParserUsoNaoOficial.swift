import Foundation

/// Resposta do `GET https://api.anthropic.com/api/oauth/usage` (mesma fonte que o CodexBar usa):
///
/// ```json
/// { "five_hour":  { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
///   "seven_day":  { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
///   "seven_day_opus": null,
///   "seven_day_sonnet": { "utilization": 1.0, "resets_at": "..." } }
/// ```
///
/// Janela ausente ou `null` simplesmente não aparece (não vira 0%).
public enum ParserUsoClaude {
    /// Ordem fixa no painel: a janela de 5 h primeiro, depois a semana, depois as por modelo.
    public static let janelas: [(chave: String, rotulo: String)] = [
        ("five_hour", "5 h"),
        ("seven_day", "semana"),
        ("seven_day_opus", "semana · opus"),
        ("seven_day_sonnet", "semana · sonnet"),
    ]

    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        var saida: [JanelaUso] = []
        for (chave, rotulo) in janelas {
            guard let d = obj[chave] as? [String: Any], let pct = JV.numero(d["utilization"]) else { continue }
            let reset = JV.texto(d["resets_at"]).flatMap { Datas.lerISO8601($0) }
            saida.append(JanelaUso(chave: chave, rotulo: rotulo, pct: pct, resetEm: reset))
        }
        return saida.isEmpty ? .failure(.semJanelas) : .success(saida)
    }
}

/// Resposta do `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (a mesma API de
/// billing do grok CLI que o CodexBar consulta com o token local):
///
/// ```json
/// { "config": { "creditUsagePercent": 42.0, "currentPeriod": { "end": "2026-11-01T00:00:00Z" } },
///   "onDemandUsed": { "val": 1234 }, "onDemandCap": { "val": 5000 } }
/// ```
///
/// Sem `creditUsagePercent`, cai para `onDemandUsed / onDemandCap`. Sem nenhum dos dois,
/// devolve `.semJanelas` — o painel mostra "sem dado".
public enum ParserUsoGrok {
    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        let config = obj["config"] as? [String: Any] ?? [:]

        var pct = JV.numero(config["creditUsagePercent"])
        var rotulo = "créditos"
        if pct == nil {
            // Os campos vêm na raiz (formato antigo) ou dentro de `config` (cobrança unificada, 10/2026).
            func val(_ chave: String) -> Double? {
                JV.numero((config[chave] as? [String: Any])?["val"]) ?? JV.numero((obj[chave] as? [String: Any])?["val"])
            }
            let usado = val("onDemandUsed"), teto = val("onDemandCap")
            if let usado, let teto, teto > 0 {
                pct = usado / teto * 100
            } else if config["isUnifiedBillingUser"] as? Bool == true, let saldo = val("prepaidBalance") {
                // Cobrança unificada pré-paga: não há % de cota. Com saldo, a lane está livre (0%);
                // sem saldo, está bloqueada (100%). Nunca inventa um % intermediário.
                pct = saldo > 0 ? 0 : 100
                rotulo = "pré-pago"
            }
        }
        guard let pct, pct.isFinite, pct >= 0 else { return .failure(.semJanelas) }

        let fim = JV.texto((config["currentPeriod"] as? [String: Any])?["end"])
            ?? JV.texto(config["billingPeriodEnd"])
        return .success([JanelaUso(chave: "credito", rotulo: rotulo, pct: pct,
                                   resetEm: fim.flatMap { Datas.lerISO8601($0) })])
    }
}

/// Resposta do `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`
/// (o % do Grok Bot que o menu SuperGrok mostra; nada a ver com o billing do grok CLI):
///
/// ```json
/// { "usagePercent": 96.2, "nextResetTimestampUtc": "1792000000000",
///   "hasNonZeroIncludedLimit": true, "includedLimitZero": false,
///   "usesPooledEnterpriseAllowance": false }
/// ```
///
/// É Connect/JSON: int64 pode vir como string, então o reset aceita número ou texto, em
/// milissegundos ou segundos, e também ISO 8601. Fica "sem dado" (com o motivo) quando falta
/// `usagePercent`, quando o plano não tem limite incluído ou quando a cota é a da empresa.
public enum ParserUsoSand {
    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        if JV.ehBool(obj["usesPooledEnterpriseAllowance"]), JV.verdadeiro(obj["usesPooledEnterpriseAllowance"]) {
            return .failure(.cotaCompartilhada)
        }
        if JV.ehBool(obj["includedLimitZero"]), JV.verdadeiro(obj["includedLimitZero"]) {
            return .failure(.semLimiteIncluido)
        }
        // só o `false` explícito esconde; ausente não diz nada
        if JV.ehBool(obj["hasNonZeroIncludedLimit"]), !JV.verdadeiro(obj["hasNonZeroIncludedLimit"]) {
            return .failure(.semLimiteIncluido)
        }
        guard let pct = numeroOuTexto(obj["usagePercent"]), pct >= 0 else { return .failure(.semJanelas) }
        return .success([JanelaUso(chave: "sand", rotulo: "ciclo", pct: pct,
                                   resetEm: momento(obj["nextResetTimestampUtc"]))])
    }

    static func numeroOuTexto(_ v: Any?) -> Double? {
        if let n = JV.numero(v) { return n }
        guard let s = JV.texto(v), let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// Época em ms (> 1e11) ou s, como número ou texto; senão ISO 8601.
    static func momento(_ v: Any?) -> Date? {
        if let n = numeroOuTexto(v) {
            guard n > 0 else { return nil }
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        return JV.texto(v).flatMap { Datas.lerISO8601($0) }
    }
}

/// Uso do Codex CLI (`GET https://chatgpt.com/backend-api/wham/usage`, mesma fonte que
/// CodexBar/OpenUsage consultam):
///
/// ```json
/// { "plan_type": "pro",
///   "rate_limit": {
///     "primary_window": {"used_percent": 25, "limit_window_seconds": 18000, "reset_at": 1791000000},
///     "secondary_window": {"used_percent": 18, "limit_window_seconds": 604800, "reset_at": 1791600000}}}
/// ```
///
/// Rótulo pela duração da janela (30 dias/semana/5 h); reset por `reset_at` (época em s),
/// com `reset_after_seconds` de reserva. Sem janela nenhuma, `.semJanelas` — nunca 0%.
public enum ParserUsoCodex {
    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados),
              let limite = obj["rate_limit"] as? [String: Any] else { return .failure(.respostaIlegivel) }
        let janelas = [("primary_window", limite["primary_window"]), ("secondary_window", limite["secondary_window"])]
        var saida: [JanelaUso] = []
        for (chave, v) in janelas {
            guard let m = v as? [String: Any], let pct = JV.numero(m["used_percent"]) else { continue }
            let duracao = JV.numero(m["limit_window_seconds"]) ?? 0
            let rotulo: String
            if duracao >= 25 * 86400 { rotulo = "30 dias" }
            else if duracao >= 6 * 86400 { rotulo = "semana" }
            else if duracao >= 4 * 3600 { rotulo = "5 h" }
            else { rotulo = "janela" }
            var reset: Date?
            if let r = JV.numero(m["reset_at"]), r > 0 { reset = Date(timeIntervalSince1970: r) }
            else if let s = JV.numero(m["reset_after_seconds"]), s > 0 {
                reset = Date().addingTimeInterval(s)
            }
            saida.append(JanelaUso(chave: chave, rotulo: rotulo, pct: pct, resetEm: reset))
        }
        return saida.isEmpty ? .failure(.semJanelas) : .success(saida)
    }
}

/// Uso do OpenCode Console (`GET https://opencode.ai/console/api/go/status`, a mesma fonte
/// que a página Go do Console lê):
///
/// ```json
/// { "product": "go",
///   "access": { "meters": {
///     "fiveHour": { "resetsAt": "...", "limitMicroCents": 100, "usedMicroCents": 25 },
///     "week": { ... }, "month": { ... } } } }
/// ```
///
/// `% = used / limit` (micro-cents = 1e-8 dólar). O Console manda os micro-cents como texto
/// (`"1200000000"`); número também é aceito. Sem assinatura Go (`product` diferente),
/// devolve `.semLimiteIncluido`; sem medidores, `.semJanelas` — nunca um número inventado.
public enum ParserUsoOpenCode {
    public static let janelas: [(chave: String, rotulo: String)] = [
        ("fiveHour", "5 h"),
        ("week", "semana"),
        ("month", "mês"),
    ]

    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        // Corpo `null` = o workspace não tem os medidores (sem assinatura Go): "sem dado"
        // com o motivo, nunca 0%.
        if let texto = String(data: dados, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           texto.isEmpty || texto == "null" {
            return .failure(.semLimiteIncluido)
        }
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        if let prod = JV.texto(obj["product"]), prod != "go" && prod != "go-plus" {
            return .failure(.semLimiteIncluido)
        }
        guard let access = obj["access"] as? [String: Any],
              let meters = access["meters"] as? [String: Any] else { return .failure(.semJanelas) }
        var saida: [JanelaUso] = []
        for (chave, rotulo) in janelas {
            guard let m = meters[chave] as? [String: Any],
                  let usado = JV.numeroOuTexto(m["usedMicroCents"]),
                  let teto = JV.numeroOuTexto(m["limitMicroCents"]), teto > 0 else { continue }
            saida.append(JanelaUso(chave: chave, rotulo: rotulo, pct: usado / teto * 100,
                                   resetEm: ParserUsoSand.momento(m["resetsAt"])))
        }
        return saida.isEmpty ? .failure(.semJanelas) : .success(saida)
    }
}

/// Saldo da DeepSeek Platform (`GET /api/v0/users/get_user_summary`):
///
/// ```json
/// { "code": 0, "data": { "biz_code": 0, "biz_data": {
///     "normal_wallets": [{ "currency": "USD", "balance": "2.51" }],
///     "bonus_wallets":  [{ "currency": "USD", "balance": "0" }] } } }
/// ```
///
/// Saldo = recarga + bônus, só em USD (texto decimal; número também vale). Não há janela:
/// devolve `.apenasSaldo`. Código 40003 = autorização inválida.
public enum ParserUsoDeepSeek {
    public static func ler(_ dados: Data) -> Result<[JanelaUso], ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        if let code = JV.inteiro(obj["code"]), code != 0 {
            return .failure(code == 40003 ? .naoAutorizado : .motivo("DeepSeek respondeu código \(code)"))
        }
        guard let data = obj["data"] as? [String: Any] else { return .failure(.respostaIlegivel) }
        if let biz = JV.inteiro(data["biz_code"]), biz != 0 {
            return .failure(biz == 40003 ? .naoAutorizado : .motivo("DeepSeek respondeu biz_code \(biz)"))
        }
        guard let biz = data["biz_data"] as? [String: Any] else { return .failure(.respostaIlegivel) }
        var total = 0.0
        var achou = false
        for chave in ["normal_wallets", "bonus_wallets"] {
            for carteira in (biz[chave] as? [[String: Any]]) ?? [] {
                guard (JV.texto(carteira["currency"]) ?? "").uppercased() == "USD" else { continue }
                guard let v = JV.numeroOuTexto(carteira["balance"]) else { return .failure(.respostaIlegivel) }
                total += v
                achou = true
            }
        }
        guard achou else { return .failure(.motivo("DeepSeek sem carteira em USD")) }
        return .failure(.apenasSaldo(max(total, 0)))
    }
}
