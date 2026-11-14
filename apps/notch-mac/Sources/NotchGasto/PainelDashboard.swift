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
    @Environment(\.fatorTexto) private var fator

    private var snap: SnapshotPainel? { modelo.snapshot }
    private var ind: IndicadoresPainel { snap?.indicadores ?? .vazio }
    private var moeda: MoedaPainel { snap?.custos.moeda ?? .usd }
    private var alertas: [String] { snap?.alertasPainel ?? [] }

    var body: some View {
        conteudo(largura: largura)
            .frame(width: largura, alignment: .topLeading)
    }

    /// As seções têm altura fixa em 1×; o ⌘+ escala o texto, então a altura cresce junto
    /// (senão o texto grande é cortado pelo `clipped` dos cartões).
    private var escala: CGFloat { max(fator, 1) }

    private func conteudo(largura: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(spacing: 0) {
                kpis(largura).frame(height: 82 * escala).padding(.top, 14)
                if alertasFechados == nil || alertasFechados != alertas {
                    faixaAlertas.frame(height: 42 * escala).padding(.top, 12)
                }
                meio(largura, agora: ctx.date).frame(height: 430 * escala).padding(.top, 12)
                custos(largura, agora: ctx.date).frame(height: 228 * escala).padding(.top, 12)
            }
        }
    }

    // MARK: Cartões do topo

    private func kpis(_ largura: CGFloat) -> some View {
        let k = (largura - 48) / 1300
        return HStack(spacing: 16) {
            kpi(icone: IconeCartao(simbolo: "square.3.layers.3d", cor: PV.teal, fundo: PV.tealFundo, tamanho: 46, tamanhoIcone: 21),
                rotulo: "Lanes ativas", valor: "\(ind.lanesAtivas) / \(ind.lanesTotal)", espaco: 16,
                larguraMinimaDelta: 195, larguraMinimaAbaixo: 316, larguraMinimaDireita: 295) {
                // Mock: sem histórico do nº de lanes ativas, a variação não tem número.
                Text("—").fontePainel(13, .semibold).foregroundStyle(PV.verde).help("Variação: em breve")
            } abaixo: {
                BarraPV(fracao: ind.lanesTotal > 0 ? Double(ind.lanesAtivas) / Double(ind.lanesTotal) : 0,
                        cor: PV.teal, altura: 4, trilho: PV.trilho)
                    .frame(width: 143).padding(.leading, 63)
            } direita: { EmptyView() }
            .frame(width: 316 * k)
            .clipped()

            kpi(icone: IconeCartao(simbolo: "bolt", cor: PV.azulIcone, fundo: PV.azulFundo, tamanho: 46, tamanhoIcone: 21),
                rotulo: "Builds hoje", valor: "\(ind.buildsHoje)", espaco: 12,
                larguraMinimaDelta: 185, larguraMinimaDireita: 265) {
                variacao(ind.buildsHoje - ind.buildsOntem, sobeBom: true)
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: ind.buildsSerie.map(Double.init)) { i, _ in
                    i >= 9 ? PV.azul : (i >= 3 ? PV.azulIcone : Color(hex: 0x2F7BEA))
                }
                .help("Execuções por hora nas últimas 12 h")
                .padding(.top, 12)
            }
            .frame(width: 296 * k)
            .clipped()

            kpi(icone: IconeCartao(simbolo: "xmark.circle", cor: PV.vermelho, fundo: PV.vermelhoFundo, tamanho: 46, tamanhoIcone: 22),
                rotulo: "Falhas (24h)", valor: "\(ind.falhas24h)", espaco: 14,
                larguraMinimaDelta: 195, larguraMinimaDireita: 275) {
                Text(ind.falhasPct.map { Formato.pct($0) } ?? "—").fontePainel(13, .semibold).foregroundStyle(PV.vermelho)
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: ind.falhasSerie.map(Double.init)) { _, v in v > 0 ? PV.vermelho : Color(hex: 0x3A4868) }
                    .padding(.top, 12)
            }
            .frame(width: 336 * k)
            .clipped()

            kpi(icone: IconeCartao(simbolo: "cylinder.split.1x2", cor: PV.dourado, fundo: PV.ambarFundo, tamanho: 46, tamanhoIcone: 21),
                rotulo: "Custo (7 dias)", valor: snap?.custos.semana.map { moeda.texto($0) } ?? "sem dado", espaco: 12,
                larguraMinimaDelta: 235, larguraMinimaDireita: 290) {
                variacaoCusto
            } abaixo: { EmptyView() } direita: {
                Barrinhas(valores: (snap?.custos.dias ?? []).map(\.total), cor: { _, _ in PV.verde }, largura: 5)
                    .padding(.top, 10)
            }
            .frame(width: 352 * k)
            .clipped()
        }
    }

    private func kpi<Delta: View, Abaixo: View, Direita: View>(
        icone: IconeCartao, rotulo: String, valor: String, espaco: CGFloat,
        larguraMinimaDelta: CGFloat = 0,
        larguraMinimaAbaixo: CGFloat = 0,
        larguraMinimaDireita: CGFloat = 0,
        @ViewBuilder delta: @escaping () -> Delta,
        @ViewBuilder abaixo: @escaping () -> Abaixo,
        @ViewBuilder direita: @escaping () -> Direita
    ) -> some View {
        // O espaço que vale é o do cartão, medido abaixo; a janela não entra na conta.
        // Primeiro saem os detalhes (gráfico), depois a variação e a barra de apoio;
        // ícone, rótulo, valor e o que estiver na faixa essencial ficam.
        let pecas = [
            PecaCard(id: "icone", prioridade: .essencial),
            PecaCard(id: "texto", prioridade: .essencial),
            PecaCard(id: "delta", prioridade: .secundaria,
                     minimo: EspacoCard(largura: Double(larguraMinimaDelta), altura: 0)),
            PecaCard(id: "abaixo", prioridade: .secundaria,
                     minimo: EspacoCard(largura: Double(larguraMinimaAbaixo), altura: 0)),
            PecaCard(id: "direita", prioridade: .detalhe,
                     minimo: EspacoCard(largura: Double(larguraMinimaDireita), altura: 0)),
        ]
        return ComEspacoDoCard { espacoDoCard in
            let visiveis = Set(DegradacaoCard.visiveis(pecas, em: espacoDoCard))
            HStack(spacing: 0) {
                if visiveis.contains("icone") { icone.padding(.trailing, 14) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(rotulo.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Aurora.mudo)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: espaco) {
                        Text(valor)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Aurora.texto)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .fixedSize()
                            .contentTransition(.numericText())
                            .animation(DS.anim(DS.mola), value: valor)
                        if visiveis.contains("delta") { delta().fixedSize() }
                    }
                    if visiveis.contains("abaixo") { abaixo() }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if visiveis.contains("direita") { direita() }
            }
            .padding(.leading, 15).padding(.trailing, 18)
            .frame(maxHeight: .infinity)
            .vidroAurora(raio: 16)
        }
    }

    private func variacao(_ d: Int, sobeBom: Bool) -> some View {
        let cor: Color = d == 0 ? PV.mudo : ((d > 0) == sobeBom ? PV.verde : PV.vermelho)
        return Text(d > 0 ? "↑ \(d)" : (d < 0 ? "↓ \(-d)" : "= 0"))
            .fontePainel(13, .semibold).foregroundStyle(cor)
            .help("Comparado com ontem")
    }

    /// Subiu: ↑ vermelho. Caiu: ↓ verde. Sem os 7 dias anteriores: «—».
    private var variacaoCusto: some View {
        Group {
            if let v = ind.variacaoSemanaPct {
                if abs(v) < 0.5 {
                    // Sem variação não é «subiu 0%»: o traço neutro diz a mesma coisa sem alarme.
                    Text("= 0%").foregroundStyle(PV.mudo)
                } else {
                    Text(v > 0 ? "↑ \(Formato.pct(abs(v)))" : "↓ \(Formato.pct(abs(v)))")
                        .foregroundStyle(v > 0 ? PV.vermelho : PV.verde)
                }
            } else {
                Text("—").foregroundStyle(PV.mudo)
            }
        }
        .fontePainel(13, .semibold)
        .help("Comparado com os 7 dias anteriores, até o mesmo horário")
    }

    // MARK: Alertas

    private var faixaAlertas: some View {
        let vazio = alertas.isEmpty
        return HStack(spacing: 11) {
            Image(systemName: vazio ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(vazio ? Aurora.verde : Aurora.ambar)
            Text("ALERTAS")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(vazio ? Aurora.mudo : Aurora.vermelho)
                .padding(.trailing, 8)
            if vazio {
                Text("Nenhum alerta agora")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.texto2)
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(alertas.enumerated()), id: \.offset) { i, a in
                        if i > 0 { Circle().fill(Aurora.vermelho.opacity(0.7)).frame(width: 3, height: 3) }
                        Text(a.hasSuffix(".") ? String(a.dropLast()) : a)
                            .font(.system(size: 12.5, design: .rounded))
                            .foregroundStyle(Aurora.texto2)
                            .lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            }
            Spacer(minLength: 8)
            if !vazio {
                Button { verAlertas.toggle() } label: {
                    HStack(spacing: 6) {
                        Text("Ver detalhes")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Aurora.azul)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Aurora.azul.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Aurora.azul.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(Pressionavel())
                .popover(isPresented: $verAlertas, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        RotuloSecao(titulo: "Alertas", icone: "exclamationmark.triangle.fill", cor: Aurora.vermelho)
                        ForEach(Array(alertas.enumerated()), id: \.offset) { _, a in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Aurora.vermelho).frame(width: 5, height: 5).padding(.top, 5)
                                Text(a)
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(Aurora.texto2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14).frame(width: 380, alignment: .leading)
                }
                Button { alertasFechados = alertas } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Aurora.mudo)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                        .contentShape(Circle())
                }
                .buttonStyle(Pressionavel())
                .padding(.leading, 4)
                .help("Esconder até a lista de alertas mudar")
                .accessibilityLabel("Esconder alertas")
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(vazio ? Color.white.opacity(0.035) : Aurora.vermelho.opacity(0.09))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(vazio ? Color.white.opacity(0.07) : Aurora.vermelho.opacity(0.28), lineWidth: 1))
    }

    // MARK: Linha do meio

    private func meio(_ largura: CGFloat, agora: Date) -> some View {
        let m = (largura - 26) / 1322
        return HStack(alignment: .top, spacing: 14) {
            cartaoLanes(agora: agora).frame(width: 474 * m).clipped()
            VStack(spacing: 12) {
                cartaoBuilds(agora: agora).frame(height: 164 * escala)
                cartaoTestes.frame(height: 254 * escala)
            }
            .frame(width: 409 * m)
            .clipped()
            VStack(spacing: 12) {
                cartaoDispatcher.frame(height: 224 * escala)
                cartaoEntregas(agora: agora).frame(height: 194 * escala)
            }
            .frame(width: 439 * m)
            .clipped()
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
                    Text("Sem leitura das lanes").fontePainel(12.5).foregroundStyle(PV.mudo).padding(.horizontal, 4)
                } else {
                    // 6 linhas de 51 pt cabem no cartão. Com mais lanes (a lane extra da conta),
                    // a linha encolhe até 40 pt em vez de esconder a primeira atrás da rolagem.
                    GeometryReader { g in
                        let n = CGFloat(linhas.count)
                        let altura = max(40, min(51, (g.size.height - 6 * (n - 1)) / n))
                        ScrollView(.vertical, showsIndicators: altura <= 40) {
                            VStack(spacing: 6) {
                                ForEach(linhas, id: \.lane) { linha in
                                    LinhaLaneDashboard(linha: linha, modelo: modelo, agora: agora,
                                                       aberta: expandida == linha.lane, altura: altura) {
                                        expandida = expandida == linha.lane ? nil : linha.lane
                                    }
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
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        RotuloSecao(titulo: "Lock de build")
                        HStack(spacing: 11) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill((livre ? Aurora.verde : Aurora.ambar).opacity(0.14))
                                .frame(width: 34, height: 34)
                                .overlay(Image(systemName: livre ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(livre ? Aurora.verde : Aurora.ambar))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder((livre ? Aurora.verde : Aurora.ambar).opacity(0.24), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(livre ? "Livre" : "Ocupado")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(livre ? Aurora.verde : Aurora.ambar)
                                Text(livre ? "sem lock" : textoLock)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Aurora.mudo)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 172, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .linhaPV(borda: false)
                    VStack(alignment: .leading, spacing: 8) {
                        RotuloSecao(titulo: "Fila (\(fila.count))")
                        if fila.isEmpty {
                            Text("fila vazia")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Aurora.mudo)
                        }
                        ForEach(Array(fila.prefix(2).enumerated()), id: \.offset) { _, carta in
                            HStack(spacing: 9) {
                                // Mock: item da fila ainda não é execução, então não tem `#N`.
                                Text("#—")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Aurora.apagado)
                                    .help("O número sai quando a build começa")
                                Text(carta.lane.isEmpty ? carta.card : carta.lane)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                EtiquetaAurora(texto: "aguardando", cor: Aurora.ambar)
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
        let total = ind.provasComVeredito
        return CartaoPV {
            VStack(alignment: .leading, spacing: 0) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "flask", tamanhoIcone: 18),
                                titulo: "Testes", subtitulo: "Provas de hoje (local e GitHub)") {
                    BotaoVer(texto: "Ver todos") { ir(.testes) }
                }
                HStack(spacing: 22) {
                    Rosca(passou: ind.provasOk, falhou: ind.provasFalha)
                        .frame(width: 142 * escala, height: 142 * escala)
                    VStack(alignment: .leading, spacing: 20) {
                        legenda(cor: Aurora.verde, texto: Formato.plural(ind.provasOk, "prova ok", "provas ok"),
                                pct: pct(ind.provasOk, total))
                        legenda(cor: Aurora.vermelho, texto: Formato.plural(ind.provasFalha, "prova falhou", "provas falharam"),
                                pct: pct(ind.provasFalha, total))
                        // Mock: o parser da prova ainda não lê testes pulados.
                        legenda(cor: Aurora.azul, texto: "— ignoradas", pct: "—")
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
                        .underline().fontePainel(12.5).foregroundStyle(PV.mudo)
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
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(cor)
                .frame(width: 9, height: 9)
                .shadow(color: cor.opacity(0.6), radius: 3)
            Text(texto)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Aurora.texto2)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(pct)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Aurora.texto)
        }
    }

    private var cartaoDispatcher: some View {
        let vivo = snap?.dispatcherVivo == true
        let pausa = snap?.pausa == true
        let (rotulo, cor): (String, Color) = pausa ? ("Pausado", PV.ambar) : (vivo ? ("Operacional", PV.verde) : ("Parado", PV.vermelho))
        return CartaoPV {
            VStack(alignment: .leading, spacing: 0) {
                CabecalhoCartao(icone: IconeCartao(simbolo: "gearshape", tamanhoIcone: 18),
                                titulo: "Dispatcher", subtitulo: "Estado do sistema") {
                    PilulaAurora(titulo: rotulo, cor: cor, compacta: true)
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
                    Text("Baixo: < \(Int(LanesPainel.folgaBaixo))% (\(Int(LanesPainel.folgaLongaBaixo))%)")
                    Spacer(minLength: 8)
                    Text("Médio: < \(Int(LanesPainel.folgaMedio))% (\(Int(LanesPainel.folgaLongaMedio))%)")
                    Spacer(minLength: 8)
                    Text("Alto: < \(Int(LanesPainel.folgaAlto))% (\(Int(LanesPainel.folgaLongaAlto))%)")
                    Spacer(minLength: 0)
                }
                .fontePainel(11.5).foregroundStyle(PV.mudo)
                .help("Uso máximo da conta para assumir card de cada esforço. Entre parênteses: conta medida em janela de 1 dia ou mais.")
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
        HStack(spacing: 10) {
            Circle().fill(cor)
                .frame(width: 6, height: 6)
                .shadow(color: cor.opacity(0.7), radius: 3)
            Text(nome)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Aurora.mudo)
            Spacer(minLength: 8)
            Text(valor)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Aurora.texto2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 12))
                            .foregroundStyle(Aurora.apagado)
                        Text("Nenhum card fechado neste registro")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Aurora.mudo)
                    }
                    .padding(.top, 14).padding(.leading, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entregas.prefix(5).enumerated()), id: \.offset) { _, e in
                            HStack(spacing: 0) {
                                Circle().fill(Aurora.verde)
                                    .frame(width: 6, height: 6)
                                    .shadow(color: Aurora.verde.opacity(0.7), radius: 3)
                                    .padding(.trailing, 16)
                                Text(e.card)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Aurora.texto)
                                    .frame(width: 78, alignment: .leading)
                                Text("\(e.lane) • \(e.pr ?? e.quando)")
                                    .font(.system(size: 11.5, design: .rounded))
                                    .foregroundStyle(Aurora.mudo)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(haPainel(e.quandoData, agora: agora) ?? "")
                                    .font(.system(size: 11.5, design: .rounded))
                                    .foregroundStyle(Aurora.apagado)
                            }
                            .frame(height: 25.5)
                        }
                    }
                    .background(alignment: .leading) {
                        Capsule().fill(Aurora.verde.opacity(0.35))
                            .frame(width: 2).padding(.vertical, 10).padding(.leading, 2)
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
                    painelGastoLane(p).frame(width: 424 * c).clipped()
                    GraficoGasto(barras: p?.barras ?? [], moeda: moeda, titulo: tituloGrafico)
                        .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 16)
                        .frame(width: 413 * c)
                        .clipped()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PV.interno))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
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
        // Com mais de 5 lanes o painel começava a cortar a última linha (`deepseek`).
        let apertado = lanes.count > 5
        return VStack(alignment: .leading, spacing: apertado ? 3 : 8) {
            RotuloSecao(titulo: "Gasto por lane (\(periodo.complemento))")
            ForEach(Array(lanes.enumerated()), id: \.offset) { i, l in
                HStack(spacing: 0) {
                    Text(l.lane)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Aurora.texto2)
                        .lineLimit(1)
                        .frame(width: 87, alignment: .leading)
                    BarraPV(fracao: maximo > 0 ? (l.custoUSD ?? 0) / maximo : 0, cor: PV.barrasLane[i % PV.barrasLane.count])
                    Text(l.custoUSD.map { moeda.texto($0) } ?? (l.desconhecidas > 0 ? "—" : "sem gasto"))
                        .font(.system(size: 11.5, weight: l.custoUSD == nil ? .regular : .semibold, design: .rounded))
                        .foregroundStyle(l.custoUSD == nil ? Aurora.mudo : Aurora.texto)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 66, alignment: .leading)
                        .padding(.leading, 14)
                }
                .frame(height: apertado ? 14 : 15)
            }
        }
        .padding(.top, 12).padding(.leading, 13).padding(.trailing, 12).padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PV.interno))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func painelTop(_ top: [CardCaro], agora: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RotuloSecao(titulo: "Builds mais caros (top 5)")
                Spacer()
                BotaoVer(texto: "Ver todos", pequeno: true) { ir(.custos) }
            }
            .padding(.bottom, 4)
            if top.isEmpty {
                Text("Sem gasto conhecido neste período")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
                    .padding(.top, 6)
            }
            ForEach(Array(top.prefix(5).enumerated()), id: \.offset) { i, card in
                HStack(spacing: 0) {
                    Circle()
                        .fill(i == 0 ? Aurora.ambar : Color.white.opacity(0.07))
                        .frame(width: 17, height: 17)
                        .overlay(Text("\(i + 1)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(i == 0 ? Aurora.tinta : Aurora.texto2))
                    Button { modelo.abrirCard(card.card) } label: {
                        Text(card.card)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Aurora.azul)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 76, alignment: .leading).padding(.leading, 12)
                    Text("\(card.lane) • \(Formato.plural(card.tentativas, "tentativa", "tentativas"))")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(card.custoUSD.map { moeda.texto($0) } ?? "sem custo")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(card.custoUSD == nil ? Aurora.mudo : Aurora.vermelho)
                        .frame(width: 84, alignment: .leading)
                    Text(haPainel(card.ultimoInicio, agora: agora) ?? "")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Aurora.apagado)
                        .frame(width: 62, alignment: .trailing)
                }
                .frame(height: 24.2)
            }
        }
        .padding(.top, 8).padding(.horizontal, 12).padding(.bottom, 4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PV.interno))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Uma lane no cartão do Dashboard. › expande o detalhe; ⋮ abre as ações que já existem.
struct LinhaLaneDashboard: View {
    var linha: LinhaLane
    @ObservedObject var modelo: ModeloNotch
    var agora: Date
    var aberta: Bool
    /// Altura da linha fechada. O cartão do Dashboard encolhe quando há mais de 6 lanes.
    var altura: CGFloat = 51
    var alternar: () -> Void
    /// Barra de uso da conta na própria linha (só na página Lanes, que tem espaço).
    var mostrarUso = false
    @State private var hover = false

    var body: some View {
        let estado = EstadoPilula(linha.estado)
        // A linha também degrada pelo espaço dela: a altura chega do cartão e diz
        // o que cabe. Primeiro saem a segunda linha e a build; lane e estado ficam.
        let pecas = [
            PecaCard(id: "principal", prioridade: .essencial),
            PecaCard(id: "secundaria", prioridade: .secundaria,
                     minimo: EspacoCard(largura: 0, altura: 46)),
            PecaCard(id: "build", prioridade: .secundaria,
                     minimo: EspacoCard(largura: 0, altura: 46)),
            PecaCard(id: "uso", prioridade: .detalhe,
                     minimo: EspacoCard(largura: 0, altura: 50)),
        ]
        let visiveis = Set(DegradacaoCard.visiveis(pecas, altura: Double(altura)))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: alternar) {
                    HStack(spacing: 0) {
                        Image(systemName: aberta ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(PV.icone).frame(width: 14)
                        PontoLane(cor: estado.corLane, piscando: linha.estado == .rodando)
                            .padding(.leading, 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(linha.lane).fontePainel(13.5, .semibold).lineLimit(1)
                            if visiveis.contains("secundaria") {
                                Text(secundaria(linha)).fontePainel(11.5).foregroundStyle(PV.mudo).lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(secundaria(linha))
                            }
                        }
                        .frame(width: 104, alignment: .leading)
                        .padding(.leading, 9)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(aberta ? "Recolher \(linha.lane)" : "Expandir \(linha.lane)")
                PilulaEstado(estado: estado).fixedSize().frame(width: 97, alignment: .leading)
                if visiveis.contains("build") {
                    VStack(alignment: .leading, spacing: 1) {
                        if linha.estado == .rodando || linha.estado == .livre {
                            Text(verbatim: linha.ultimaBuild.map { "build #" + String($0) } ?? "—").fontePainel(12.5)
                            Text(haPainel(linha.ultimaBuildInicio, agora: agora) ?? "sem build").fontePainel(11.5).foregroundStyle(PV.mudo)
                        } else {
                            // Pausada/desligada não está executando build: mostrar a última só confunde.
                            Text("—").fontePainel(12.5).foregroundStyle(PV.apagado)
                        }
                    }
                    .padding(.leading, 10)
                }
                Spacer(minLength: 4)
                if mostrarUso, linha.pct != nil, visiveis.contains("uso") {
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
            .frame(height: altura)
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
        if linha.urlProvaRemota != nil { return "aguardando prova remota" }
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
                Text(texto).fontePainel(12, .semibold).lineLimit(1)
            }
            if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                Text(aviso).fontePainel(11.5, .semibold)
                    .foregroundStyle(Aurora.rosa)
                    .lineLimit(2)
            }
            Text(linha.estado == .desligada ? "desligada" : linha.descricao).fontePainel(12).lineLimit(2)
            if !linha.detalhe.isEmpty {
                Text(linha.detalhe).fontePainel(11.5).foregroundStyle(PV.mudo).lineLimit(1)
            }
            if let endereco = linha.urlProvaRemota, let url = URL(string: endereco) {
                Link(destination: url) {
                    Text(endereco).fontePainel(11.5).lineLimit(1).truncationMode(.middle)
                }
            }
            if let endereco = linha.urlCheckRemoto, endereco != linha.urlProvaRemota,
               let url = URL(string: endereco) {
                Link(destination: url) {
                    Text(endereco).fontePainel(11.5).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 10) {
                BarraUso(pct: linha.pct, altura: 6).frame(width: 130)
                if let j = linha.janela { Text(j).fontePainel(11.5).foregroundStyle(PV.mudo) }
                if let plano = linha.plano {
                    Text(plano.rotulo).fontePainel(10.5, .semibold)
                        .foregroundStyle(plano == .pago ? Color(hex: 0xB9A6FF) : PV.verde)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder((plano == .pago ? Color(hex: 0x8B6CFF) : PV.verde).opacity(0.7), lineWidth: 1))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1))
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(aberto ? Color.white.opacity(0.10) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ações da lane \(linha.lane)")
        .popover(isPresented: $aberto, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                if linha.estado == .desligada {
                    item("Ativar lane", cor: PV.texto) { modelo.ativarLane(linha.lane) }
                } else {
                    item("Desativar lane", cor: Aurora.rosa) { modelo.desativarLane(linha.lane) }
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
            Text(texto).fontePainel(12.5).foregroundStyle(cor)
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
            Circle().stroke(Color.white.opacity(0.06), lineWidth: 13)
            if total > 0 {
                // Arco de comprimento zero com ponta arredondada vira um ponto colorido no topo
                // (verde com 0 aprovadas, vermelho com 0 falhas). Só desenha o que tem valor.
                if passou > 0 {
                    Circle().trim(from: 0, to: fPassou)
                        .stroke(Aurora.verde, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(7)
                        .shadow(color: Aurora.verde.opacity(0.35), radius: 6)
                }
                if falhou > 0 {
                    Circle().trim(from: fPassou, to: 1)
                        .stroke(Aurora.vermelho, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(7)
                        .shadow(color: Aurora.vermelho.opacity(0.30), radius: 6)
                }
            }
            VStack(spacing: 1) {
                Text("\(passou + falhou)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Aurora.texto)
                Text(passou + falhou == 1 ? "PROVA HOJE" : "PROVAS HOJE")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Aurora.mudo)
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
            RotuloSecao(titulo: titulo)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([3, 2, 1, 0], id: \.self) { i in
                        Text("\(moeda.rotulo) \(GraficoGasto.marca(passo * Double(i)))")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Aurora.apagado)
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
                            Text(b.rotulo)
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Aurora.apagado)
                                .frame(maxWidth: .infinity)
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
            return LinearGradient(colors: [Aurora.acento, Aurora.ciano], startPoint: .top, endPoint: .bottom)
        }
        if i >= barras.count - 4 {
            return LinearGradient(colors: [Aurora.azul, Aurora.azulForte], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Aurora.azulForte.opacity(0.7)], startPoint: .top, endPoint: .bottom)
    }

    /// Valor da marca do eixo: inteiro sem casa; passo 2,5 mostra «2,5» e «7,5» (antes truncava para 2 e 7).
    static func marca(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
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


/// Ícone da lane na lista do dashboard. Lane rodando pisca (além da barra de progresso);
/// com «reduzir movimento» ligado no macOS, fica acesa e parada.
private struct PontoLane: View {
    var cor: Color
    var piscando: Bool
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento
    @State private var apagado = false

    var body: some View {
        Circle().fill(cor)
            .frame(width: 9, height: 9)
            .shadow(color: piscando ? cor.opacity(apagado ? 0 : 0.9) : .clear, radius: 4)
            .opacity(piscando && apagado ? 0.25 : 1)
            .onAppear { ajustar() }
            .onChange(of: piscando) { _, _ in ajustar() }
            .onChange(of: reduzirMovimento) { _, _ in ajustar() }
            .accessibilityLabel(piscando ? "rodando" : "")
    }

    private func ajustar() {
        if piscando && !reduzirMovimento {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { apagado = true }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { apagado = false }
        }
    }
}
