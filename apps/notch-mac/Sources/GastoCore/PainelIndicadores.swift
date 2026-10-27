import Foundation

/// Recorte do bloco de custos do painel.
public enum PeriodoCustos: String, CaseIterable, Equatable, Hashable, Sendable {
    case semana
    case mes
    case ano

    public var rotulo: String {
        switch self {
        case .semana: return "Semana"
        case .mes: return "Mês"
        case .ano: return "Ano"
        }
    }

    /// Complemento do título «Gasto por lane (…)».
    public var complemento: String {
        switch self {
        case .semana: return "semana"
        case .mes: return "mês"
        case .ano: return "ano"
        }
    }
}

/// Custos de um recorte. Custo desconhecido fica fora da soma e conta em `desconhecidas`.
public struct CustosPeriodo: Equatable, Sendable {
    public var porLane: [GastoLanePainel]
    /// Semana: um dia por barra (7). Mês: uma semana ISO por barra. Ano: um mês por barra.
    public var barras: [GastoDiaPainel]
    /// Ranking por custo, no máximo 5.
    public var top: [CardCaro]
    /// Cards do mesmo recorte de `top`, do mais recente ao mais antigo.
    public var builds: [CardCaro] = []
    public var total: Double?
    public var desconhecidas: Int
}

/// Uma página da lista completa de cards do recorte.
public struct PaginaBuilds: Equatable, Sendable {
    public var itens: [CardCaro]
    /// 1-based. Fora do intervalo, a função de corte encosta na última página que existe.
    public var pagina: Int
    public var tamanho: Int
    public var total: Int
    public var paginas: Int

    public var temAnterior: Bool { pagina > 1 }
    public var temProxima: Bool { pagina < paginas }

    /// "1 a 25 de 80", "3 de 40" ou "0 builds".
    public var intervalo: String {
        ListaPaginada(itens: itens, pagina: pagina, tamanho: tamanho, total: total,
                      paginas: paginas, vazio: "0 builds").intervalo
    }
}

/// Cards do recorte na ordem da aba «Todos os builds»: o mais recente primeiro.
public enum ListaBuilds {
    /// Quantos cards a aba «Todos os builds» mostra por vez.
    public static let tamanhoPagina = ListaPaginada<CardCaro>.tamanhoPadrao

    /// Mais recente primeiro. Sem `ultimoInicio`, o card vai para o fim.
    /// No mesmo horário, o id do card decide.
    public static func porRecencia(_ cards: [CardCaro]) -> [CardCaro] {
        cards.sorted { a, b in
            let ia = a.ultimoInicio ?? .distantPast
            let ib = b.ultimoInicio ?? .distantPast
            if ia != ib { return ia > ib }
            return a.card < b.card
        }
    }

    public static func pagina(_ cards: [CardCaro], numero: Int, tamanho: Int = tamanhoPagina) -> PaginaBuilds {
        let fatia = ListaPaginada.cortar(cards, numero: numero, tamanho: tamanho, vazio: "0 builds")
        return PaginaBuilds(itens: fatia.itens, pagina: fatia.pagina, tamanho: fatia.tamanho,
                            total: fatia.total, paginas: fatia.paginas)
    }
}

/// Uma execução de lane no histórico de builds do painel.
public struct BuildPainel: Equatable, Sendable {
    public var numero: Int?
    public var card: String
    public var titulo: String?
    public var lane: String
    public var inicio: Date?
    public var status: StatusExecucao
    public var duracaoMs: Int?
    /// nil = custo desconhecido (nunca vira zero).
    public var custoUSD: Double?
    public var custo: TipoCusto = .desconhecido
    /// O que o dispatcher fez com o card depois desta execução (linha `FECHOU`), em texto curto.
    public var desfecho: String? = nil
    /// Esta execução é a do card que segura o lock de build agora (a prova está compilando).
    public var naProva: Bool = false

    /// Coluna Custo: valor, «grátis», «no plano» ou traço (FRA-528).
    public func textoCusto(_ moeda: MoedaPainel) -> String {
        if let fixo = custo.rotuloFixo { return fixo }
        return custoUSD.map { moeda.texto($0) } ?? "—"
    }

    /// Coluna Status: o card na prova aparece como «na prova», mesmo com o agente já concluído.
    public var textoStatus: String { naProva ? "na prova" : status.rotulo }
}

/// FRA-528: lock de build e lista de builds lidos do mesmo retrato.
/// O lock só existe na prova do dispatcher (xcodebuild); a fase do agente não segura lock.
public enum ResumoLock {
    public static func dono(lockLane: String?, lockCard: String?) -> String {
        guard let lockLane, let lockCard else { return "Livre" }
        return "\(lockLane) · \(lockCard) (prova compilando)"
    }

    /// Linha de contexto quando o lock está livre mas há lane trabalhando.
    public static func contexto(lockLane: String?, rodando: [LinhaLane]) -> String? {
        guard lockLane == nil else { return nil }
        let ativas = rodando.filter { $0.estado == .rodando }.map { l in "\(l.lane) · \(l.card ?? "?")" }
        guard !ativas.isEmpty else { return "Nenhuma prova compilando agora." }
        return "Na fase do agente: " + ativas.joined(separator: ", ") + ". O lock só é pego na prova."
    }

    /// Texto curto do desfecho de uma linha `FECHOU <card> → <resto>`.
    public static func desfecho(_ resto: String) -> String {
        let r = resto.lowercased()
        if r.contains("in review") { return "PR aberto" }
        if r.contains("aguardando o limite") { return "limite da conta" }
        if r.contains("prova do dispatcher falhou") { return "prova falhou" }
        if r.contains("saiu da") { return "saiu da lane" }
        if r.hasPrefix("needs:") { return "precisa de você" }
        if r.contains("lane:falhou") { return "agente falhou" }
        if r.contains("lane:parada") { return "parada" }
        return String(resto.prefix(30))
    }
}

/// Números dos quatro cartões do topo e do bloco de testes do painel.
public struct IndicadoresPainel: Equatable, Sendable {
    /// Lanes ativas = rodando ou livres. Pausada (esperando, sem folga) e desligada não contam.
    public var lanesAtivas: Int
    public var lanesTotal: Int
    /// Execuções de lane que começaram hoje e ontem (relógio local).
    public var buildsHoje: Int
    public var buildsOntem: Int
    /// 12 barras de 1 h: as últimas 12 horas, a última é a hora corrente.
    public var buildsSerie: [Int]
    /// Execuções com status erro ou morta que começaram nas últimas 24 h.
    public var falhas24h: Int
    public var execucoes24h: Int
    /// 12 barras de 2 h nas últimas 24 h.
    public var falhasSerie: [Int]
    /// Custo conhecido da semana ISO anterior até o mesmo ponto da semana. nil = sem gasto conhecido.
    public var semanaAnterior: Double?
    /// (semana atual − anterior) / anterior, em %. nil quando não dá para comparar.
    public var variacaoSemanaPct: Double?
    /// Suítes das provas pedidas hoje.
    public var testesPassou: Int
    public var testesFalhou: Int
    public var provasHoje: Int

    public static let vazio = IndicadoresPainel(
        lanesAtivas: 0, lanesTotal: 0, buildsHoje: 0, buildsOntem: 0, buildsSerie: Array(repeating: 0, count: 12),
        falhas24h: 0, execucoes24h: 0, falhasSerie: Array(repeating: 0, count: 12), semanaAnterior: nil,
        variacaoSemanaPct: nil, testesPassou: 0, testesFalhou: 0, provasHoje: 0)

    /// Falhas / execuções nas últimas 24 h, em %. Sem execução, nil.
    public var falhasPct: Double? {
        execucoes24h > 0 ? Double(falhas24h) * 100 / Double(execucoes24h) : nil
    }

    public var testesHoje: Int { testesPassou + testesFalhou }
}

/// Cálculos do painel v2 sobre dados que já existem (execuções, estado e provas).
/// Só leitura, sem relógio próprio: tudo depende de `agora` e do calendário recebidos.
public enum Indicadores {
    /// Variação do custo semanal a partir da qual vira alerta na faixa do painel.
    public static let alertaVariacaoPct = 20.0

    /// `#N` estável de cada execução: posição no histórico inteiro ordenado por início e id.
    /// Chame com a lista completa (antes de filtrar lanes desligadas) para o número não mudar.
    public static func ordinais(_ execucoes: [Execucao]) -> [String: Int] {
        let ordenadas = execucoes.sorted { ($0.inicio, $0.id) < ($1.inicio, $1.id) }
        var saida: [String: Int] = [:]
        for (i, ex) in ordenadas.enumerated() { saida[ex.id] = i + 1 }
        return saida
    }

    /// Última execução de cada lane: número e início.
    static func ultimaPorLane(_ execucoes: [Execucao], ordinais: [String: Int],
                              calendario: Calendar) -> [String: (numero: Int, inicio: Date?)] {
        var saida: [String: (Int, Date?, String)] = [:]
        for ex in execucoes {
            guard let n = ordinais[ex.id] else { continue }
            if let atual = saida[ex.lane], (atual.2, atual.0) >= (ex.inicio, n) { continue }
            saida[ex.lane] = (n, Datas.lerLocal(ex.inicio, calendario: calendario), ex.inicio)
        }
        return saida.mapValues { ($0.0, $0.1) }
    }

    static func calcular(linhas: [LinhaLane], execucoes: [Execucao], provas: [ProvaBruta],
                         semanaAtual: Double?, agora: Date, calendario: Calendar) -> IndicadoresPainel {
        let hojeInicio = calendario.startOfDay(for: agora)
        let hojeISO = Datas.diaISO(agora, calendario: calendario)
        let ontemISO = calendario.date(byAdding: .day, value: -1, to: hojeInicio).map { Datas.diaISO($0, calendario: calendario) } ?? ""
        var buildsHoje = 0, buildsOntem = 0
        var serieBuilds = Array(repeating: 0, count: 12)
        var serieFalhas = Array(repeating: 0, count: 12)
        var exec24 = 0, falhas24 = 0
        let semanaPassada = calendario.date(byAdding: .day, value: -7, to: agora) ?? agora
        let rotuloAnterior = Datas.rotuloSemana(semanaPassada, calendario: calendario)
        var anteriorSoma = 0.0, anteriorTeve = false

        for ex in execucoes {
            if ex.dia == hojeISO { buildsHoje += 1 }
            if ex.dia == ontemISO { buildsOntem += 1 }
            guard let inicio = Datas.lerLocal(ex.inicio, calendario: calendario) else { continue }
            let idade = agora.timeIntervalSince(inicio)
            if idade >= 0 && idade < 12 * 3600 {
                serieBuilds[11 - Int(idade / 3600)] += 1
            }
            if idade >= 0 && idade < 24 * 3600 {
                exec24 += 1
                if ex.status == .erro || ex.status == .morta {
                    falhas24 += 1
                    serieFalhas[11 - Int(idade / 7200)] += 1
                }
            }
            if ex.semana == rotuloAnterior, inicio <= semanaPassada, let custo = ex.custoConhecido {
                anteriorSoma += custo
                anteriorTeve = true
            }
        }
        let anterior = anteriorTeve ? anteriorSoma : nil
        var variacao: Double?
        if let anterior, anterior > 0, let semanaAtual {
            variacao = (semanaAtual - anterior) / anterior * 100
        }

        var passou = 0, falhou = 0, provasHoje = 0
        var vistas: Set<String> = []
        for bruta in provas {
            guard let pedido = bruta.pedidoEm, calendario.isDate(pedido, inSameDayAs: agora) else { continue }
            let chave = Provas.chave(bruta)
            if vistas.contains(chave) { continue }
            vistas.insert(chave)
            provasHoje += 1
            let carta = Provas.carta(bruta, agora: agora, seguraLock: false, posicao: nil, espera: nil)
            passou += carta.suites.filter { $0.estado == .ok }.count
            falhou += carta.suites.filter { $0.estado == .falha }.count
        }

        return IndicadoresPainel(
            lanesAtivas: linhas.filter { $0.estado == .rodando || $0.estado == .livre }.count,
            lanesTotal: linhas.count, buildsHoje: buildsHoje, buildsOntem: buildsOntem,
            buildsSerie: serieBuilds, falhas24h: falhas24, execucoes24h: exec24, falhasSerie: serieFalhas,
            semanaAnterior: anterior, variacaoSemanaPct: variacao,
            testesPassou: passou, testesFalhou: falhou, provasHoje: provasHoje)
    }

    /// Execuções que começaram hoje, a mais nova primeiro (até `limite`).
    static func buildsDeHoje(_ execucoes: [Execucao], ordinais: [String: Int], agora: Date,
                             calendario: Calendar, limite: Int = 30,
                             fechamentos: [FechamentoLog] = [], lockLane: String? = nil,
                             lockCard: String? = nil, titulos: [String: String] = [:]) -> [BuildPainel] {
        let hoje = Datas.diaISO(agora, calendario: calendario)
        let todas = execucoes.filter { $0.dia == hoje }
        // A execução mais nova de cada (lane, card) é a que fica com o lock, se houver.
        let maisNova = Dictionary(todas.map { ("\($0.lane)|\($0.card)", $0) }, uniquingKeysWith: { a, b in
            (a.inicio, a.id) > (b.inicio, b.id) ? a : b
        })
        func desfecho(_ ex: Execucao) -> String? {
            // primeiro FECHOU da mesma lane e card depois do início desta execução
            let inicio = ex.inicio.replacingOccurrences(of: "T", with: " ")
            return fechamentos.first { $0.lane == ex.lane && $0.card == ex.card && $0.quando >= inicio }
                .map { ResumoLock.desfecho($0.resto) }
        }
        return todas
            .sorted { ($0.inicio, $0.id) > ($1.inicio, $1.id) }
            .prefix(limite)
            .map { ex in
                BuildPainel(numero: ordinais[ex.id], card: ex.card, titulo: titulos[ex.card], lane: ex.lane,
                            inicio: Datas.lerLocal(ex.inicio, calendario: calendario), status: ex.status,
                            duracaoMs: ex.duracaoMs ?? ex.duracaoEstimadaMs, custoUSD: ex.custoConhecido,
                            custo: ex.custo, desfecho: desfecho(ex),
                            naProva: lockLane == ex.lane && lockCard == ex.card
                                && maisNova["\(ex.lane)|\(ex.card)"]?.id == ex.id)
            }
    }

    /// Alertas que só a faixa do painel mostra (não mexem no estado do notch).
    static func alertasExtras(_ ind: IndicadoresPainel) -> [String] {
        var lista: [String] = []
        if ind.falhas24h == 1 {
            lista.append("1 build falhou nas últimas 24h")
        } else if ind.falhas24h > 1 {
            lista.append("\(ind.falhas24h) builds falharam nas últimas 24h")
        }
        if let v = ind.variacaoSemanaPct, v >= alertaVariacaoPct {
            lista.append("Custo semanal \(Int(v.rounded()))% maior que a semana anterior")
        }
        return lista
    }

    static let meses = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]

    /// Mês corrente (barras por semana ISO) ou ano corrente (barras por mês).
    static func periodo(_ periodo: PeriodoCustos, execucoes: [Execucao], titulos: [String: String],
                        planos: [String: PlanoLane], agora: Date, calendario: Calendar) -> CustosPeriodo {
        let comps = calendario.dateComponents([.year, .month], from: agora)
        let ano = comps.year ?? 0, mes = comps.month ?? 1
        let prefixoAno = String(format: "%04d-", ano)
        let prefixoMes = String(format: "%04d-%02d-", ano, mes)
        let filtradas = execucoes.filter { ex in
            switch periodo {
            case .semana: return ex.semana == Datas.rotuloSemana(agora, calendario: calendario)
            case .mes: return ex.dia.hasPrefix(prefixoMes)
            case .ano: return ex.dia.hasPrefix(prefixoAno)
            }
        }
        var barras: [GastoDiaPainel] = []
        var indice: [String: Int] = [:]
        switch periodo {
        case .semana:
            break
        case .mes:
            var dia = calendario.date(from: DateComponents(year: ano, month: mes, day: 1)) ?? agora
            let semanaHoje = Datas.rotuloSemana(agora, calendario: calendario)
            while dia <= agora {
                let rotulo = Datas.rotuloSemana(dia, calendario: calendario)
                if indice[rotulo] == nil {
                    indice[rotulo] = barras.count
                    let n = Datas.numeroSemana(dia, calendario: calendario)
                    barras.append(GastoDiaPainel(rotulo: rotulo == semanaHoje ? "atual" : "S\(n)", total: 0,
                                                 ehHoje: rotulo == semanaHoje))
                }
                guard let prox = calendario.date(byAdding: .day, value: 1, to: dia) else { break }
                dia = prox
            }
        case .ano:
            for m in 1...max(1, mes) {
                indice[String(format: "%04d-%02d", ano, m)] = barras.count
                barras.append(GastoDiaPainel(rotulo: meses[m - 1], total: 0, ehHoje: m == mes))
            }
        }
        var porLane: [String: (custo: Double, teve: Bool, desc: Int)] = [:]
        var soma = 0.0, teve = false, desc = 0
        for ex in filtradas {
            let conhecido = ex.custoConhecido
            var lane = porLane[ex.lane] ?? (0, false, 0)
            if let conhecido {
                lane.custo += conhecido; lane.teve = true
                soma += conhecido; teve = true
                let chave = periodo == .mes ? ex.semana : String(ex.dia.prefix(7))
                if let i = indice[chave] { barras[i].total += conhecido }
            } else {
                lane.desc += 1; desc += 1
            }
            porLane[ex.lane] = lane
        }
        let gastos = LanesPainel.ordem.map { lane in
            let item = porLane[lane]
            return GastoLanePainel(lane: lane, custoUSD: item?.teve == true ? item?.custo : nil,
                                   desconhecidas: item?.desc ?? 0, plano: planos[lane])
        }
        let agregados = MontadorPainel.top(filtradas, titulos: titulos, calendario: calendario)
        return CustosPeriodo(porLane: gastos, barras: barras,
                             top: Array(agregados.prefix(5)),
                             builds: ListaBuilds.porRecencia(agregados),
                             total: teve ? soma : nil, desconhecidas: desc)
    }
}
