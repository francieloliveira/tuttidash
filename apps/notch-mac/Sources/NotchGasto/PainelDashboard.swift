import SwiftUI
import GastoCore

/// Dashboard do painel v2, fiel à imagem de referência em 1600×900.
/// Mocks (aparecem e não fazem nada, sem número inventado): «↑» de lanes ativas, `#nº` da fila
/// do lock e «ignorado» nos testes. O resto vem do snapshot.
struct DashboardPainel: View {
    @ObservedObject var modelo: ModeloNotch
    var largura: CGFloat
    var ir: (PaginaPainel) -> Void
    @State private var periodo: PeriodoCustos = .semana
    @State private var alertasFechados: [String]?
    @State private var verAlertas = false
    @State private var expandida: String?

    private var snap: SnapshotPainel? { modelo.snapshot }
    private var ind: IndicadoresPainel { snap?.indicadores ?? .vazio }
    private var moeda: MoedaPainel { snap?.custos.moeda ?? .usd }
    private var alertas: [String] { snap?.alertasPainel ?? [] }

    /// Largura do conteúdo na imagem (1600 − 208 da barra − 2 × 22 de margem).
    static let larguraDesenho: CGFloat = 1348

    var body: some View {
        // Abaixo da largura da imagem, o Dashboard inteiro encolhe por igual (as proporções ficam).
        let escala = min(1, largura / Self.larguraDesenho)
        let base = max(largura, Self.larguraDesenho)
        conteudo(largura: base)
            .frame(width: base)
            .scaleEffect(escala, anchor: .topLeading)
            .frame(width: base * escala, height: alturaConteudo * escala, alignment: .topLeading)
    }

    private var alturaConteudo: CGFloat {
        (alertasFechados == nil || alertasFechados != alertas) ? 840 : 783
    }

    private func conteudo(largura: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(spacing: 0) {
                kpis(largura).frame(height: 88).padding(.top, 10)
                if alertasFechados == nil || alertasFechados != alertas {
                    faixaAlertas.frame(height: 44).padding(.top, 13)
                }
                meio(largura, agora: ctx.date).frame(height: 430).padding(.top, 14)
                custos(largura, agora: ctx.date).frame(height: 228).padding(.top, 13)
            }
        }
    }

    // MARK: Cartões do topo

    private func kpis(_ largura: CGFloat) -> some View {
        let k = (largura - 48) / 1300
        return HStack(spacing: 16) {
            kpi(icone: IconeCartao(simbolo: "square.3.layers.3d", cor: PV.teal, fundo: PV.tealFundo, tamanho: 54, tamanhoIcone: 26),
                rotulo: "Lanes ativas", valor: "\(ind.lanesAtivas) / \(ind.lanesTotal)", espaco: 16) {
                // Mock: sem histórico do nº de lanes ativas, a variação não tem número.
                Text("—").font(PV.fonte(13, .semibold)).foregroundStyle(PV.verde).help("Variação: em breve")
            } abaixo: {
                BarraPV(fracao: ind.lanesTotal > 0 ? Double(ind.lanesAtivas) / Double(ind.lanesTotal) : 0,
                        cor: PV.teal, altura: 4, trilho: PV.trilho)
                    .frame(width: 143).padding(.leading, 63)
            } direita: { EmptyView() }
            .frame(width: 316 * k)

            kpi(icone: IconeCartao(simbolo: "bolt", cor: PV.azulIcone, fundo: PV.azulFundo, tamanho: 54, tamanhoIcone: 25),
                rotulo: "Builds hoje", valor: "\(ind.buildsHoje)", espaco: 12) {
                variacao(ind.buildsHoje - ind.buildsOntem, sobeBom: true)
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: ind.buildsSerie.suffix(11).map(Double.init)) { i, _ in
                    i >= 8 ? PV.azul : (i >= 2 ? PV.azulIcone : Color(hex: 0x2F7BEA))
                }
                .padding(.top, 12)
            }
            .frame(width: 296 * k)

            kpi(icone: IconeCartao(simbolo: "xmark.circle", cor: PV.vermelho, fundo: PV.vermelhoFundo, tamanho: 54, tamanhoIcone: 27),
                rotulo: "Falhas (24h)", valor: "\(ind.falhas24h)", espaco: 14) {
                Text(ind.falhasPct.map { Formato.pct($0) } ?? "—").font(PV.fonte(13, .semibold)).foregroundStyle(PV.vermelho)
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: ind.falhasSerie.map(Double.init)) { _, v in v > 0 ? PV.vermelho : Color(hex: 0x3A4868) }
                    .padding(.top, 12)
            }
            .frame(width: 336 * k)

            kpi(icone: IconeCartao(simbolo: "cylinder.split.1x2", cor: PV.dourado, fundo: PV.ambarFundo, tamanho: 54, tamanhoIcone: 25),
                rotulo: "Custo da semana", valor: snap?.custos.semana.map { moeda.texto($0) } ?? "sem dado", espaco: 12) {
                variacaoCusto
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: (snap?.custos.dias ?? []).map(\.total), cor: { _, _ in PV.verde }, largura: 5)
                    .padding(.top, 10)
            }
            .frame(width: 352 * k)
        }
    }

    private func kpi<Delta: View, Abaixo: View, Direita: View>(
        icone: IconeCartao, rotulo: String, valor: String, espaco: CGFloat,
        @ViewBuilder delta: () -> Delta, @ViewBuilder abaixo: () -> Abaixo, @ViewBuilder direita: () -> Direita
    ) -> some View {
        HStack(spacing: 0) {
            icone.padding(.trailing, 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(rotulo).font(PV.fonte(13)).foregroundStyle(PV.texto2).fixedSize()
                HStack(spacing: espaco) {
                    Text(valor).font(PV.fonte(24, .bold)).lineLimit(1).fixedSize()
                        .contentTransition(.numericText())
                        .animation(DS.anim(DS.mola), value: valor)
                    delta().fixedSize()
                }
                abaixo()
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            direita()
        }
        .padding(.leading, 16).padding(.trailing, 22)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [PV.kpiTopo, PV.kpiBase], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.1), PV.kpiBorda], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func variacao(_ d: Int, sobeBom: Bool) -> some View {
        let cor: Color = d == 0 ? PV.mudo : ((d > 0) == sobeBom ? PV.verde : PV.vermelho)
        return Text(d > 0 ? "↑ \(d)" : (d < 0 ? "↓ \(-d)" : "= 0"))
            .font(PV.fonte(13, .semibold)).foregroundStyle(cor)
            .help("Comparado com ontem")
    }

    /// Subiu: ↑ vermelho. Caiu: ↓ verde. Sem semana anterior: «—».
    private var variacaoCusto: some View {
        Group {
            if let v = ind.variacaoSemanaPct {
                Text(v >= 0 ? "↑ \(Formato.pct(abs(v)))" : "↓ \(Formato.pct(abs(v)))")
                    .foregroundStyle(v > 0 ? PV.vermelho : PV.verde)
            } else {
                Text("—").foregroundStyle(PV.mudo)
            }
        }
        .font(PV.fonte(13, .semibold))
        .help("Comparado com a semana anterior até o mesmo ponto")
    }

    // MARK: Alertas

    private var faixaAlertas: some View {
        let vazio = alertas.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: vazio ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17)).foregroundStyle(vazio ? PV.verde : Color(hex: 0xF5A524))
            Text("ALERTAS").font(PV.fonte(12.5, .bold)).tracking(0.2)
                .foregroundStyle(vazio ? PV.mudo : Color(hex: 0xFF5A6E)).padding(.trailing, 11)
            if vazio {
                Text("Nenhum alerta agora").font(PV.fonte(12.5)).foregroundStyle(PV.texto)
            } else {
                HStack(spacing: 14) {
                    ForEach(Array(alertas.enumerated()), id: \.offset) { i, a in
                        if i > 0 { Text("•").foregroundStyle(PV.vermelho) }
                        Text(a.hasSuffix(".") ? String(a.dropLast()) : a).font(PV.fonte(12.5)).lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            }
            Spacer(minLength: 8)
            if !vazio {
                Button { verAlertas.toggle() } label: {
                    HStack(spacing: 8) {
                        Text("Ver detalhes").underline()
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(PV.fonte(12.5)).foregroundStyle(PV.azul)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $verAlertas, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(alertas.enumerated()), id: \.offset) { _, a in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(PV.vermelho).frame(width: 6, height: 6).padding(.top, 5)
                                Text(a).font(PV.fonte(12.5)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14).frame(width: 380, alignment: .leading)
                }
                Button { alertasFechados = alertas } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x7F8EA8))
                        .frame(width: 44, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .help("Esconder até a lista de alertas mudar")
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
            vazio ? AnyShapeStyle(PV.cartao)
                  : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x2A1324), Color(hex: 0x1C1121), Color(hex: 0x1A1222)],
                                                 startPoint: .leading, endPoint: .trailing))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(vazio ? PV.cartaoBorda : Color(hex: 0x873D4E), lineWidth: 1))
    }

    // MARK: Linha do meio

    private func meio(_ largura: CGFloat, agora: Date) -> some View {
        let m = (largura - 26) / 1322
        return HStack(alignment: .top, spacing: 13) {
            cartaoLanes(agora: agora).frame(width: 474 * m)
            VStack(spacing: 12) {
                cartaoBuilds(agora: agora).frame(height: 164)
                cartaoTestes.frame(height: 254)
            }
            .frame(width: 409 * m)
            VStack(spacing: 12) {
                cartaoDispatcher.frame(height: 224)
                cartaoEntregas(agora: agora).frame(height: 194)
            }
            .frame(width: 439 * m)
        }
    }

    private func cartaoLanes(agora: Date) -> some View {
        let linhas = snap?.lanes ?? []
        return CartaoPV {
            VStack(alignment: .leading, spacing: 6) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "square.3.layers.3d", cor: PV.teal, fundo: PV.tealFundo, tamanhoIcone: 20),
                                titulo: "Lanes", subtitulo: Formato.plural(linhas.count, "lane no total", "lanes no total")) {
                    BotaoVer(texto: "Ver todas") { ir(.lanes) }
                }
                .padding(.horizontal, 4).padding(.bottom, 10)
                if linhas.isEmpty {
                    Text("Sem leitura das lanes").font(PV.fonte(12.5)).foregroundStyle(PV.mudo).padding(.horizontal, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(linhas, id: \.lane) { linha in
                                LinhaLaneDashboard(linha: linha, modelo: modelo, agora: agora,
                                                   aberta: expandida == linha.lane) {
                                    expandida = expandida == linha.lane ? nil : linha.lane
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 14).padding(.horizontal, 11).padding(.bottom, 12)
        }
    }

    private func cartaoBuilds(agora: Date) -> some View {
        let fila = (snap?.provas ?? []).filter { $0.posicaoFila != nil }.sorted { ($0.posicaoFila ?? 0) < ($1.posicaoFila ?? 0) }
        let livre = snap?.lockLane == nil
        return CartaoPV {
            VStack(alignment: .leading, spacing: 12) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "cube", tamanhoIcone: 19), titulo: "Builds", subtitulo: "Lock de build e fila") {
                    BotaoVer(texto: "Ver fila") { ir(.builds) }
                }
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lock de build").font(PV.fonte(12.5))
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8).fill(livre ? PV.verdeFundo : PV.ambarFundo)
                                .frame(width: 34, height: 34)
                                .overlay(Image(systemName: livre ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 16)).foregroundStyle(livre ? Color(hex: 0x12E3B0) : PV.ambar))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(livre ? "Livre" : "Ocupado").font(PV.fonte(15, .semibold))
                                    .foregroundStyle(livre ? PV.verdeClaro : PV.ambar)
                                Text(livre ? "sem lock" : textoLock).font(PV.fonte(12)).foregroundStyle(PV.mudo).lineLimit(1)
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 167, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .linhaPV(borda: false)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fila (\(fila.count))").font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                        if fila.isEmpty {
                            Text("vazia").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        }
                        ForEach(Array(fila.prefix(2).enumerated()), id: \.offset) { _, carta in
                            HStack(spacing: 10) {
                                // Mock: item da fila ainda não é execução, então não tem `#N`.
                                Text("#—").font(PV.fonte(12.5)).foregroundStyle(PV.mudo).help("O número sai quando a build começa")
                                Text(carta.lane.isEmpty ? carta.card : carta.lane).font(PV.fonte(12.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("aguardando").font(PV.fonte(10)).foregroundStyle(PV.mudo)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .linhaPV(borda: false)
                }
            }
            .padding(14)
        }
    }

    private var textoLock: String {
        let quem = [snap?.lockLane, snap?.lockCard].compactMap { $0 }.joined(separator: " · ")
        let tempo = snap?.lockSegundos.map { "há \(Formato.relogio($0))" }
        return [quem, tempo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var cartaoTestes: some View {
        let total = ind.testesHoje
        return CartaoPV {
            VStack(alignment: .leading, spacing: 0) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "flask", tamanhoIcone: 18),
                                titulo: "Testes", subtitulo: "Execução de provas automatizadas") {
                    BotaoVer(texto: "Ver todos") { ir(.testes) }
                }
                HStack(spacing: 22) {
                    Rosca(passou: ind.testesPassou, falhou: ind.testesFalhou)
                        .frame(width: 142, height: 142)
                    VStack(alignment: .leading, spacing: 20) {
                        legenda(cor: Color(hex: 0x19E58C), texto: "\(ind.testesPassou) passou", pct: pct(ind.testesPassou, total))
                        legenda(cor: Color(hex: 0xF64561), texto: "\(ind.testesFalhou) falhou", pct: pct(ind.testesFalhou, total))
                        // Mock: o parser da prova ainda não lê testes pulados.
                        legenda(cor: Color(hex: 0x8DA6D0), texto: "— ignorado", pct: "—")
                            .help("Testes ignorados: em breve")
                    }
                    .padding(.vertical, 10.5).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .linhaPV(borda: false)
                }
                .padding(.top, 18).padding(.leading, 8)
                Button { ir(.testes) } label: {
                    Text(ind.provasHoje == 0 ? "Nenhuma prova executada hoje."
                         : Formato.plural(ind.provasHoje, "prova executada hoje.", "provas executadas hoje."))
                        .underline().font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 0)
            }
            .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private func pct(_ n: Int, _ total: Int) -> String {
        total > 0 ? "\(Int((Double(n) * 100 / Double(total)).rounded()))%" : "0%"
    }

    private func legenda(cor: Color, texto: String, pct: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(cor).frame(width: 11, height: 11)
            Text(texto).font(PV.fonte(12.5))
            Spacer(minLength: 4)
            Text(pct).font(PV.fonte(12.5))
        }
    }

    private var cartaoDispatcher: some View {
        let vivo = snap?.dispatcherVivo == true
        let pausa = snap?.pausa == true
        let (rotulo, cor): (String, Color) = pausa ? ("Pausado", PV.ambar) : (vivo ? ("Operacional", PV.verde) : ("Parado", PV.vermelho))
        return CartaoPV {
            VStack(alignment: .leading, spacing: 0) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "gearshape", tamanhoIcone: 19),
                                titulo: "Dispatcher", subtitulo: "Estado do sistema") {
                    HStack(spacing: 7) {
                        Circle().fill(cor).frame(width: 8, height: 8)
                        Text(rotulo).font(PV.fonte(12, .medium)).foregroundStyle(cor == PV.verde ? Color(hex: 0x35E08A) : cor)
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(cor.opacity(0.18)))
                }
                VStack(spacing: 10.3) {
                    parDispatcher(vivo ? PV.verde : PV.vermelho, "Batimento", batimento)
                    parDispatcher(pausa ? PV.ambar : PV.verde, "Pausa", pausa ? "ligada" : "desligada")
                    parDispatcher(PV.verde, "Fila pronta", snap?.filaPronta.isEmpty == false ? snap!.filaPronta.joined(separator: ", ") : "vazia")
                    parDispatcher(PV.azulForte, "Próxima decisão", snap?.proximaDecisao ?? "sem decisão nova")
                    parDispatcher(PV.azulForte, "Strikes opencode", snap?.strikesTexto ?? "sem registro")
                }
                .padding(.top, 13).padding(.leading, 10).padding(.trailing, 8)
                HStack(spacing: 0) {
                    Text("Baixo: < \(Int(LanesPainel.folgaBaixo))%")
                    Spacer(minLength: 8)
                    Text("Médio: < \(Int(LanesPainel.folgaMedio))%")
                    Spacer(minLength: 8)
                    Text("Alto: < \(Int(LanesPainel.folgaAlto))%")
                    Spacer(minLength: 0)
                }
                .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                .padding(.top, 14).padding(.leading, 10).padding(.trailing, 40)
            }
            .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    private var batimento: String {
        let t = snap?.batimentoTexto ?? "sem batimento"
        return t.hasPrefix("último ciclo ") ? String(t.dropFirst("último ciclo ".count)) : t
    }

    private func parDispatcher(_ cor: Color, _ nome: String, _ valor: String) -> some View {
        HStack(spacing: 12) {
            Circle().fill(cor).frame(width: 8, height: 8)
            Text(nome).foregroundStyle(PV.texto2)
            Spacer(minLength: 8)
            Text(valor).lineLimit(1).truncationMode(.middle)
        }
        .font(PV.fonte(12.5))
    }

    private func cartaoEntregas(agora: Date) -> some View {
        let entregas = snap?.entregas ?? []
        return CartaoPV {
            VStack(alignment: .leading, spacing: 0) {
                CabecalhoCartao(icone: IconeCartao(tamanhoIcone: 19, foguete: true),
                                titulo: "Entregas", subtitulo: "Últimas entregas realizadas") {
                    BotaoVer(texto: "Ver todos") { ir(.entregas) }
                }
                if entregas.isEmpty {
                    Text("Nenhum card fechado neste registro").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        .padding(.top, 14).padding(.leading, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entregas.prefix(5).enumerated()), id: \.offset) { _, e in
                            HStack(spacing: 0) {
                                Circle().fill(PV.verde).frame(width: 8, height: 8).padding(.trailing, 16)
                                Text(e.card).font(PV.fonte(12.5, .bold)).frame(width: 78, alignment: .leading)
                                Text("\(e.lane) • \(e.pr ?? e.quando)").font(PV.fonte(12)).foregroundStyle(PV.mudo).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(haPainel(e.quandoData, agora: agora) ?? "").font(PV.fonte(12)).foregroundStyle(PV.mudo)
                            }
                            .frame(height: 26.5)
                        }
                    }
                    .background(alignment: .leading) {
                        Rectangle().fill(Color(hex: 0x1E8F52)).frame(width: 2).padding(.vertical, 10).padding(.leading, 3)
                    }
                    .padding(.top, 8).padding(.leading, 10)
                }
            }
            .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 0)
        }
    }

    // MARK: Custos

    private func custos(_ largura: CGFloat, agora: Date) -> some View {
        let p = snap?.custos.periodos[periodo]
        let c = (largura - 48) / 1300
        return CartaoPV {
            VStack(spacing: 9) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "cylinder.split.1x2", tamanhoIcone: 19),
                                titulo: "Custos", subtitulo: "Uso de recursos e gastos estimados") {
                    SeletorPeriodo(periodo: $periodo)
                }
                .padding(.leading, 3)
                HStack(spacing: 12) {
                    painelGastoLane(p).frame(width: 424 * c)
                    GraficoGasto(barras: p?.barras ?? [], moeda: moeda, titulo: tituloGrafico)
                        .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 16)
                        .frame(width: 413 * c)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: 10).fill(PV.interno))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PV.cartaoBorda, lineWidth: 1))
                    painelTop(p?.top ?? [], agora: agora).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    private var tituloGrafico: String {
        switch periodo {
        case .semana: return "Evolução do gasto diário"
        case .mes: return "Evolução do gasto semanal"
        case .ano: return "Evolução do gasto mensal"
        }
    }

    private func painelGastoLane(_ p: CustosPeriodo?) -> some View {
        let lanes = p?.porLane ?? []
        let maximo = lanes.compactMap(\.custoUSD).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Gasto por lane (\(periodo.complemento))").font(PV.fonte(13, .medium))
            ForEach(Array(lanes.enumerated()), id: \.offset) { i, l in
                HStack(spacing: 0) {
                    Text(l.lane).font(PV.fonte(12.5)).frame(width: 87, alignment: .leading)
                    BarraPV(fracao: maximo > 0 ? (l.custoUSD ?? 0) / maximo : 0, cor: PV.barrasLane[i % PV.barrasLane.count])
                    Text(l.custoUSD.map { moeda.texto($0) } ?? (l.desconhecidas > 0 ? "—" : "sem gasto"))
                        .font(PV.fonte(12.5, l.custoUSD == nil ? .regular : .semibold))
                        .foregroundStyle(l.custoUSD == nil ? PV.mudo : PV.texto)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 66, alignment: .leading)
                        .padding(.leading, 14)
                }
                .frame(height: 15)
            }
        }
        .padding(.top, 12).padding(.leading, 13).padding(.trailing, 12).padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.interno))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PV.cartaoBorda, lineWidth: 1))
    }

    private func painelTop(_ top: [CardCaro], agora: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Builds mais caros (top 5)").font(PV.fonte(12.5, .medium))
                Spacer()
                BotaoVer(texto: "Ver todos", pequeno: true) { ir(.custos) }
            }
            .padding(.bottom, 2)
            if top.isEmpty {
                Text("Sem gasto conhecido neste período").font(PV.fonte(12)).foregroundStyle(PV.mudo).padding(.top, 6)
            }
            ForEach(Array(top.prefix(5).enumerated()), id: \.offset) { i, card in
                HStack(spacing: 0) {
                    Circle().fill(i == 0 ? Color(hex: 0xC9A56A) : Color(hex: 0x2A3A52)).frame(width: 17, height: 17)
                        .overlay(Text("\(i + 1)").font(PV.fonte(10, .bold))
                            .foregroundStyle(i == 0 ? Color(hex: 0x1A1206) : Color(hex: 0xD5DEEA)))
                    Button { modelo.abrirCard(card.card) } label: {
                        Text(card.card).font(PV.fonte(12, .semibold)).foregroundStyle(PV.azul)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 76, alignment: .leading).padding(.leading, 12)
                    Text("\(card.lane) • \(Formato.plural(card.tentativas, "tentativa", "tentativas"))")
                        .font(PV.fonte(12)).foregroundStyle(PV.mudo).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(card.custoUSD.map { moeda.texto($0) } ?? "sem custo")
                        .font(PV.fonte(13.5, .semibold)).foregroundStyle(card.custoUSD == nil ? PV.mudo : PV.vermelho)
                        .frame(width: 84, alignment: .leading)
                    Text(haPainel(card.ultimoInicio, agora: agora) ?? "").font(PV.fonte(12)).foregroundStyle(PV.mudo)
                        .frame(width: 62, alignment: .trailing)
                }
                .frame(height: 24.2)
            }
        }
        .padding(.top, 8).padding(.horizontal, 12).padding(.bottom, 4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.interno))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PV.cartaoBorda, lineWidth: 1))
    }
}

/// Uma lane no cartão do Dashboard. › expande o detalhe; ⋮ abre as ações que já existem.
struct LinhaLaneDashboard: View {
    var linha: LinhaLane
    @ObservedObject var modelo: ModeloNotch
    var agora: Date
    var aberta: Bool
    var alternar: () -> Void
    /// Barra de uso da conta na própria linha (só na página Lanes, que tem espaço).
    var mostrarUso = false
    @State private var hover = false

    var body: some View {
        let estado = EstadoPilula(linha.estado)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: alternar) {
                    HStack(spacing: 0) {
                        Image(systemName: aberta ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(PV.icone).frame(width: 14)
                        Circle().fill(estado.corLane).frame(width: 9, height: 9).padding(.leading, 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(linha.lane).font(PV.fonte(13.5, .semibold)).lineLimit(1)
                            Text(secundaria(linha)).font(PV.fonte(11.5)).foregroundStyle(PV.mudo).lineLimit(1)
                                .truncationMode(.middle)
                                .help(secundaria(linha))
                        }
                        .frame(width: 104, alignment: .leading)
                        .padding(.leading, 9)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(aberta ? "Recolher \(linha.lane)" : "Expandir \(linha.lane)")
                PilulaEstado(estado: estado).fixedSize().frame(width: 97, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    if linha.estado == .rodando, let card = linha.card {
                        // O nº de build é da lane, não do card. Rodando, o que importa é o card.
                        Text(verbatim: card).font(PV.fonte(12.5, .semibold)).foregroundStyle(PV.azul)
                        Text("em execução").font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    } else if linha.estado == .livre {
                        Text(verbatim: linha.ultimaBuild.map { "build #" + String($0) } ?? "—").font(PV.fonte(12.5))
                        Text(haPainel(linha.ultimaBuildInicio, agora: agora) ?? "sem build").font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    } else {
                        // Pausada/desligada não está executando build: mostrar a última só confunde.
                        Text("—").font(PV.fonte(12.5)).foregroundStyle(PV.apagado)
                    }
                }
                .padding(.leading, 10)
                Spacer(minLength: 4)
                if mostrarUso, linha.pct != nil {
                    BarraUso(pct: linha.pct, altura: 5).frame(width: 92)
                        .help("Uso da conta \(linha.janela ?? "")")
                        .padding(.trailing, 6)
                }
                if modelo.lanesEmAcao.contains(linha.lane) {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                MenuLane(linha: linha, modelo: modelo)
            }
            .padding(.leading, 10).padding(.trailing, 6)
            .frame(height: 51)
            .overlay(alignment: .bottom) {
                if linha.estado == .rodando, let s = linha.segundosNoCard {
                    BarraProgresso(progresso: ProgressoProcesso.estimado(inicio: agora.addingTimeInterval(-Double(s)),
                                                                         duracaoTipica: 45 * 60, agora: agora),
                                   cor: PV.verde, altura: 2, mostrarLegenda: false)
                        .padding(.horizontal, 10)
                        .help("No card há \(TextoTempo.duracao(Double(s)))")
                }
            }
            if aberta {
                DetalheLane(linha: linha)
                    .padding(.leading, 38).padding(.trailing, 10).padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .linhaPV()
        .clipped()
        .animation(DS.anim(DS.mola), value: aberta)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PV.azul.opacity(hover ? 0.35 : 0), lineWidth: 1))
    }

    private func secundaria(_ linha: LinhaLane) -> String {
        if let texto = linha.textoModelo { return texto }
        return linha.branch ?? "—"
    }
}

/// Detalhe que o painel v1 já mostrava: card, situação, uso da conta e plano.
struct DetalheLane: View {
    var linha: LinhaLane

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let texto = linha.textoModelo {
                Text(texto).font(PV.fonte(12, .semibold)).lineLimit(1)
            }
            if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                Text(aviso).font(PV.fonte(11.5, .semibold))
                    .foregroundStyle(Color(hex: 0xFF8DA3))
                    .lineLimit(2)
            }
            Text(linha.estado == .desligada ? "desligada" : linha.descricao).font(PV.fonte(12)).lineLimit(2)
            if !linha.detalhe.isEmpty {
                Text(linha.detalhe).font(PV.fonte(11.5)).foregroundStyle(PV.mudo).lineLimit(1)
            }
            HStack(spacing: 10) {
                BarraUso(pct: linha.pct, altura: 6).frame(width: 130)
                if let j = linha.janela { Text(j).font(PV.fonte(11.5)).foregroundStyle(PV.mudo) }
                if let plano = linha.plano {
                    Text(plano.rotulo).font(PV.fonte(10.5, .semibold))
                        .foregroundStyle(plano == .pago ? Color(hex: 0xB9A6FF) : PV.verde)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder((plano == .pago ? Color(hex: 0x8B6CFF) : PV.verde).opacity(0.7), lineWidth: 1))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(PV.cartao))
    }
}

/// ⋮ da lane: desativar/ativar (lanes_ctl.py), abrir o card no Linear, copiar o comando para retomar.
/// Popover em vez de `Menu`: o `Menu` do macOS achata o rótulo e não desenha os três pontos em pé.
struct MenuLane: View {
    var linha: LinhaLane
    @ObservedObject var modelo: ModeloNotch
    @State private var aberto = false

    var body: some View {
        Button { aberto.toggle() } label: {
            VStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(PV.icone).frame(width: 3.6, height: 3.6) }
            }
            .frame(width: 32, height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(aberto ? Color(hex: 0x13233B) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ações da lane \(linha.lane)")
        .popover(isPresented: $aberto, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                if linha.estado == .desligada {
                    item("Ativar lane", cor: PV.texto) { modelo.ativarLane(linha.lane) }
                } else {
                    item("Desativar lane", cor: Color(hex: 0xFF8DA3)) { modelo.desativarLane(linha.lane) }
                }
                if let card = linha.card {
                    item("Abrir \(card) no Linear", cor: PV.texto) { modelo.abrirCard(card) }
                }
                if let r = modelo.retomadas.first(where: { $0.lane == linha.lane }) {
                    item("Copiar comando para retomar \(r.card)", cor: PV.texto) { modelo.copiar(r.comando) }
                }
            }
            .padding(6)
            .frame(minWidth: 240, alignment: .leading)
        }
    }

    private func item(_ texto: String, cor: Color, acao: @escaping () -> Void) -> some View {
        Button {
            aberto = false
            acao()
        } label: {
            Text(texto).font(PV.fonte(12.5)).foregroundStyle(cor)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(ItemMenuEstilo())
    }
}

/// Rosca dos testes de hoje: verde = passou, vermelho = falhou. Sem teste, só o trilho.
struct Rosca: View {
    var passou: Int
    var falhou: Int

    var body: some View {
        let total = Double(passou + falhou)
        let fPassou = total > 0 ? Double(passou) / total : 0
        ZStack {
            Circle().fill(Color(hex: 0x071321))
            Circle().stroke(Color(hex: 0x17253B), lineWidth: 15).padding(7.5)
            if total > 0 {
                Circle().trim(from: 0, to: fPassou)
                    .stroke(Color(hex: 0x19E58C), style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90)).padding(7.5)
                Circle().trim(from: fPassou, to: 1)
                    .stroke(Color(hex: 0xF64561), style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90)).padding(7.5)
            }
            VStack(spacing: 2) {
                Text("\(passou + falhou)").font(PV.fonte(26, .semibold))
                Text("testes hoje").font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
            }
        }
    }
}

/// Barras de gasto com eixo em moeda (0 e três marcas).
struct GraficoGasto: View {
    var barras: [GastoDiaPainel]
    var moeda: MoedaPainel
    var titulo: String

    var body: some View {
        let valores = barras.map { converter($0.total) }
        let passo = GraficoGasto.passo(valores.max() ?? 0)
        let topo = passo * 3
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(PV.fonte(12.5, .medium))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([3, 2, 1, 0], id: \.self) { i in
                        Text("\(moeda.rotulo) \(Int(passo * Double(i)))").font(PV.fonte(11)).foregroundStyle(PV.texto2)
                        if i > 0 { Spacer(minLength: 0) }
                    }
                }
                .padding(.bottom, 18)
                .frame(width: 50, alignment: .leading)
                VStack(spacing: 4) {
                    GeometryReader { g in
                        ZStack(alignment: .bottom) {
                            VStack(spacing: 0) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Rectangle().fill(PV.grade).frame(height: 1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.top, 7)
                            HStack(alignment: .bottom, spacing: 0) {
                                ForEach(Array(barras.enumerated()), id: \.offset) { i, b in
                                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                        .fill(cor(i, b))
                                        .frame(width: min(34, g.size.width / CGFloat(max(barras.count, 1)) * 0.7),
                                               height: topo > 0 ? max(2, (g.size.height - 7) * valores[i] / topo) : 2)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .overlay(alignment: .bottom) { Rectangle().fill(PV.eixo).frame(height: 1) }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(barras.enumerated()), id: \.offset) { _, b in
                            Text(b.rotulo).font(PV.fonte(11)).foregroundStyle(PV.texto2).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func converter(_ usd: Double) -> Double {
        if case .brl(let taxa) = moeda { return usd * taxa }
        return usd
    }

    private func cor(_ i: Int, _ b: GastoDiaPainel) -> LinearGradient {
        if b.ehHoje {
            return LinearGradient(colors: [Color(hex: 0x2CEBF7), Color(hex: 0x20B5E6)], startPoint: .top, endPoint: .bottom)
        }
        if i >= barras.count - 4 {
            return LinearGradient(colors: [Color(hex: 0x4C90FA), Color(hex: 0x3570E0)], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(hex: 0x3570E0)], startPoint: .top, endPoint: .bottom)
    }

    /// Passo «redondo» para três marcas acima de zero (20 → 0/20/40/60).
    static func passo(_ maximo: Double) -> Double {
        let bruto = max(maximo / 3, 1)
        let base = pow(10, floor(log10(bruto)))
        for m in [1.0, 2.0, 2.5, 5.0, 10.0] where base * m >= bruto { return base * m }
        return base * 10
    }
}

/// Item do menu ⋮: fundo no hover e no clique.
struct ItemMenuEstilo: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Corpo(configuration: configuration) }
    private struct Corpo: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.1 : (hover ? 0.05 : 0))))
                .onHover { hover = $0 }
        }
    }
}
