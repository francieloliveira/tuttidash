import Foundation

/// Leitura (só leitura) do `ledger.jsonl` gravado pela ferramenta `gasto` (Python).
/// Uma linha por execução, chave `id` = nome do log sem `.jsonl`. Linha inválida é ignorada,
/// como no `ledger.load()` do Python.
public enum Ledger {
    public static func carregar(url: URL) -> [String: Execucao] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let dados = try? handle.readToEnd() else { return [:] }
        return interpretar(dados: dados)
    }

    public static func interpretar(dados: Data) -> [String: Execucao] {
        var out: [String: Execucao] = [:]
        for linha in dados.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let obj = JV.objeto(Data(linha)), let ex = execucao(obj) else { continue }
            out[ex.id] = ex
        }
        return out
    }

    /// Converte um registro do ledger. Campos obrigatórios: id, card, lane e dia (ou inicio).
    static func execucao(_ r: [String: Any]) -> Execucao? {
        guard let id = JV.texto(r["id"]), let lane = JV.texto(r["lane"]), let card = JV.texto(r["card"]) else {
            return nil
        }
        let inicio = JV.texto(r["inicio"]) ?? ""
        guard let dia = JV.texto(r["dia"]) ?? (inicio.count >= 10 ? String(inicio.prefix(10)) : nil),
              Datas.lerLocal(dia) != nil else { return nil }
        let semana = JV.texto(r["semana"]) ?? Datas.lerLocal(dia).map { Datas.rotuloSemana($0) } ?? ""
        let status = StatusExecucao(rawValue: JV.texto(r["status"]) ?? "") ?? .morta
        var custo = TipoCusto(rawValue: JV.texto(r["custo"]) ?? "") ?? .desconhecido
        var custoUSD = JV.numero(r["custo_usd"])
        if custo == .gratis || custo == .plano { custoUSD = 0 }
        if custoUSD == nil { custo = .desconhecido }        // mesmo critério do report._soma
        if custo == .desconhecido { custoUSD = nil }
        let parcial = r["parcial"] as? [String: Any]
        let tokens = (r["tokens"] as? [String: Any]) ?? (parcial?["tokens"] as? [String: Any])
        var fonte: Fonte?
        if let f = r["fonte"] as? [String: Any], let t = JV.inteiro(f["tamanho"]), let m = JV.numero(f["mtime"]) {
            fonte = Fonte(tamanho: t, mtime: m)
        }
        return Execucao(
            id: id, card: card.uppercased(), lane: lane, inicio: inicio, dia: dia, semana: semana,
            status: status, subtipo: JV.texto(r["subtipo"]),
            erros: (r["erros"] as? [Any] ?? []).map { "\($0)" },
            custoUSD: custoUSD, custo: custo, turnos: JV.inteiro(r["turnos"]),
            duracaoMs: JV.inteiro(r["duracao_ms"]), duracaoEstimadaMs: JV.inteiro(r["duracao_estimada_ms"]),
            respostasParciais: JV.inteiro(parcial?["respostas"]), tokensTotal: JV.inteiro(tokens?["total"]),
            fonte: fonte)
    }
}
