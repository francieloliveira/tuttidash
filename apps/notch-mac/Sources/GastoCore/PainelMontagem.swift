import Foundation

/// Junta os leitores num retrato do notch e do painel. Não lê disco e não grava nada.
public enum MontadorPainel {
    /// Teto da lista da tela Entregas (último fechamento de cada card).
    /// O log já guarda no máximo 60 fechamentos; o dashboard mostra só as 5 primeiras.
    public static let limiteEntregas = 60

    // MARK: Cache do último snapshot montado (FRA-582)
    /// Chave (hash dos dados de entrada) do último snapshot montado.
    private static var cacheChave: Int?
    /// Último snapshot montado, reutilizado quando os dados de entrada não mudaram.
    private static var cacheSnapshot: SnapshotPainel?

    /// Limpa o cache do último snapshot. Útil em testes e quando se quer forçar remontagem.
    public static func limparCache() {
        cacheChave = nil
        cacheSnapshot = nil
    }

    /// Hash dos dados de entrada: serve para saber se `montar` precisa rodar de novo.
    public static func hashEntrada(entrada: EntradaPainel, execucoes: [Execucao], usos: [UsoConta] = [],
                                   agora: Date? = nil, calendario: Calendar = Datas.calendarioISO,
                                   taxaUsdBrl: Double? = nil, ordinais: [String: Int]? = nil) -> Int {
        Self.chave(entrada: entrada, execucoes: execucoes, usos: usos, agora: agora, calendario: calendario,
                   taxaUsdBrl: taxaUsdBrl, ordinais: ordinais)
    }
    /// Alias em português.
    public static func hashDosDados(entrada: EntradaPainel, execucoes: [Execucao], usos: [UsoConta] = [],
                                    agora: Date? = nil, calendario: Calendar = Datas.calendarioISO,
                                    taxaUsdBrl: Double? = nil, ordinais: [String: Int]? = nil) -> Int {
        hashEntrada(entrada: entrada, execucoes: execucoes, usos: usos, agora: agora, calendario: calendario,
                    taxaUsdBrl: taxaUsdBrl, ordinais: ordinais)
    }
    public static func hashDeEntrada(entrada: EntradaPainel, execucoes: [Execucao], usos: [UsoConta] = [],
                                     agora: Date? = nil, calendario: Calendar = Datas.calendarioISO,
                                     taxaUsdBrl: Double? = nil, ordinais: [String: Int]? = nil) -> Int {
        hashEntrada(entrada: entrada, execucoes: execucoes, usos: usos, agora: agora, calendario: calendario,
                    taxaUsdBrl: taxaUsdBrl, ordinais: ordinais)
    }
    /// Último snapshot montado (somente leitura).
    public static var ultimoSnapshotMontado: SnapshotPainel? { cacheSnapshot }

    private static func chave(entrada: EntradaPainel, execucoes: [Execucao], usos: [UsoConta],
                             agora: Date?, calendario: Calendar, taxaUsdBrl: Double?,
                             ordinais: [String: Int]?) -> Int {
        var hasher = Hasher()
        hasher.combine(String(reflecting: entrada))
        for ex in execucoes { hasher.combine(String(reflecting: ex)) }
        for u in usos { hasher.combine(String(reflecting: u)) }
        if let agora { hasher.combine(agora.timeIntervalSinceReferenceDate) }
        hasher.combine(String(describing: calendario.identifier))
        hasher.combine(calendario.timeZone.identifier)
        if let taxa = taxaUsdBrl { hasher.combine(taxa) } else { hasher.combine(0 as Int) }
        if let ord = ordinais {
            for k in ord.keys.sorted() {
                hasher.combine(k)
                hasher.combine(ord[k] ?? 0)
            }
        }
        return hasher.finalize()
    }

    public static func montar(entrada: EntradaPainel, execucoes: [Execucao], usos: [UsoConta] = [],
                              agora: Date = Date(), calendario: Calendar = Datas.calendarioISO,
                              taxaUsdBrl: Double? = nil, ordinais: [String: Int]? = nil) -> SnapshotPainel {
        let chaveAtual = Self.chave(entrada: entrada, execucoes: execucoes, usos: usos, agora: agora,
                                    calendario: calendario, taxaUsdBrl: taxaUsdBrl, ordinais: ordinais)
        if let cacheChave, cacheChave == chaveAtual, let snap = cacheSnapshot {
            return snap
        }
        let quadro = Provas.organizar(entrada.provas, agora: agora)
        let medidas = medidasEfetivas(entrada: entrada, usos: usos)
        let numeros = ordinais ?? Indicadores.ordinais(execucoes)
        let linhas = enriquecer(linhasLane(entrada: entrada, medidas: medidas, provas: quadro.cartas, agora: agora,
                                           calendario: calendario),
                                entrada: entrada, execucoes: execucoes, ordinais: numeros, calendario: calendario)
        let moeda = MoedaPainel.escolher(taxaUsdBrl: taxaUsdBrl)
        let apurado = custos(entrada: entrada, execucoes: execucoes, medidas: medidas, agora: agora,
                             calendario: calendario, moeda: moeda)
        var custos = apurado.painel
        custos.periodos = [
            .semana: CustosPeriodo(porLane: custos.porLane, barras: custos.dias, top: custos.top,
                                   builds: apurado.buildsSemana,
                                   total: custos.semana, desconhecidas: custos.desconhecidasSemana),
            .mes: Indicadores.periodo(.mes, execucoes: execucoes, titulos: entrada.titulos, planos: entrada.planos,
                                      agora: agora, calendario: calendario),
            .ano: Indicadores.periodo(.ano, execucoes: execucoes, titulos: entrada.titulos, planos: entrada.planos,
                                      agora: agora, calendario: calendario),
        ]
        let indicadores = Indicadores.calcular(linhas: linhas, execucoes: execucoes, provas: entrada.provas,
                                               semanaAtual: custos.semana, agora: agora, calendario: calendario)
        let heartbeatData = entrada.heartbeat.flatMap { Datas.lerLocal($0.at, calendario: calendario) }
        let idade = heartbeatData.map { agora.timeIntervalSince($0) }
        let batimentoMorto = heartbeatData == nil || (idade ?? 0) > Double(LanesPainel.batimentoParadoSegundos)
        let alertas = alertas(entrada: entrada, linhas: linhas, provas: quadro.cartas,
                              batimentoMorto: batimentoMorto, idade: idade, agora: agora)
        let todasOff = linhas.allSatisfy { $0.estado == .desligada }
        let geral: EstadoGeral
        if entrada.pausa || batimentoMorto || todasOff {
            geral = .parado
        } else if alertas.isEmpty {
            geral = .tudoOk
        } else {
            geral = .atencao
        }
        let dono = quadro.cartas.first { $0.seguraLock }
        let notch = EstadoNotch(
            geral: geral, rotulo: geral.rotulo, pontos: pontos(linhas),
            contaCritica: contaCritica(medidas), contaPct: contaCriticaPct(medidas),
            linhas: linhas, testes: textoTestes(quadro.cartas),
            build: textoBuild(dono), custoHoje: textoCusto(custos))
        let laneSugerida = dono?.lane ?? linhas.filter { $0.estado == .rodando }.map(\.lane).only
        let snap = SnapshotPainel(
            geral: geral, rotuloGeral: geral.rotulo, notch: notch, alertas: alertas, lanes: linhas,
            provas: quadro.cartas, historico: quadro.historico,
            lockTexto: dono.map { "\($0.lane) · \($0.card)" } ?? "livre",
            lockSegundos: dono?.segundos, lockLane: dono?.lane, lockCard: dono?.card,
            filaLock: quadro.cartas.compactMap { carta in
                guard let pos = carta.posicaoFila else { return nil }
                return "\(pos)º \(carta.lane) · \(carta.card)"
            },
            simulador: textoSimulador(entrada.simulador),
            batimentoTexto: textoBatimento(heartbeatData, agora: agora),
            dispatcherVivo: heartbeatData != nil && !batimentoMorto,
            pausa: entrada.pausa,
            filaPronta: filaPronta(log: entrada.decisao.fila, provas: quadro.cartas),
            proximaDecisao: entrada.decisao.proxima ?? "sem decisão nova",
            strikesTexto: entrada.strikes?.texto ?? "sem registro",
            regrasRisco: LanesPainel.regrasRisco,
            entregas: entregas(entrada: entrada, execucoes: execucoes),
            iphone: textoInstalacao(entrada.instalacoes.leu, entrada.instalacoes.iphone),
            relogio: textoInstalacao(entrada.instalacoes.leu, entrada.instalacoes.relogio),
            custos: custos, logTexto: entrada.logTexto, logAberto: false, laneSugerida: laneSugerida,
            indicadores: indicadores, alertasPainel: alertas + Indicadores.alertasExtras(indicadores),
            buildsHoje: Indicadores.buildsDeHoje(execucoes, ordinais: numeros, agora: agora, calendario: calendario,
                                                 fechamentos: entrada.fechamentos, lockLane: dono?.lane,
                                                 lockCard: dono?.card, titulos: entrada.titulos),
            esperandoVoce: esperandoVoce(entrada.fechamentos))
        cacheChave = chaveAtual
        cacheSnapshot = snap
        return snap
    }

    /// Branch do card em curso e número/início da última execução de cada lane.
    static func enriquecer(_ linhas: [LinhaLane], entrada: EntradaPainel, execucoes: [Execucao],
                           ordinais: [String: Int], calendario: Calendar) -> [LinhaLane] {
        let branches = Dictionary(entrada.rodando.map { ($0.lane, $0.branch) }, uniquingKeysWith: { a, _ in a })
        let ultimas = Indicadores.ultimaPorLane(execucoes, ordinais: ordinais, calendario: calendario)
        return linhas.map { linha in
            var l = linha
            if l.estado != .desligada || branches[l.lane] != nil {
                l.branch = branches[l.lane] ?? nil
            }
            l.ultimaBuild = ultimas[l.lane]?.numero
            l.ultimaBuildInicio = ultimas[l.lane]?.inicio
            l.textoModelo = entrada.textoModelo[l.lane]
            l.avisoModelo = entrada.avisoModelo[l.lane]
            return l
        }
    }

    static func medidasEfetivas(entrada: EntradaPainel, usos: [UsoConta]) -> [MedidaConta] {
        LanesPainel.ordem.map { lane in
            if let uso = usos.first(where: { $0.conta == lane || $0.tipo == lane }), uso.temDado, let pct = uso.pct {
                return MedidaConta(lane: lane, pct: pct, janela: uso.critica?.rotulo)
            }
            if let medida = entrada.medidas.first(where: { $0.lane == lane }) {
                return medida
            }
            return MedidaConta(lane: lane, pct: nil, janela: nil)
        }
    }

    static func linhasLane(entrada: EntradaPainel, medidas: [MedidaConta], provas: [CartaoProva],
                           agora: Date, calendario: Calendar) -> [LinhaLane] {
        let porLane = Dictionary(uniqueKeysWithValues: entrada.rodando.map { ($0.lane, $0) })
        let ligadas = entrada.habilitadas ?? entrada.heartbeat.map { Set($0.habilitadas) }
        return LanesPainel.ordem.map { lane in
            let medida = medidas.first { $0.lane == lane }
            let prova = provas.first { $0.lane == lane }
            let ocupada = porLane[lane]
            let plano = entrada.planos[lane]
            let desde = ocupada?.startedAt.flatMap { Datas.lerLocal($0, calendario: calendario) }
            let noCard = desde.map { max(0, Int(agora.timeIntervalSince($0))) }
            let foraDaLista = ligadas.map { !$0.contains(lane) && ocupada == nil } ?? false
            if entrada.desligadasPeloUsuario.contains(lane) || foraDaLista {
                return LinhaLane(lane: lane, estado: .desligada, card: nil, descricao: "desligada",
                                 detalhe: "", pct: nil, janela: nil, plano: nil, segundosNoCard: nil,
                                 desligadaPeloUsuario: entrada.desligadasPeloUsuario.contains(lane))
            }
            if let ocupada {
                let titulo = ocupada.titulo ?? entrada.titulos[ocupada.card]
                let descricao = titulo.map { "\(ocupada.card), \($0)" } ?? ocupada.card
                let detalhe = noCard.map { "rodando, há \(Formato.relogio($0)) no card" } ?? "rodando"
                return LinhaLane(lane: lane, estado: .rodando, card: ocupada.card, descricao: descricao,
                                 detalhe: detalhe, pct: medida?.pct, janela: medida?.janela, plano: plano,
                                 segundosNoCard: noCard)
            }
            if let prova, let pos = prova.posicaoFila {
                let espera = prova.esperaSegundos.map { "há \(Formato.relogio($0)) de espera" } ?? "na fila"
                return LinhaLane(lane: lane, estado: .esperando, card: prova.card,
                                 descricao: "\(prova.card), \(prova.descricao)",
                                 detalhe: "posição \(pos) na fila, \(espera)",
                                 pct: medida?.pct, janela: medida?.janela, plano: plano, segundosNoCard: nil)
            }
            if let ate = entrada.limitesAte[lane] {
                return LinhaLane(lane: lane, estado: .esperando, card: nil, descricao: "Sem card",
                                 detalhe: "limite da conta até \(Formato.quando(ate, agora: agora, calendario: calendario))",
                                 pct: medida?.pct, janela: medida?.janela, plano: plano, segundosNoCard: nil)
            }
            if let prova, prova.emCurso || prova.seguraLock {
                let descricao = prova.descricao == "sem descrição" ? prova.card : "\(prova.card), \(prova.descricao)"
                return LinhaLane(lane: lane, estado: .rodando, card: prova.card, descricao: descricao,
                                 detalhe: "prova há \(Formato.relogio(prova.segundos))",
                                 pct: medida?.pct, janela: medida?.janela, plano: plano,
                                 segundosNoCard: prova.segundos)
            }
            if let pct = medida?.pct, pct >= LanesPainel.folgaBaixo {
                return LinhaLane(lane: lane, estado: .semFolga, card: nil, descricao: "Sem card, sem folga",
                                 detalhe: medida?.janela.map { "janela \($0)" } ?? "conta sem folga",
                                 pct: pct, janela: medida?.janela, plano: plano, segundosNoCard: nil)
            }
            return LinhaLane(lane: lane, estado: .livre, card: nil, descricao: "livre, sem card pronto",
                             detalhe: "pode assumir card", pct: medida?.pct, janela: medida?.janela,
                             plano: plano, segundosNoCard: nil)
        }
    }

    static func pontos(_ linhas: [LinhaLane]) -> [PontoNotch] {
        linhas.map { linha in
            PontoNotch(lane: linha.lane, aceso: linha.estado != .desligada,
                       atencao: linha.estado == .semFolga || linha.estado == .esperando || (linha.pct ?? 0) >= Uso.pctAtencao)
        }
    }

    static func contaCritica(_ medidas: [MedidaConta]) -> String {
        guard let melhor = melhorConta(medidas), let pct = melhor.pct else { return "sem medida" }
        return "\(melhor.lane) \(Formato.pct(pct))"
    }

    static func contaCriticaPct(_ medidas: [MedidaConta]) -> Double? {
        melhorConta(medidas)?.pct
    }

    static func melhorConta(_ medidas: [MedidaConta]) -> MedidaConta? {
        medidas.filter { $0.pct != nil }.max { a, b in
            if a.pct != b.pct { return (a.pct ?? 0) < (b.pct ?? 0) }
            return LanesPainel.ordem.firstIndex(of: a.lane) ?? 0 > LanesPainel.ordem.firstIndex(of: b.lane) ?? 0
        }
    }

    static func alertas(entrada: EntradaPainel, linhas: [LinhaLane], provas: [CartaoProva],
                        batimentoMorto: Bool, idade: TimeInterval?, agora: Date) -> [String] {
        var lista: [String] = []
        if entrada.pausa { lista.append("Pausa ligada. Nenhum card novo entra.") }
        if entrada.heartbeat == nil {
            lista.append("Sem batimento do dispatcher.")
        } else if batimentoMorto, let idade {
            lista.append("Batimento atrasado há \(Formato.relogio(Int(idade))).")
        }
        for prova in provas where prova.emCurso && prova.segundos > LanesPainel.alertaProvaSegundos {
            lista.append("Prova do \(prova.card) passa de 10 min (há \(Formato.relogio(prova.segundos))).")
        }
        for linha in linhas {
            guard let pct = linha.pct else { continue }
            let janela = linha.janela.map { " da \($0)" } ?? ""
            if pct >= LanesPainel.folgaBaixo {
                lista.append("\(linha.lane) sem folga (\(Formato.pct(pct))\(janela)).")
            } else if pct >= Uso.pctAtencao {
                lista.append("\(linha.lane) em \(Formato.pct(pct))\(janela).")
            }
        }
        for lane in entrada.rodando where lane.travada {
            lista.append("\(lane.lane) travada em \(lane.card).")
        }
        for linha in linhas {
            if let aviso = linha.avisoModelo, aviso.contains("saiu da lista") {
                lista.append("\(linha.lane): \(aviso)")
            }
        }
        for prova in provas where prova.zeroTestes {
            lista.append("Prova do \(prova.card) falhou com 0 testes.")
        }
        if linhas.allSatisfy({ $0.estado == .desligada }) {
            lista.append("Todas as lanes estão desligadas.")
        }
        return lista
    }

    static func textoTestes(_ provas: [CartaoProva]) -> String {
        guard let atual = provas.first(where: \.emCurso) ?? provas.first else { return "sem prova" }
        var texto = "\(atual.card), tentativa \(atual.tentativa) de \(atual.tentativas)"
        if atual.zeroTestes {
            texto += ", 0 testes"
        } else {
            let falhas = atual.suites.filter { $0.estado == .falha }.count
            if falhas == 1 { texto += ", 1 falha" }
            else if falhas > 1 { texto += ", \(falhas) falhas" }
            else if atual.falha { texto += ", falha" }
        }
        return texto
    }

    static func textoBuild(_ dono: CartaoProva?) -> String {
        guard let dono else { return "lock livre" }
        let quem = dono.lane.isEmpty ? dono.card : dono.lane
        return "lock com \(quem) há \(Formato.relogio(dono.segundos))"
    }

    static func textoCusto(_ custos: CustosPainel) -> String {
        if let hoje = custos.hoje { return custos.moeda.texto(hoje) }
        if custos.desconhecidasHoje > 0 { return "custo desconhecido" }
        return "sem dado"
    }

    static func textoBatimento(_ data: Date?, agora: Date) -> String {
        guard let data else { return "sem batimento" }
        let segundos = max(0, Int(agora.timeIntervalSince(data)))
        if segundos < 60 { return "último ciclo há \(segundos) s" }
        return "último ciclo " + Formato.ha(data, agora: agora)
    }

    /// Cards cujo último `FECHOU` no log foi para o rótulo de dono (`needs:...`).
    static func esperandoVoce(_ fechamentos: [FechamentoLog]) -> Int {
        var ultimo: [String: String] = [:]
        for f in fechamentos { ultimo[f.card] = f.resto }
        return ultimo.values.filter { $0.lowercased().hasPrefix("needs:") }.count
    }

    static func textoSimulador(_ bruto: String?) -> String {
        switch bruto?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ligado", "on", "1", "sim": return "ligado"
        case "desligado", "off", "0", "nao", "não": return "desligado"
        default: return "sem leitura ainda"
        }
    }

    static func textoInstalacao(_ leu: Bool, _ sha: String?) -> String {
        guard leu, let sha, !sha.isEmpty else { return "sem leitura ainda" }
        return sha
    }

    /// Último fechamento de cada card, o mais recente primeiro, até `limiteEntregas`.
    /// Card que ainda está na lane ou na prova não entra.
    /// Duração abaixo de 1 s não vira «0 s».
    /// O dashboard mostra só as 5 primeiras; a tela Entregas pagina a lista.
    static func entregas(entrada: EntradaPainel, execucoes: [Execucao]) -> [EntregaPainel] {
        let andamento = cardsEmAndamento(entrada)
        var vistos: Set<String> = []
        var saida: [EntregaPainel] = []
        for fechou in entrada.fechamentos.reversed() {
            if vistos.contains(fechou.card) || andamento.contains(fechou.card) { continue }
            vistos.insert(fechou.card)
            let ms = execucoes.filter { $0.card == fechou.card }
                .compactMap { $0.duracaoMs ?? $0.duracaoEstimadaMs }.reduce(0, +)
            saida.append(EntregaPainel(card: fechou.card, titulo: entrada.titulos[fechou.card], lane: fechou.lane,
                                       quando: fechou.quando, segundos: ms >= 1000 ? ms / 1000 : nil, pr: pr(fechou.resto),
                                       urlPR: EnderecosPainel.urlPR(fechou.resto),
                                       quandoData: Datas.lerLocal(fechou.quando)))
            if saida.count == limiteEntregas { break }
        }
        return saida
    }

    static func cardsEmAndamento(_ entrada: EntradaPainel) -> Set<String> {
        var ids = Set(entrada.rodando.map(\.card))
        for prova in entrada.provas where !prova.historico && (prova.saida == nil || prova.esperandoLock) {
            ids.insert(prova.card)
        }
        return ids
    }

    /// A fila do log é a fonte. Card esperando o lock entra se o log não o citou.
    static func filaPronta(log: [String], provas: [CartaoProva]) -> [String] {
        var vistos = log
        for prova in provas where prova.posicaoFila != nil && !vistos.contains(prova.card) {
            vistos.append(prova.card)
        }
        return vistos
    }

    static func pr(_ resto: String) -> String? {
        if let n = LeitorLogDispatcher.grupos(#"pull/(\d+)"#, resto).first { return "PR #\(n)" }
        if let n = LeitorLogDispatcher.grupos(#"#(\d+)"#, resto).first { return "PR #\(n)" }
        return nil
    }

    static func custos(entrada: EntradaPainel, execucoes: [Execucao], medidas: [MedidaConta],
                       agora: Date, calendario: Calendar, moeda: MoedaPainel) -> (painel: CustosPainel, buildsSemana: [CardCaro]) {
        let hojeISO = Datas.diaISO(agora, calendario: calendario)
        let semana = Datas.rotuloSemana(agora, calendario: calendario)
        let hojeInicio = calendario.startOfDay(for: agora)
        var dias: [GastoDiaPainel] = []
        var indice: [String: Int] = [:]
        for off in stride(from: 6, through: 0, by: -1) {
            guard let dia = calendario.date(byAdding: .day, value: -off, to: hojeInicio) else { continue }
            let iso = Datas.diaISO(dia, calendario: calendario)
            let comps = calendario.dateComponents([.weekday], from: dia)
            let rotulo = off == 0 ? "hoje" : Formato.diasSemana[((comps.weekday ?? 1) - 1) % 7]
            indice[iso] = dias.count
            dias.append(GastoDiaPainel(rotulo: rotulo, total: 0, ehHoje: off == 0))
        }
        var porLane: [String: (custo: Double, teve: Bool, desc: Int)] = [:]
        var hojeSoma = 0.0, hojeTeve = false, hojeDesc = 0
        var semanaSoma = 0.0, semanaTeve = false, semanaDesc = 0
        for ex in execucoes {
            let conhecido = ex.custoConhecido
            if let i = indice[ex.dia], let conhecido { dias[i].total += conhecido }
            if ex.dia == hojeISO {
                if let conhecido { hojeSoma += conhecido; hojeTeve = true } else { hojeDesc += 1 }
            }
            if ex.semana == semana {
                var lane = porLane[ex.lane] ?? (0, false, 0)
                if let conhecido { lane.custo += conhecido; lane.teve = true } else { lane.desc += 1 }
                porLane[ex.lane] = lane
                if let conhecido { semanaSoma += conhecido; semanaTeve = true } else { semanaDesc += 1 }
            }
        }
        let gastosLane = LanesPainel.ordem.map { lane in
            let item = porLane[lane]
            return GastoLanePainel(lane: lane, custoUSD: item?.teve == true ? item?.custo : nil,
                                   desconhecidas: item?.desc ?? 0, plano: entrada.planos[lane])
        }
        let caros = Self.top(execucoes.filter { indice[$0.dia] != nil }, titulos: entrada.titulos, calendario: calendario)
        let painel = CustosPainel(porLane: gastosLane, hoje: hojeTeve ? hojeSoma : nil, semana: semanaTeve ? semanaSoma : nil,
                                  desconhecidasHoje: hojeDesc, desconhecidasSemana: semanaDesc, dias: dias,
                                  uso: medidas, top: Array(caros.prefix(5)), moeda: moeda)
        return (painel: painel, buildsSemana: ListaBuilds.porRecencia(caros))
    }

    /// Cards mais caros do recorte: custo conhecido, duração e tentativas somados por card.
    static func top(_ execucoes: [Execucao], titulos: [String: String], calendario: Calendar) -> [CardCaro] {
        var cards: [String: AcumCard] = [:]
        for ex in execucoes {
            var card = cards[ex.card] ?? AcumCard()
            card.tentativas += 1
            if ex.status == .erro { card.erros += 1 }
            if let conhecido = ex.custoConhecido { card.custo += conhecido; card.teveCusto = true }
            let dur = ex.duracaoMs ?? ex.duracaoEstimadaMs ?? 0
            if dur > 0 { card.duracao += dur }
            card.porLane[ex.lane, default: 0] += 1
            if ex.inicio > card.ultimo { card.ultimo = ex.inicio }
            cards[ex.card] = card
        }
        return cards.map { card, acum in
            let lane = acum.porLane.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return (LanesPainel.ordem.firstIndex(of: a.key) ?? 99) > (LanesPainel.ordem.firstIndex(of: b.key) ?? 99)
            }?.key ?? ""
            let motivo: String?
            let destaque: Bool
            if acum.erros >= 2 {
                motivo = "falha repetida"; destaque = true
            } else if acum.tentativas >= 3 {
                motivo = "prova repetida"; destaque = true
            } else if acum.erros == 1 {
                motivo = "falha"; destaque = true
            } else {
                motivo = nil; destaque = false
            }
            return CardCaro(card: card, lane: lane, descricao: titulos[card],
                            custoUSD: acum.teveCusto ? acum.custo : nil, duracaoMs: acum.duracao,
                            tentativas: acum.tentativas, motivo: motivo, destaque: destaque,
                            ultimoInicio: Datas.lerLocal(acum.ultimo, calendario: calendario))
        }.sorted { a, b in
            let ca = a.custoUSD ?? -1
            let cb = b.custoUSD ?? -1
            if ca != cb { return ca > cb }
            if a.duracaoMs != b.duracaoMs { return a.duracaoMs > b.duracaoMs }
            if a.tentativas != b.tentativas { return a.tentativas > b.tentativas }
            return a.card < b.card
        }
    }
}

/// Endereços que a tela abre no navegador.
/// O workspace do Linear é o `linear.workspace_url` que o app já grava.
/// O repositório do PR é a URL que o dispatcher deixa no `FECHOU`.
public enum EnderecosPainel {
    /// `https://linear.app/<workspace>/issue/<CARD>`.
    public static func issueLinear(workspace: String, card: String) -> URL? {
        let base = workspace.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, !card.isEmpty else { return nil }
        let seguro = card.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card
        return URL(string: "\(base)/issue/\(seguro)")
    }

    /// Só `https://github.com/<dono>/<repo>/pull/<número>`. Outro texto não vira link.
    public static func urlPR(_ resto: String) -> String? {
        LeitorLogDispatcher.grupos(
            #"(https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+)"#,
            resto
        ).first
    }
}

private struct AcumCard {
    var ultimo = ""
    var custo = 0.0
    var teveCusto = false
    var duracao = 0
    var tentativas = 0
    var erros = 0
    var porLane: [String: Int] = [:]
}

private extension Array where Element == String {
    var only: String? { count == 1 ? first : nil }
}
