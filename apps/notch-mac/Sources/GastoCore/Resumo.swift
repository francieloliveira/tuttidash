import Foundation

/// Nível do anel semanal (mesmas regras do `report.avaliar_teto`).
public enum NivelTeto: String, Sendable {
    case semTeto     // anel neutro, "sem teto definido"
    case ok          // verde · folga
    case perto       // amarelo · atenção (>= aviso_pct)
    case estourado   // vermelho · gasto >= teto
}

/// Tudo o que o painel mostra, calculado só a partir das execuções e do estado lidos.
public struct Resumo: Equatable, Sendable {
    public struct Dia: Equatable, Sendable {
        public var dia: String              // AAAA-MM-DD
        public var diaSemana: String        // "ter", "qua"... ou "hoje"
        public var dataCurta: String        // "29/09"
        public var ehHoje: Bool
        public var porLane: [String: Double]   // custo conhecido por lane
        public var total: Double
        public var execucoes: Int
        public var desconhecidas: Int
    }

    public struct Card: Equatable, Sendable {
        public var card: String
        public var lanes: [String]          // por custo, a primeira é a dominante
        public var custoConhecido: Double
        public var execucoes: Int
        public var erros: Int
        public var desconhecidas: Int
        public var laneDominante: String { lanes.first ?? "" }
        public var todasDesconhecidas: Bool { desconhecidas > 0 && desconhecidas == execucoes }
    }

    public struct Lane: Equatable, Sendable {
        public var lane: String
        public var custoConhecido: Double
        public var execucoes: Int
        public var desconhecidas: Int
        public var duracaoMs: Int           // informada
        public var duracaoEstimadaMs: Int   // pela última escrita do log
        public var todasDesconhecidas: Bool { desconhecidas > 0 && desconhecidas == execucoes }
    }

    public struct Rodando: Equatable, Sendable {
        public var lane: String
        public var card: String
        public var desde: Date?
        public var respostas: Int?          // respostas do modelo até agora (do log em andamento)
        public var travada: Bool
    }

    // Semana atual (ISO)
    public var semana: String
    public var numeroSemana: Int
    public var gastoSemana: Double
    public var execucoesSemana: Int
    public var desconhecidasSemana: Int
    public var estimadoSemana: Double
    public var informadoSemana: Double
    public var teto: Double?
    public var avisoPct: Double
    public var pct: Double?             // 0...∞ (pode passar de 100)
    public var nivel: NivelTeto

    // Últimos 7 dias (hoje incluso)
    public var dias: [Dia]
    public var cards: [Card]            // todos, do mais caro ao mais barato
    public var lanes: [Lane]
    public var desconhecidas7d: Int
    public var execucoes7d: Int

    // Agora
    public var rodando: [Rodando]
    public var heartbeat: EstadoLanes.Heartbeat?
    public var heartbeatData: Date?
}

public enum Agregador {
    static let diasSemana = Formato.diasSemana

    public static func nivel(gasto: Double, teto: Double?, avisoPct: Double) -> (NivelTeto, Double?) {
        guard let teto, teto > 0 else { return (.semTeto, nil) }
        let pct = gasto / teto * 100
        if gasto >= teto { return (.estourado, pct) }
        if pct >= avisoPct { return (.perto, pct) }
        return (.ok, pct)
    }

    /// Ordem das lanes: fonte única em `Agentes` (FRA-373). Usada pelo painel e pelos cálculos.
    public static func ordemLane(_ a: String, _ b: String) -> Bool {
        Agentes.ordemLane(a, b)
    }

    public static func resumir(execucoes: [Execucao], estado: EstadoLanes, teto: Double?, avisoPct: Double,
                               agora: Date = Date(), calendario: Calendar = Datas.calendarioISO) -> Resumo {
        let semana = Datas.rotuloSemana(agora, calendario: calendario)
        let daSemana = execucoes.filter { $0.semana == semana }
        let gasto = daSemana.compactMap(\.custoConhecido).reduce(0, +)
        let (nv, pct) = nivel(gasto: gasto, teto: teto, avisoPct: avisoPct)

        // 7 dias: hoje e os 6 anteriores
        let hoje = calendario.startOfDay(for: agora)
        var dias: [Resumo.Dia] = []
        for off in stride(from: 6, through: 0, by: -1) {
            guard let d = calendario.date(byAdding: .day, value: -off, to: hoje) else { continue }
            let c = calendario.dateComponents([.day, .month, .weekday], from: d)
            dias.append(Resumo.Dia(
                dia: Datas.diaISO(d, calendario: calendario),
                diaSemana: off == 0 ? "hoje" : diasSemana[((c.weekday ?? 1) - 1) % 7],
                dataCurta: String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0),
                ehHoje: off == 0, porLane: [:], total: 0, execucoes: 0, desconhecidas: 0))
        }
        let idx = Dictionary(uniqueKeysWithValues: dias.enumerated().map { ($1.dia, $0) })
        var cards: [String: Resumo.Card] = [:]
        var custoCardLane: [String: [String: (Double, Int)]] = [:]
        var lanes: [String: Resumo.Lane] = [:]
        var desc7 = 0, exec7 = 0

        for ex in execucoes {
            guard let i = idx[ex.dia] else { continue }
            exec7 += 1
            let custo = ex.custoConhecido
            dias[i].execucoes += 1
            if let custo {
                dias[i].porLane[ex.lane, default: 0] += custo
                dias[i].total += custo
            } else {
                dias[i].desconhecidas += 1
                desc7 += 1
            }

            var c = cards[ex.card] ?? Resumo.Card(card: ex.card, lanes: [], custoConhecido: 0, execucoes: 0,
                                                 erros: 0, desconhecidas: 0)
            c.execucoes += 1
            if ex.status == .erro { c.erros += 1 }
            if let custo { c.custoConhecido += custo } else { c.desconhecidas += 1 }
            cards[ex.card] = c
            var porLane = custoCardLane[ex.card] ?? [:]
            let atual = porLane[ex.lane] ?? (0, 0)
            porLane[ex.lane] = (atual.0 + (custo ?? 0), atual.1 + 1)
            custoCardLane[ex.card] = porLane

            var l = lanes[ex.lane] ?? Resumo.Lane(lane: ex.lane, custoConhecido: 0, execucoes: 0, desconhecidas: 0,
                                                 duracaoMs: 0, duracaoEstimadaMs: 0)
            l.execucoes += 1
            if let custo { l.custoConhecido += custo } else { l.desconhecidas += 1 }
            if let d = ex.duracaoMs, d > 0 { l.duracaoMs += d } else { l.duracaoEstimadaMs += ex.duracaoEstimadaMs ?? 0 }
            lanes[ex.lane] = l
        }
        for (card, porLane) in custoCardLane {
            cards[card]?.lanes = porLane.sorted { a, b in
                if a.value.0 != b.value.0 { return a.value.0 > b.value.0 }
                if a.value.1 != b.value.1 { return a.value.1 > b.value.1 }
                return ordemLane(a.key, b.key)
            }.map(\.key)
        }
        // Mesmo critério do report.agrupar: maior gasto, depois mais execuções, depois nome.
        let cardsOrdenados = cards.values.sorted {
            ($0.custoConhecido, $0.execucoes) != ($1.custoConhecido, $1.execucoes)
                ? ($0.custoConhecido, $0.execucoes) > ($1.custoConhecido, $1.execucoes)
                : $0.card < $1.card
        }

        // Agora: lanes ocupadas segundo os lane-<lane>.json
        let porNome = Dictionary(execucoes.map { ($0.id + ".jsonl", $0) }, uniquingKeysWith: { a, _ in a })
        let rodando = estado.lanes.sorted { ordemLane($0.lane, $1.lane) }.map { l in
            Resumo.Rodando(lane: l.lane, card: l.card,
                           desde: l.startedAt.flatMap { Datas.lerLocal($0, calendario: calendario) },
                           respostas: porNome[l.nomeLog]?.respostasParciais, travada: l.travada)
        }

        return Resumo(
            semana: semana, numeroSemana: Datas.numeroSemana(agora, calendario: calendario),
            gastoSemana: gasto, execucoesSemana: daSemana.count,
            desconhecidasSemana: daSemana.filter { $0.custoConhecido == nil }.count,
            estimadoSemana: daSemana.filter { $0.custo == .estimado }.compactMap(\.custoConhecido).reduce(0, +),
            informadoSemana: daSemana.filter { $0.custo == .informado }.compactMap(\.custoConhecido).reduce(0, +),
            teto: (teto ?? 0) > 0 ? teto : nil, avisoPct: avisoPct, pct: pct, nivel: nv,
            dias: dias, cards: cardsOrdenados,
            lanes: lanes.values.sorted { ordemLane($0.lane, $1.lane) },
            desconhecidas7d: desc7, execucoes7d: exec7,
            rodando: rodando, heartbeat: estado.heartbeat,
            heartbeatData: estado.heartbeat.flatMap { Datas.lerLocal($0.at, calendario: calendario) })
    }
}
