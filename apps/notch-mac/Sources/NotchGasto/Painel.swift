import AppKit
import SwiftUI
import GastoCore

/// Estado expandido (hover): painel completo do mockup v1.
struct Painel: View {
    @ObservedObject var modelo: ModeloNotch

    var body: some View {
        VStack(spacing: 0) {
            faixaTopo
            if let r = modelo.resumo {
                cabecalho(r)
                HStack(alignment: .top, spacing: 10) {
                    GraficoDias(dias: r.dias, lanes: r.lanes.map(\.lane))
                        .frame(width: 238)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .fundoCard()
                    CardsCaros(cards: Array(r.cards.prefix(4)), abrir: modelo.abrirCard)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .fundoCard()
                }
                .fixedSize(horizontal: false, vertical: true)
                DivisaoLanes(lanes: r.lanes)
                    .fundoCard()
                    .padding(.top, 10)
                if !modelo.retomadas.isEmpty {
                    CardRetomar(retomadas: modelo.retomadas, copiar: modelo.copiar)
                        .fundoCard()
                        .padding(.top, 10)
                }
                if modelo.config.usoContas {
                    LimitesContas(usos: modelo.usos)
                        .fundoCard()
                        .padding(.top, 10)
                }
                Rodape(resumo: r, abrirConfig: modelo.abrirConfig)
                    .padding(.top, 10)
            } else {
                Text("Lendo o gasto das lanes…")
                    .font(.sf(12)).foregroundStyle(Tema.t3)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: Tema.larguraPainel)
    }

    // "● TuttiDash · lanes" ... (notch) ... "atualizado agora"
    private var faixaTopo: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            HStack(spacing: 7) {
                let vivo = dispatcherVivo(agora: ctx.date)
                Circle().fill(vivo ? Tema.ok : Tema.t4).frame(width: 6, height: 6)
                    .shadow(color: vivo ? Tema.ok : .clear, radius: 3)
                Text("TuttiDash · lanes")
                Spacer(minLength: modelo.temNotch ? modelo.larguraNotch : 12)
                if let erro = modelo.config.erro {
                    Text(erro).foregroundStyle(Tema.bad).lineLimit(1).truncationMode(.middle)
                } else if let em = modelo.atualizadoEm {
                    Text("atualizado " + Formato.ha(em, agora: ctx.date))
                }
            }
            .font(.sf(11.5))
            .foregroundStyle(Tema.t3)
            .padding(.horizontal, 4)
            .frame(height: modelo.alturaNotch)
        }
    }

    private func dispatcherVivo(agora: Date) -> Bool {
        guard let d = modelo.resumo?.heartbeatData else { return false }
        return agora.timeIntervalSince(d) < 10 * 60
    }

    private func cabecalho(_ r: Resumo) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SEMANA \(r.numeroSemana)")
                    .font(.sf(11, .semibold)).tracking(0.8).foregroundStyle(Tema.t3)
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("US$").font(.sf(20, .semibold)).tracking(-0.2).foregroundStyle(Tema.t2)
                        Text(Formato.valor(r.gastoSemana)).font(.sf(34, .bold)).tracking(-1)
                            .foregroundStyle(Tema.t1)
                    }
                    .monospacedDigit()
                    if let teto = r.teto {
                        Text("de \(Formato.usd(teto))").font(.sf(14, .medium)).monospacedDigit()
                            .foregroundStyle(Tema.t2)
                    } else {
                        Text("sem teto definido").font(.sf(14, .medium)).foregroundStyle(Tema.t2)
                    }
                }
                .padding(.top, 5)
                HStack(spacing: 6) {
                    if r.estimadoSemana > 0 {
                        Nota(cor: Tema.t2, texto: "estimado a preço de tabela")
                    }
                    if r.desconhecidasSemana > 0 {
                        Nota(cor: Tema.t2, texto: "+ " + Formato.plural(r.desconhecidasSemana,
                             "execução com custo desconhecido", "execuções com custo desconhecido"))
                    }
                    if r.execucoesSemana == 0 {
                        Nota(cor: Tema.t2, texto: "nenhuma execução nesta semana")
                    }
                }
                .padding(.top, 9)
            }
            Spacer()
            ZStack {
                Anel(fracao: r.pct.map { $0 / 100 }, nivel: r.nivel, tamanho: 88, espessura: 8, brilho: true)
                VStack(spacing: 1) {
                    if let pct = r.pct {
                        Text("\(Int(pct.rounded()))%").font(.sf(20, .bold)).tracking(-0.5).monospacedDigit()
                            .foregroundStyle(Tema.cor(nivel: r.nivel))
                        Text("do limite").font(.sf(9.5)).tracking(0.2).foregroundStyle(Tema.t3)
                    } else {
                        Text("sem").font(.sf(12, .semibold)).foregroundStyle(Tema.t2)
                        Text("teto").font(.sf(9.5)).tracking(0.2).foregroundStyle(Tema.t3)
                    }
                }
            }
            .padding(.trailing, 2)
        }
        .padding(.top, 4).padding(.horizontal, 6).padding(.bottom, 10)
    }
}

/// Selo pequeno com bolinha ("claude estimado a preço de tabela").
struct Nota: View {
    var cor: Color
    var texto: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(cor).frame(width: 6, height: 6)
            Text(texto).font(.sf(11)).foregroundStyle(Tema.t3).lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, 9).padding(.vertical, 3)
        .background(Capsule().fill(cor.opacity(0.08)))
        .overlay(Capsule().strokeBorder(cor.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Últimos 7 dias

struct GraficoDias: View {
    var dias: [Resumo.Dia]
    var lanes: [String]
    private let alturaPlot: CGFloat = 96
    private let alturaMaxBarra: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TituloCard(texto: "Últimos 7 dias") {
                HStack(spacing: 10) {
                    ForEach(lanes, id: \.self) { lane in
                        legenda(Tema.cor(lane: lane), lane)
                    }
                }
            }
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    linhaTracejada
                    Spacer()
                    linhaTracejada
                    Spacer()
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(dias.enumerated()), id: \.element.dia) { i, d in
                        coluna(d)
                        if i < dias.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: alturaPlot)
            .padding(.top, 8)
            HStack(spacing: 0) {
                ForEach(Array(dias.enumerated()), id: \.element.dia) { i, d in
                    VStack(spacing: 0) {
                        Text(d.diaSemana).font(.sf(10, .semibold))
                            .foregroundStyle(d.ehHoje ? Tema.t1 : Tema.t2)
                        Text(d.dataCurta).font(.sf(9.5))
                            .foregroundStyle(d.ehHoje ? Tema.t1 : Tema.t3)
                    }
                    .lineLimit(1).fixedSize()
                    .frame(width: 24)
                    if i < dias.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 2).padding(.top, 6)
        }
        .padding(.top, 11).padding(.horizontal, 12).padding(.bottom, 9)
    }

    private var linhaTracejada: some View {
        Line().stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }

    private func legenda(_ cor: Color, _ nome: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(cor).frame(width: 7, height: 7)
            Text(nome).font(.sf(10.5, .medium)).foregroundStyle(Tema.t3)
        }
    }

    private func coluna(_ d: Resumo.Dia) -> some View {
        let maximo = max(dias.map(\.total).max() ?? 0, 0.0001)
        // Empilhamento na ordem das lanes (a última da ordem fica no topo).
        let lanes = d.porLane.filter { $0.value > 0 }.keys.sorted { Agregador.ordemLane($1, $0) }
        return VStack(spacing: 0) {
            if d.total > 0 {
                Text(Formato.valor(d.total)).font(.sf(10, .semibold)).monospacedDigit()
                    .foregroundStyle(d.ehHoje ? Tema.t1 : Tema.t2)
                    .lineLimit(1).fixedSize()
                    .padding(.bottom, 4)
                VStack(spacing: 1) {
                    ForEach(Array(lanes.enumerated()), id: \.element) { i, lane in
                        let h = max(alturaMaxBarra * (d.porLane[lane] ?? 0) / maximo, 4)
                        UnevenRoundedRectangle(topLeadingRadius: i == 0 ? 5 : 2, bottomLeadingRadius: 2,
                                               bottomTrailingRadius: 2, topTrailingRadius: i == 0 ? 5 : 2)
                            .fill(LinearGradient(stops: [
                                .init(color: Tema.corClara(lane: lane), location: 0),
                                .init(color: Tema.cor(lane: lane), location: 0.3),
                                .init(color: Tema.cor2(lane: lane), location: 1)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(width: 16, height: h)
                            .shadow(color: Tema.cor(lane: lane).opacity(0.35), radius: 6)
                    }
                }
            } else {
                if d.desconhecidas > 0 {
                    Text("?").font(.sf(10, .semibold)).foregroundStyle(Tema.t3).padding(.bottom, 4)
                        .help("\(d.desconhecidas) execução(ões) com custo desconhecido")
                }
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12)).frame(width: 16, height: 3)
            }
        }
        .frame(width: 24)
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Cards mais caros

struct CardsCaros: View {
    var cards: [Resumo.Card]
    var abrir: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TituloCard(texto: "Cards mais caros") {
                Text("abrir no Linear").font(.sf(11, .medium)).foregroundStyle(Tema.t4)
            }
            if cards.isEmpty {
                Text("Nenhuma execução nos últimos 7 dias")
                    .font(.sf(11)).foregroundStyle(Tema.t3)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
            } else {
                let maximo = max(cards.map(\.custoConhecido).max() ?? 0, 0.0001)
                ForEach(Array(cards.enumerated()), id: \.element.card) { i, c in
                    if i > 1 { Rectangle().fill(Tema.hair).frame(height: 0.5) }
                    LinhaCard(card: c, fracao: c.custoConhecido / maximo, destaque: i == 0) { abrir(c.card) }
                        .padding(.top, i == 0 ? 4 : 0)
                }
            }
        }
        .padding(.top, 11).padding(.horizontal, 12).padding(.bottom, 4)
    }
}

struct LinhaCard: View {
    var card: Resumo.Card
    var fracao: Double
    var destaque: Bool
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle().fill(Tema.cor(lane: card.laneDominante)).frame(width: 6, height: 6)
                        Text(card.card).font(.sf(13, .semibold)).tracking(-0.1).foregroundStyle(Tema.t1)
                        ForEach(card.lanes, id: \.self) { ChipLane(lane: $0) }
                        Spacer(minLength: 4)
                        if card.todasDesconhecidas {
                            Text("desconhecido").font(.sf(11, .medium)).foregroundStyle(Tema.t3)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("US$").font(.sf(10.5, .medium)).foregroundStyle(Tema.t3)
                                Text(Formato.valor(card.custoConhecido)).font(.sf(13, .semibold)).tracking(-0.2)
                                    .foregroundStyle(Tema.t1)
                            }
                            .monospacedDigit()
                        }
                    }
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                                RoundedRectangle(cornerRadius: 3).fill(gradienteLane(card.laneDominante))
                                    .frame(width: max(g.size.width * fracao, 3))
                                    .opacity(card.custoConhecido > 0 ? 1 : 0)
                            }
                        }
                        .frame(height: 4)
                        subtitulo
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? Tema.t2 : Tema.t4)
                    .frame(width: 12)
            }
            .padding(.vertical, 5)
            .padding(.leading, destaque ? 6 : 2)
            .padding(.trailing, 4)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(destaque ? 0.035 : 0).opacity(1) )
                .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.03 : 0))))
            .padding(.horizontal, destaque ? -4 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Abrir \(card.card) no Linear")
    }

    private var subtitulo: some View {
        HStack(spacing: 0) {
            Text(Formato.plural(card.execucoes, "execução", "execuções"))
            if card.erros > 0 {
                Text(" · ")
                Text(Formato.plural(card.erros, "erro", "erros")).foregroundStyle(Tema.bad)
            }
            if card.desconhecidas > 0 && !card.todasDesconhecidas {
                Text(" · \(card.desconhecidas) desconh.")
            }
        }
        .font(.sf(10.5)).foregroundStyle(Tema.t3).lineLimit(1).fixedSize()
    }
}

// MARK: - Divisão por lane

struct DivisaoLanes: View {
    var lanes: [Resumo.Lane]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TituloCard(texto: "Divisão por lane") {
                Text("últimos 7 dias").font(.sf(11, .medium)).foregroundStyle(Tema.t4)
            }
            barra.frame(height: 8).padding(.vertical, 9)
            if lanes.isEmpty {
                Text("Nenhuma execução nos últimos 7 dias").font(.sf(11)).foregroundStyle(Tema.t3)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(lanes.enumerated()), id: \.element.lane) { i, l in
                        if i > 0 { Spacer(minLength: 12) }
                        ItemLane(lane: l, direita: i == lanes.count - 1 && lanes.count > 1)
                    }
                }
            }
        }
        .padding(.top, 11).padding(.horizontal, 14).padding(.bottom, 11)
    }

    @ViewBuilder private var barra: some View {
        let comCusto = lanes.filter { $0.custoConhecido > 0 }
        let total = comCusto.map(\.custoConhecido).reduce(0, +)
        GeometryReader { g in
            if comCusto.isEmpty {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07))
            } else {
                let espaco = CGFloat(comCusto.count - 1) * 3
                let minimo: CGFloat = 8
                let util = max(g.size.width - espaco - minimo * CGFloat(comCusto.count), 0)
                HStack(spacing: 3) {
                    ForEach(comCusto, id: \.lane) { l in
                        RoundedRectangle(cornerRadius: 2).fill(gradienteLane(l.lane))
                            .frame(width: minimo + util * CGFloat(l.custoConhecido / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

struct ItemLane: View {
    var lane: Resumo.Lane
    var direita: Bool

    var body: some View {
        HStack(spacing: 9) {
            if direita { textos; selo } else { selo; textos }
        }
    }

    private var selo: some View {
        let cor = Tema.cor(lane: lane.lane)
        return Text(String(lane.lane.prefix(1)).uppercased())
            .font(.sf(12, .bold)).foregroundStyle(cor)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(cor.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cor.opacity(0.35), lineWidth: 0.5))
    }

    private var textos: some View {
        VStack(alignment: direita ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(lane.lane).font(.sf(12.5, .semibold)).foregroundStyle(Tema.t1)
                if lane.todasDesconhecidas {
                    Text("custo desconhecido").font(.sf(11.5, .medium)).foregroundStyle(Tema.t3)
                } else {
                    Text(Formato.usd(lane.custoConhecido)).font(.sf(12.5, .bold)).monospacedDigit()
                        .foregroundStyle(Tema.t1)
                }
            }
            Text(meta).font(.sf(10.5)).monospacedDigit().foregroundStyle(Tema.t3)
        }
        .lineLimit(1)
    }

    private var meta: String {
        var partes = ["\(lane.execucoes) exec."]
        let total = lane.duracaoMs + lane.duracaoEstimadaMs
        if total > 0 {
            partes.append((lane.duracaoEstimadaMs > 0 ? "~" : "") + Formato.duracao(ms: total))
        }
        if lane.desconhecidas > 0 && !lane.todasDesconhecidas {
            partes.append("\(lane.desconhecidas) desconh.")
        }
        return partes.joined(separator: " · ")
    }
}

// MARK: - Retomar

/// Lanes que pararam sem fechar o card: o botão copia `cd <worktree> && <cli> --resume <id>`.
struct CardRetomar: View {
    var retomadas: [Retomada]
    var copiar: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TituloCard(texto: "Parou · retomar") {
                Text("copia o comando").font(.sf(11, .medium)).foregroundStyle(Tema.t4)
            }
            .padding(.bottom, 4)
            ForEach(Array(retomadas.enumerated()), id: \.element.card) { i, r in
                if i > 0 { Rectangle().fill(Tema.hair).frame(height: 0.5) }
                LinhaRetomar(retomada: r, copiar: copiar)
            }
        }
        .padding(.top, 11).padding(.horizontal, 14).padding(.bottom, 7)
    }
}

struct LinhaRetomar: View {
    var retomada: Retomada
    var copiar: (String) -> Void
    @State private var hover = false
    @State private var copiado = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(Tema.cor(lane: retomada.lane)).frame(width: 6, height: 6)
                        Text(retomada.card).font(.sf(13, .semibold)).tracking(-0.1).foregroundStyle(Tema.t1)
                        ChipLane(lane: retomada.lane)
                        Text(retomada.rotulo).font(.sf(10.5, .medium))
                            .foregroundStyle(retomada.rotulo == "lane:falhou" ? Tema.bad : Tema.warn)
                        Text(Formato.ha(retomada.inicio, agora: ctx.date)).font(.sf(10.5)).foregroundStyle(Tema.t3)
                    }
                    if let m = retomada.motivo {
                        Text(m).font(.sf(10.5)).foregroundStyle(Tema.t3).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                Button {
                    copiar(retomada.comando)
                    copiado = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        copiado = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiado ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copiado ? "copiado" : "retomar").font(.sf(11, .semibold))
                    }
                    .foregroundStyle(copiado ? Tema.ok : Color.white.opacity(hover ? 0.95 : 0.75))
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(retomada.comando)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Rodapé

struct Rodape: View {
    var resumo: Resumo
    var abrirConfig: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let rodando = resumo.rodando.first
            HStack(spacing: 8) {
                HStack(spacing: 13) {
                    PontoPulsando(ativo: rodando != nil, cor: (rodando?.travada ?? false) ? Tema.bad : Tema.ok)
                        .padding(.leading, 3)
                    Text("AGORA").font(.sf(10.5, .bold)).tracking(0.8)
                        .foregroundStyle(rodando != nil ? Tema.ok : Tema.t3)
                        .padding(.leading, -2)
                    texto(rodando, agora: ctx.date).font(.sf(12)).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                HStack(spacing: 9) {
                    Text("custo desconhecido: \(resumo.desconhecidas7d)").font(.sf(11)).monospacedDigit()
                        .foregroundStyle(Tema.t3).lineLimit(1).fixedSize()
                        .help("Execuções dos últimos 7 dias sem custo (morta, em andamento, sem custo informado ou parcial). Não entram na soma.")
                    BotaoAbrirComando.painelLogs
                    BotaoAbrirComando.janelaLanes
                    BotaoEngrenagem(acao: abrirConfig)
                    BotaoSair()
                }
            }
            .padding(.vertical, 8).padding(.leading, 14).padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(stops: [
                        .init(color: rodando != nil ? Tema.ok.opacity(0.10) : Color.white.opacity(0.04), location: 0),
                        .init(color: Color.white.opacity(0.03), location: 0.55)],
                        startPoint: .leading, endPoint: .trailing)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(rodando != nil ? Tema.ok.opacity(0.22) : Color.white.opacity(0.09), lineWidth: 0.5))
        }
    }

    private func texto(_ rodando: Resumo.Rodando?, agora: Date) -> Text {
        guard let r = rodando else {
            var t = Text("nenhuma lane rodando").foregroundColor(Tema.t2)
            if let hb = resumo.heartbeatData {
                t = t + Text(" · dispatcher \(Formato.ha(hb, agora: agora))").foregroundColor(Tema.t3)
                if resumo.heartbeat?.dryRun == true { t = t + Text(" (simulação)").foregroundColor(Tema.t3) }
            }
            return t
        }
        var meta: [String] = []
        if let d = r.desde { meta.append(Formato.ha(d, agora: agora)) }
        if let n = r.respostas { meta.append("~\(n) turnos") }
        if r.travada { meta.append("travada") }
        var t = Text(r.lane).foregroundColor(Tema.cor(lane: r.lane)).fontWeight(.semibold)
            + Text(" rodando ").foregroundColor(Tema.t1).fontWeight(.medium)
            + Text(r.card).foregroundColor(Tema.t1).fontWeight(.bold)
        if !meta.isEmpty { t = t + Text(" · " + meta.joined(separator: " · ")).foregroundColor(Tema.t3) }
        for outra in resumo.rodando.dropFirst() {
            t = t + Text("  + ").foregroundColor(Tema.t3)
                + Text(outra.lane).foregroundColor(Tema.cor(lane: outra.lane)).fontWeight(.semibold)
                + Text(" " + outra.card).foregroundColor(Tema.t1).fontWeight(.semibold)
        }
        return t
    }
}

struct BotaoEngrenagem: View {
    var acao: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: acao) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.7))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(String(localized: "Abrir os Ajustes"))
    }
}

/// Botão do rodapé que encerra o app (igual ao "Sair" da barra de menus).
struct BotaoSair: View {
    @State private var hover = false
    var body: some View {
        Button { PresencaApp.sair() } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.7))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(String(localized: "Sair do TuttiDash"))
    }
}


/// Botão do rodapé que abre um `.command` da config no Terminal, só quando a titular clica.
/// Reutilizado pelo painel de logs e pela janela das lanes: muda só a chave, o padrão, o ícone e a ajuda.
struct BotaoAbrirComando: View {
    let chave: String
    let padrao: String
    let simbolo: String
    let ajuda: String
    @State private var hover = false
    var body: some View {
        Button {
            let cfg = Configuracao.lerArquivo()
            let caminho = Configuracao.valor(chave, em: cfg).map { "\($0)" } ?? padrao
            let cmd = Configuracao.expandir(caminho, ambiente: [:], home: FileManager.default.homeDirectoryForCurrentUser)
            NSWorkspace.shared.open([cmd], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Image(systemName: simbolo)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.7))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(ajuda)
    }
}

extension BotaoAbrirComando {
    /// Painel único de logs (tmux «painel»).
    static var painelLogs: BotaoAbrirComando {
        BotaoAbrirComando(chave: "painel.comando", padrao: Legado.painelComando, simbolo: "terminal",
                          ajuda: String(localized: "Abrir o painel de logs (testes, dispatcher e vigia)"))
    }
    /// Janela única das lanes (tmux «lanes»): uma por lane, na ordem das lanes.
    static var janelaLanes: BotaoAbrirComando {
        BotaoAbrirComando(chave: "painel.lanes_comando", padrao: Legado.lanesComando, simbolo: "rectangle.split.1x2",
                          ajuda: String(localized: "Abrir a janela das lanes"))
    }
}
