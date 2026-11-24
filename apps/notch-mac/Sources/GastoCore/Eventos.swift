import Foundation

/// Uma linha do `eventos.jsonl` gravado pelo dispatcher/vigia (`eventos.py`).
/// Só o que o painel usa: o resto do evento fica no arquivo.
public struct EventoFluxo: Equatable, Sendable {
    public var ts: String
    public var projeto: String
    public var card: String
    public var lane: String
    public var etapa: String
    public var status: String

    public init(ts: String, projeto: String, card: String, lane: String, etapa: String, status: String = "") {
        self.ts = ts
        self.projeto = projeto
        self.card = card
        self.lane = lane
        self.etapa = etapa
        self.status = status
    }
}

/// Retrato do fluxo de um projeto: contagens e duração média claim→finalize.
public struct FluxoProjeto: Equatable, Sendable {
    public var projeto: String
    public var claims: Int
    public var finalizes: Int
    public var merges: Int
    public var falhas: Int
    public var paradas: Int
    public var abertos: Int
    public var duracaoMediaMin: Double?
    public var finalizesComDuracao: Int

    public init(projeto: String, claims: Int = 0, finalizes: Int = 0, merges: Int = 0,
                falhas: Int = 0, paradas: Int = 0, abertos: Int = 0,
                duracaoMediaMin: Double? = nil, finalizesComDuracao: Int = 0) {
        self.projeto = projeto
        self.claims = claims
        self.finalizes = finalizes
        self.merges = merges
        self.falhas = falhas
        self.paradas = paradas
        self.abertos = abertos
        self.duracaoMediaMin = duracaoMediaMin
        self.finalizesComDuracao = finalizesComDuracao
    }
}

public enum LeitorEventos {
    /// Lê o arquivo; ausente ou ilegível devolve vazio (o painel mostra «sem medida»).
    public static func ler(url: URL) -> [EventoFluxo] {
        guard let dados = try? Data(contentsOf: url) else { return [] }
        return ler(dados: dados)
    }

    public static func ler(dados: Data) -> [EventoFluxo] {
        var out: [EventoFluxo] = []
        for linha in dados.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(linha)) as? [String: Any],
                  (obj["schema"] as? NSNumber)?.intValue == 1,
                  let ts = JV.texto(obj["ts"]),
                  let projeto = JV.texto(obj["projeto"]),
                  let card = JV.texto(obj["card"]),
                  let lane = JV.texto(obj["lane"]),
                  let etapa = JV.texto(obj["etapa"]) else { continue }
            out.append(EventoFluxo(ts: ts, projeto: projeto, card: card.uppercased(),
                                   lane: lane, etapa: etapa, status: JV.texto(obj["status"]) ?? ""))
        }
        return out
    }
}

public enum Fluxo {
    /// Mesma régua do `gasto_lanes/fluxo.py`: claim→finalize por card/lane.
    public static func resumo(_ eventos: [EventoFluxo], calendario: Calendar = Datas.calendarioISO) -> [FluxoProjeto] {
        var por: [String: FluxoProjeto] = [:]
        var duracoes: [String: [Double]] = [:]
        var abertos: [String: Date] = [:]
        for ev in eventos {
            guard !ev.projeto.isEmpty, !ev.card.isEmpty, !ev.lane.isEmpty, !ev.etapa.isEmpty else { continue }
            var p = por[ev.projeto] ?? FluxoProjeto(projeto: ev.projeto)
            let chave = "\(ev.projeto)|\(ev.card)|\(ev.lane)"
            switch ev.etapa {
            case "claim":
                p.claims += 1
                if let d = Datas.lerLocal(ev.ts, calendario: calendario) { abertos[chave] = d }
            case "finalize":
                p.finalizes += 1
                let st = ev.status.lowercased()
                if st.contains("falhou") { p.falhas += 1 }
                else if st.contains("parada") { p.paradas += 1 }
                if let fim = Datas.lerLocal(ev.ts, calendario: calendario),
                   let inicio = abertos.removeValue(forKey: chave), fim >= inicio {
                    duracoes[ev.projeto, default: []].append(fim.timeIntervalSince(inicio))
                    p.finalizesComDuracao += 1
                }
            case "merge":
                p.merges += 1
            default:
                break
            }
            por[ev.projeto] = p
        }
        return por.values.map { p in
            var x = p
            x.abertos = abertos.keys.filter { $0.hasPrefix(p.projeto + "|") }.count
            let ds = duracoes[p.projeto] ?? []
            x.duracaoMediaMin = ds.isEmpty ? nil : (ds.reduce(0, +) / Double(ds.count) / 60).rounded(to: 1)
            return x
        }.sorted { $0.projeto < $1.projeto }
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
