import SwiftUI
import GastoCore

/// Painel completo v2: barra lateral, cabeçalho e seis páginas.
/// Só leitura, como o v1. As ações são as que já existiam (desativar/ativar lane, copiar retomar,
/// abrir card, abrir terminais, abrir ajustes).
struct PainelTela: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var nav = NavegacaoPainel.compartilhada
    private var pagina: PaginaPainel { nav.pagina }

    init(modelo: ModeloNotch, pagina: PaginaPainel? = nil) {
        self.modelo = modelo
        if let pagina { NavegacaoPainel.compartilhada.pagina = pagina }
    }

    var body: some View {
        HStack(spacing: 0) {
            BarraLateralPainel(pagina: $nav.pagina, secao: $nav.secao)
            VStack(spacing: 0) {
                CabecalhoPainel(pagina: pagina, modelo: modelo)
                GeometryReader { g in
                    ScrollView(.vertical) {
                        conteudo(largura: max(g.size.width - 44, 900))
                            .padding(.horizontal, 22)
                            .padding(.bottom, pagina == .dashboard ? 0 : 22)
                            .id(pagina == .ajustes ? "ajustes-\(nav.secao.rawValue)" : pagina.rawValue)
                            .transition(DS.reduzir ? .identity : .opacity.combined(with: .offset(y: 8)))
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .animation(DS.anim(DS.mola), value: pagina)
        .animation(DS.anim(DS.mola), value: nav.secao)
        .overlay { CamadaAvisos() }
        .background(PV.fundo)
        .foregroundStyle(PV.texto)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 1280, minHeight: 800)
    }

    @ViewBuilder
    private func conteudo(largura: CGFloat) -> some View {
        switch pagina {
        case .dashboard: DashboardPainel(modelo: modelo, largura: largura, ir: { nav.pagina = $0 })
        case .lanes: PaginaLanes(modelo: modelo)
        case .builds: PaginaBuilds(modelo: modelo)
        case .entregas: PaginaEntregas(modelo: modelo)
        case .testes: PaginaTestes(modelo: modelo)
        case .custos: PaginaCustos(modelo: modelo)
        case .esperando: PaginaEsperando()
        case .ajustes:
            if let s = CatalogoAjustes.secoes().first(where: { $0.id == nav.secao }) { PaginaAjustes(secao: s) }
        }
    }
}

/// Barra lateral: marca, seis páginas e Configurações (abre os Ajustes que já existem).
struct BarraLateralPainel: View {
    @Binding var pagina: PaginaPainel
    @Binding var secao: IdSecaoAjustes
    @Namespace private var selecao
    private let secoes = CatalogoAjustes.secoes().map { ($0.id, $0.nome, $0.simbolo) }

    private func ir(_ p: PaginaPainel) { comAnimacao { pagina = p } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 15) {
                MarcaTuttiDash().frame(width: 28, height: 28)
                (Text(verbatim: "TUTTI").foregroundColor(.white) + Text(verbatim: "DASH").foregroundColor(PV.azul))
                    .font(PV.fonte(18.5, .bold))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            SeloVersao().padding(.horizontal, 14).padding(.top, 6)
            VStack(spacing: 1) {
                ForEach(PaginaPainel.principais) { p in
                    ItemNavegacao(simbolo: p.simbolo, texto: p.titulo, selecionado: pagina == p, ns: selecao) { ir(p) }
                }
            }
            .padding(.top, 24)
            Rectangle().fill(PV.divisor).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 14)
            ItemNavegacao(simbolo: "gearshape", texto: "Ajustes", selecionado: pagina == .ajustes, ns: selecao) { ir(.ajustes) }
            if pagina == .ajustes {
                VStack(spacing: 1) {
                    ForEach(secoes, id: \.0) { id, nome, simbolo in
                        ItemSubsecao(simbolo: simbolo, texto: nome, selecionado: secao == id, ns: selecao) {
                            comAnimacao { secao = id }
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.horizontal, 8)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PV.lateral)
        .overlay(alignment: .trailing) { Rectangle().fill(PV.lateralBorda).frame(width: 1) }
    }
}

/// Sub-seção dos Ajustes na barra lateral, com o fundo de seleção que desliza.
struct ItemSubsecao: View {
    var simbolo: String
    var texto: String
    var selecionado: Bool
    var ns: Namespace.ID
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 9) {
                Image(systemName: simbolo).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(selecionado ? PV.azul : PV.mudo)
                Text(texto).font(PV.fonte(13, selecionado ? .semibold : .regular))
                    .foregroundStyle(selecionado ? Color.white : PV.icone)
                Spacer(minLength: 0)
            }
            .padding(.leading, 30).padding(.trailing, 6)
            .frame(height: 30)
            .background {
                if selecionado {
                    RoundedRectangle(cornerRadius: DS.raioP).fill(PV.navSelecao.opacity(0.8))
                        .matchedGeometryEffect(id: "subsecao", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: DS.raioP).fill(Color.white.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Logotipo: «N» ciano inclinado sobre um quadrado azul arredondado (a imagem de referência).
/// Desenhado em 24×20 unidades. Os vãos escuros separam o N dos cantos azuis.
/// Ícone novo do app (AppIcon.icns do bundle), o mesmo do Dock.
struct MarcaTuttiDash: View {
    var body: some View {
        Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct ItemNavegacao: View {
    var simbolo: String
    var texto: String
    var selecionado: Bool
    var ns: Namespace.ID? = nil
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 13) {
                Image(systemName: simbolo)
                    .font(.system(size: 16, weight: selecionado ? .semibold : .regular))
                    .foregroundStyle(selecionado ? PV.azul : PV.icone)
                    .frame(width: 20)
                Text(texto)
                    .font(PV.fonte(14.5, selecionado ? .semibold : .regular))
                    .foregroundStyle(selecionado ? Color.white : PV.icone)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background {
                if selecionado {
                    let fundo = RoundedRectangle(cornerRadius: 8).fill(PV.navSelecao)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PV.navSelecaoBorda, lineWidth: 1))
                        .overlay(alignment: .leading) {
                            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                                .fill(PV.azulForte).frame(width: 3)
                        }
                    if let ns { fundo.matchedGeometryEffect(id: "pagina", in: ns) } else { fundo }
                } else if hover {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Cabeçalho: título da página, busca (ainda sem função), notificações (ainda sem central) e conta.
struct CabecalhoPainel: View {
    var pagina: PaginaPainel
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pagina.titulo).font(PV.fonte(22, .semibold))
                Text(pagina.subtitulo).font(PV.fonte(13)).foregroundStyle(PV.mudo)
            }
            .padding(.leading, 5).padding(.top, 2)
            Spacer(minLength: 16)
            if pagina != .dashboard {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(PV.icone)
                    TextField("Buscar lanes, builds, entregas...", text: $busca.texto)
                        .textFieldStyle(.plain).font(PV.fonte(13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !busca.texto.isEmpty {
                        Button { busca.texto = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PV.apagado) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12).padding(.trailing, 10)
                .frame(width: 300, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(PV.campo))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PV.campoBorda, lineWidth: 1))
                .help("Filtra a página atual por texto (id, título ou lane)")
            }
            // FRA-531: quando os dados foram lidos, e «Atualizar agora» com indicador e aviso.
            HStack(spacing: 8) {
                SeloAtualizado(data: modelo.atualizadoEm, carregando: modelo.atualizando || modelo.medindoUso)
                Button { modelo.atualizarAgora() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(modelo.atualizando && !DS.reduzir ? 360 : 0))
                        .animation(modelo.atualizando && !DS.reduzir ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                   value: modelo.atualizando)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(PV.botao))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PV.botaoBorda, lineWidth: 1))
                }
                .buttonStyle(Pressionavel())
                .disabled(modelo.atualizando)
                .help("Atualizar agora")
            }
            .padding(.leading, 4)
            // Caixa do dono (PRD de 29/10): o sino mostra as respostas em aberto e abre «Esperando você».
            // Sem resposta em aberto, o ponto vermelho dos outros alertas do painel fica como antes.
            Button { comAnimacao { NavegacaoPainel.compartilhada.pagina = .esperando } } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell").font(.system(size: 19)).foregroundStyle(PV.icone)
                    if abertas > 0 {
                        Text("\(abertas)").font(PV.fonte(10.5, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(PV.vermelhoPonto))
                            .overlay(Capsule().strokeBorder(PV.fundo, lineWidth: 1.5))
                            .offset(x: 9, y: -7)
                    } else if !(modelo.snapshot?.alertasPainel.isEmpty ?? true) {
                        Circle().fill(PV.vermelhoPonto).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(PV.fundo, lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressionavel())
            .padding(.leading, 5)
            .padding(.trailing, 5)
            .help(abertas > 0 ? String(localized: "\(abertas) resposta(s) em aberto: abrir Esperando você")
                                     : String(localized: "Nada esperando por você"))
            .onAppear { caixa.iniciar() }
        }
        .padding(.horizontal, 22)
        .frame(height: 60)
    }

    @ObservedObject private var caixa = EstadoCaixa.compartilhada
    /// Sem o arquivo da caixa (vigia parado), vale o contador antigo do log do dispatcher.
    private var abertas: Int { caixa.arquivoExiste ? caixa.abertas : (modelo.snapshot?.esperandoVoce ?? 0) }
}
