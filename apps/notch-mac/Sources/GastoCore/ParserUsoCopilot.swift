import Foundation

/// Uso do GitHub Copilot pelo relatório oficial de billing da conta pessoal.
///
/// `GET https://api.github.com/users/{username}/settings/billing/premium_request/usage`
/// com `year` e `month`. O corpo documentado traz `usageItems[].grossQuantity`
/// (requisições). A % é a soma dessas quantidades no mês dividida pela cota que
/// a pessoa informou. Cota ausente ou zero não vira número.
///
/// Nenhum trecho de cliente de editor entra aqui. O formato é o da documentação
/// pública do GitHub (REST de billing, versão `2026-03-10`).
public enum ParserUsoCopilot {
    public static let nomeProduto = "TuttiDash"
    public static let versaoProduto = "0.2.0"
    public static var userAgent: String { "\(nomeProduto)/\(versaoProduto)" }
    /// Versão atual da REST API do GitHub (cabeçalho `X-GitHub-Api-Version`).
    public static let versaoAPI = "2026-03-10"
    public static let host = "api.github.com"

    public static func cabecalhos(_ t: TokenConta) -> [String: String] {
        [
            "Authorization": "Bearer \(t.valor)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": versaoAPI,
            "User-Agent": userAgent,
        ]
    }

    /// URL do mês de `agora` (UTC), ou falha se falta usuário, cota ou o nome é inválido.
    /// Não chama a rede.
    public static func pedido(usuario: String, cota: Int?, agora: Date) -> Result<URL, ErroUso> {
        let nome = usuario.trimmingCharacters(in: .whitespacesAndNewlines)
        if nome.isEmpty { return .failure(.semUsuarioCopilot) }
        guard usuarioValido(nome) else { return .failure(.usuarioCopilotInvalido) }
        guard let cota, cota > 0 else { return .failure(.semCotaInformada) }
        guard let url = url(usuario: nome, agora: agora) else { return .failure(.usuarioCopilotInvalido) }
        return .success(url)
    }

    public static func url(usuario: String, agora: Date) -> URL? {
        let nome = usuario.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usuarioValido(nome) else { return nil }
        let p = periodo(agora)
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/users/\(nome)/settings/billing/premium_request/usage"
        comps.queryItems = [
            URLQueryItem(name: "year", value: String(p.ano)),
            URLQueryItem(name: "month", value: String(p.mes)),
        ]
        return comps.url
    }

    /// Soma `grossQuantity` dos itens do mês e divide pela cota informada.
    /// Relatório vazio ou de organização não vira 0%.
    public static func ler(_ dados: Data, cota: Int, agora: Date) -> Result<[JanelaUso], ErroUso> {
        guard cota > 0 else { return .failure(.semCotaInformada) }
        guard let obj = JV.objeto(dados) else { return .failure(.respostaIlegivel) }
        if JV.texto(obj["organization"]) != nil { return .failure(.respostaOrganizacao) }
        let p = periodo(agora)
        if let tp = obj["timePeriod"] as? [String: Any] {
            if let ano = JV.inteiro(tp["year"]), ano != p.ano { return .failure(.relatorioOutroMes) }
            if let mes = JV.inteiro(tp["month"]), mes != p.mes { return .failure(.relatorioOutroMes) }
        }
        guard let itens = obj["usageItems"] as? [Any], !itens.isEmpty else {
            return .failure(.licencaOrganizacao)
        }
        var soma = 0.0
        var contou = false
        for item in itens {
            guard let m = item as? [String: Any] else { continue }
            if let unidade = JV.texto(m["unitType"])?.lowercased(), unidade != "requests" { continue }
            guard let q = JV.numero(m["grossQuantity"]), q.isFinite, q >= 0 else { continue }
            soma += q
            contou = true
        }
        guard contou else { return .failure(.semQuantidadeCopilot) }
        let pct = soma / Double(cota) * 100
        let janela = JanelaUso(chave: "premium", rotulo: "mês", pct: pct,
                               resetEm: inicioProximoMes(ano: p.ano, mes: p.mes))
        return .success([janela])
    }

    public static func periodo(_ agora: Date) -> (ano: Int, mes: Int) {
        let c = calendarioUTC
        return (c.component(.year, from: agora), c.component(.month, from: agora))
    }

    /// Usuário do GitHub: 1–39, alfanumérico e hífen, sem hífen na ponta nem dobrado.
    static func usuarioValido(_ nome: String) -> Bool {
        guard (1...39).contains(nome.count), !nome.contains("--") else { return false }
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard nome.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return false }
        guard let primeiro = nome.first, let ultimo = nome.last else { return false }
        return primeiro != "-" && ultimo != "-"
    }

    static var calendarioUTC: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    static func inicioProximoMes(ano: Int, mes: Int) -> Date? {
        var comp = DateComponents()
        comp.year = mes == 12 ? ano + 1 : ano
        comp.month = mes == 12 ? 1 : mes + 1
        comp.day = 1
        comp.hour = 0
        comp.minute = 0
        comp.second = 0
        return calendarioUTC.date(from: comp)
    }
}
