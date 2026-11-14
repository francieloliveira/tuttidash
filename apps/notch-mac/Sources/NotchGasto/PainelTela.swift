import SwiftUI
import GastoCore

/// Painel completo v2: barra lateral, cabeçalho e seis páginas.
/// Só leitura, como o v1. As ações são as que já existiam (desativar/ativar lane, copiar retomar,
/// abrir card, abrir terminais, abrir ajustes).
struct PainelTela: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var nav = NavegacaoPainel.compartilhada
    private var pagina: PaginaPainel { nav.pagina }

    @State private var transicao: TransicaoPainel?
    @State private var area = AreaPainel()

    init(modelo: ModeloNotch, pagina: PaginaPainel? = nil) {
        self.modelo = modelo
        if let pagina { NavegacaoPainel.compartilhada.pagina = pagina }
    }

    var body: some View {
        ComEscalaTexto {
            painel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1280, minHeight: 800)
    }

    private var painel: some View {
        HStack(spacing: 0) {
            BarraLateralPainel(modelo: modelo,
                               pagina: Binding(get: { nav.pagina }, set: { trocar(para: $0) }),
                               secao: $nav.secao)
            VStack(spacing: 0) {
                CabecalhoPainel(pagina: pagina, modelo: modelo, ir: trocar, foto: false)
                GeometryReader { g in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            // A largura é a da coluna. Sem isso o título longo empurra as
                            // colunas seguintes para fora e a página ganha rolagem horizontal.
                            ConteudoPagina(modelo: modelo, pagina: pagina,
                                           largura: max(g.size.width - 44, 1), ir: trocar)
                                .frame(width: max(g.size.width - 44, 1), alignment: .topLeading)
                                .padding(.horizontal, 22)
                                .padding(.bottom, pagina == .dashboard ? 0 : 22)
                                .id(pagina == .ajustes ? "ajustes-\(nav.secao.rawValue)" : pagina.rawValue)
                        }
                        .scrollIndicators(.automatic)
                        .onChange(of: nav.grupoFoco) { _, grupo in
                            guard let grupo else { return }
                            Task { @MainActor in
                                proxy.scrollTo(grupo, anchor: .top)
                                nav.grupoFoco = nil
                            }
                        }
                    }
                }
            }
            .background {
                AreaCaptura(area: area)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .overlay {
                if let t = transicao {
                    TransicaoParticulas(origem: t.origem, destino: t.destino, tamanho: t.tamanho, duracao: 0.40) {
                        if transicao?.id == t.id { transicao = nil }
                    }
                    .id(t.id)
                }
            }
        }
        .animation(DS.anim(DS.mola), value: nav.secao)
        .overlay { CamadaAvisos() }
        .background { FundoAurora() }
        .foregroundStyle(PV.texto)
        .environment(\.colorScheme, .dark)
        // A busca do cabeçalho vale para a página em que foi escrita. Sem isto, um termo
        // deixado em Entregas escondia as lanes e a tela dizia «sem leitura».
        .onChange(of: nav.pagina) { _, _ in
            if !BuscaPainel.compartilhada.texto.isEmpty { BuscaPainel.compartilhada.texto = "" }
        }
    }

    /// Origem = foto ao vivo; destino = render offscreen da página nova.
    /// Não fotografar o destino com `cacheDisplay` depois de cobrir a tela: a capa entra no
    /// bitmap e a transição vira origem→origem.
    private func trocar(para destino: PaginaPainel) {
        guard destino != nav.pagina else { return }
        // Clique no meio da transição: troca direto. Antes o clique era engolido e a
        // barra lateral parecia travada por meio segundo.
        guard transicao == nil,
              CatalogoAjustes.transicaoTelasLigada(), !DS.reduzir, area.tamanho.width > 10,
              let origem = AreaPainel.foto(de: area),
              let nova = FotoPainel.imagem(pagina: destino, modelo: modelo, tamanho: area.tamanho)
        else {
            nav.pagina = destino
            return
        }
        transicao = TransicaoPainel(origem: origem, destino: nova, tamanho: area.tamanho)
        nav.pagina = destino
    }
}

/// Conteúdo de cada página, num só lugar: o painel ao vivo e a foto usada na transição.
struct ConteudoPagina: View {
    var modelo: ModeloNotch
    var pagina: PaginaPainel
    var largura: CGFloat
    var ir: (PaginaPainel) -> Void

    var body: some View {
        switch pagina {
        case .dashboard: DashboardPainel(modelo: modelo, largura: largura, ir: ir)
        case .lanes: PaginaLanes(modelo: modelo)
        case .builds: PaginaBuilds(modelo: modelo)
        case .entregas: PaginaEntregas(modelo: modelo)
        case .testes: PaginaTestes(modelo: modelo)
        case .custos: PaginaCustos(modelo: modelo)
        case .esperando: PaginaEsperando()
        case .brainstorm: PaginaBrainstorm(modelo: modelo)
        case .ajustes:
            if let s = CatalogoAjustes.secoes().first(where: { $0.id == NavegacaoPainel.compartilhada.secao }) {
                PaginaAjustes(secao: s)
            }
        }
    }
}

/// A mesma tela, montada fora da janela para virar imagem (destino da transição).
struct FotoPainel: View {
    var pagina: PaginaPainel
    var modelo: ModeloNotch
    var tamanho: CGSize

    var body: some View {
        VStack(spacing: 0) {
            CabecalhoPainel(pagina: pagina, modelo: modelo, ir: { _ in }, foto: true)
            ConteudoPagina(modelo: modelo, pagina: pagina,
                           largura: max(tamanho.width - 44, 1), ir: { _ in })
                .frame(width: max(tamanho.width - 44, 1), alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.bottom, pagina == .dashboard ? 0 : 22)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: tamanho.width, height: tamanho.height, alignment: .top)
        .clipped()
        .background { FundoAurora() }
        .environment(\.colorScheme, .dark)
        .environment(\.fatorTexto, CGFloat(EscalaTextoApp.compartilhada.fator))
    }

    /// Renderiza a página numa imagem (meia resolução basta: as partículas são uma malha grossa).
    @MainActor
    static func imagem(pagina: PaginaPainel, modelo: ModeloNotch, tamanho: CGSize) -> NSImage? {
        guard tamanho.width > 2, tamanho.height > 2 else { return nil }
        let renderizador = ImageRenderer(content: FotoPainel(pagina: pagina, modelo: modelo, tamanho: tamanho))
        renderizador.scale = 0.5
        renderizador.isOpaque = true
        renderizador.proposedSize = ProposedViewSize(width: tamanho.width, height: tamanho.height)
        return renderizador.nsImage
    }
}

/// Barra lateral: marca, páginas e Configurações. Vidro sobre o fundo aurora.
struct BarraLateralPainel: View {
    @ObservedObject var modelo: ModeloNotch
    @Binding var pagina: PaginaPainel
    @Binding var secao: IdSecaoAjustes
    @Namespace private var selecao
    @ObservedObject private var caixa = EstadoCaixa.compartilhada
    private let secoes = CatalogoAjustes.secoes().map { ($0.id, $0.nome, $0.simbolo) }

    private var abertas: Int {
        caixa.arquivoExiste ? caixa.abertas : (modelo.snapshot?.esperandoVoce ?? 0)
    }

    private func ir(_ p: PaginaPainel) { comAnimacao { pagina = p } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                MarcaAurora(tamanho: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "TuttiDash")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(verbatim: "lanes · builds · entregas")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 17)

            RotuloSecao(titulo: "Navegação")
                .padding(.horizontal, 16)
                .padding(.bottom, 7)

            VStack(spacing: 2) {
                ForEach(PaginaPainel.principais) { p in
                    ItemNavegacao(
                        simbolo: p.simbolo,
                        texto: p.titulo,
                        selecionado: pagina == p,
                        badge: p == .esperando ? abertas : 0,
                        ns: selecao
                    ) { ir(p) }
                }
            }
            .padding(.horizontal, 8)

            Rectangle()
                .fill(Aurora.hair)
                .frame(height: 1)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)

            VStack(spacing: 2) {
                ItemNavegacao(simbolo: "gearshape", texto: "Ajustes", selecionado: pagina == .ajustes,
                              destaque: pagina != .ajustes, chevron: true, ns: selecao) { ir(.ajustes) }
                if pagina == .ajustes {
                    VStack(spacing: 1) {
                        ForEach(secoes, id: \.0) { id, nome, simbolo in
                            ItemSubsecao(simbolo: simbolo, texto: nome, selecionado: secao == id, ns: selecao) {
                                comAnimacao { secao = id }
                            }
                        }
                    }
                    .padding(.top, 3)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Aurora.hair).frame(height: 1).padding(.bottom, 2)
                SeloVersao()
                SeloAtualizado(data: modelo.atualizadoEm, carregando: modelo.atualizando || modelo.medindoUso)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
        }
        .padding(.top, 2)
        .frame(width: 226)
        .layoutPriority(1)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .trailing) { Rectangle().fill(Aurora.hair).frame(width: 1) }
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
                Image(systemName: simbolo).font(.system(size: 11.5)).frame(width: 15)
                    .foregroundStyle(selecionado ? Aurora.acento : Aurora.mudo)
                Text(texto)
                    .font(.system(size: 12.5, weight: selecionado ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selecionado ? Color.white : Aurora.texto2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28).padding(.trailing, 8)
            .frame(height: 29)
            .background {
                if selecionado {
                    RoundedRectangle(cornerRadius: 9).fill(Aurora.acento.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Aurora.acento.opacity(0.20), lineWidth: 1))
                        .matchedGeometryEffect(id: "subsecao", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Logotipo: o ícone do app, o mesmo do Dock.
struct MarcaTuttiDash: View {
    var body: some View {
        MarcaAurora(tamanho: 34)
    }
}

struct ItemNavegacao: View {
    var simbolo: String
    var texto: String
    var selecionado: Bool
    /// `false` no «Ajustes» com as sub-seções abertas: o destaque forte fica na sub-seção ativa.
    var destaque = true
    /// Seta de grupo aberto/fechado (só no item «Ajustes»).
    var chevron = false
    /// Contador de itens esperando ação (só em «Esperando você»).
    var badge = 0
    var ns: Namespace.ID? = nil
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 12) {
                Image(systemName: simbolo)
                    .font(.system(size: 14, weight: selecionado ? .semibold : .regular))
                    .foregroundStyle(selecionado ? Aurora.acento : Aurora.mudo)
                    .frame(width: 19)
                Text(texto)
                    .font(.system(size: 13, weight: selecionado ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selecionado ? Color.white : Aurora.texto2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Aurora.ambar)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Aurora.ambar.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(Aurora.ambar.opacity(0.30), lineWidth: 1))
                        .accessibilityLabel(String(localized: "\(badge) esperando você"))
                }
                if chevron {
                    Image(systemName: selecionado ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Aurora.mudo)
                        .frame(width: 11)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background {
                if selecionado && destaque {
                    let fundo = RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Aurora.acento.opacity(0.16),
                                                      Aurora.azul.opacity(0.07)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Aurora.acento.opacity(0.28), lineWidth: 1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Aurora.acento)
                                .frame(width: 3, height: 17)
                                .padding(.leading, 5)
                        }
                    if let ns { fundo.matchedGeometryEffect(id: "pagina", in: ns) } else { fundo }
                } else if hover {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
        .accessibilityAddTraits(selecionado ? .isSelected : AccessibilityTraits())
    }
}

/// Cabeçalho: título da página, busca (ainda sem função), notificações (ainda sem central) e conta.
/// Nos Ajustes, o título e a busca acompanham a sub-seção aberta (FRA-531): assim a página
/// não repete um segundo cabeçalho dentro do formulário.
struct CabecalhoPainel: View {
    var pagina: PaginaPainel
    @ObservedObject var modelo: ModeloNotch
    var ir: (PaginaPainel) -> Void
    /// Foto da transição: texto estático. O `TextField` no `ImageRenderer` pinta o
    /// placeholder em amarelo/laranja e as partículas herdam essa cor.
    var foto = false
    @ObservedObject private var busca = BuscaPainel.compartilhada
    @ObservedObject private var nav = NavegacaoPainel.compartilhada
    @FocusState private var focoBusca: Bool

    private var secaoAjustes: SecaoAjustes? {
        guard pagina == .ajustes else { return nil }
        return CatalogoAjustes.secoes().first { $0.id == nav.secao }
    }

    /// Só as páginas com listas filtráveis mostram a busca. Antes o campo aparecia em
    /// Brainstorm e «Esperando você», onde digitar não filtrava nada.
    private var paginaTemBusca: Bool {
        switch pagina {
        case .lanes, .builds, .entregas, .testes, .custos: return true
        case .dashboard, .brainstorm, .esperando, .ajustes: return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(secaoAjustes?.nome ?? pagina.titulo)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                    .lineLimit(1)
                Text(secaoAjustes?.subtitulo ?? pagina.subtitulo)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
                    .lineLimit(1)
            }
            .padding(.leading, 2)
            Spacer(minLength: 16)
            if pagina == .ajustes {
                CampoBuscaAjustes(texto: $nav.busca, largura: 300, altura: 36, pedidoFoco: nav.pedidoFocoBusca)
            } else if paginaTemBusca {
                campoBusca
            }
            // FRA-531: quando os dados foram lidos, e «Atualizar agora» com indicador e aviso.
            HStack(spacing: 10) {
                SeloAtualizado(data: modelo.atualizadoEm, carregando: modelo.atualizando || modelo.medindoUso)
                    .opacity(0.9)
                BotaoIconeAurora(simbolo: "arrow.clockwise",
                                 ajuda: "Atualizar agora",
                                 cor: Aurora.texto2,
                                 tamanho: 34) {
                    modelo.atualizarAgora()
                }
                .disabled(modelo.atualizando)
                .rotationEffect(.degrees(modelo.atualizando && !DS.reduzir ? 360 : 0))
                .animation(modelo.atualizando && !DS.reduzir
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default,
                           value: modelo.atualizando)
            }
            // Caixa do dono (PRD de 29/10): o sino mostra as respostas em aberto e abre «Esperando você».
            // Sem resposta em aberto, o ponto vermelho dos outros alertas do painel fica como antes.
            Button { ir(.esperando) } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(abertas > 0 ? Aurora.ambar : Aurora.texto2)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.045)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    if abertas > 0 {
                        Text("\(abertas)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Aurora.tinta)
                            .padding(.horizontal, 4.5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Aurora.ambar))
                            .overlay(Capsule().strokeBorder(Aurora.base, lineWidth: 1.5))
                            .offset(x: 8, y: -5)
                    } else if !(modelo.snapshot?.alertasPainel.isEmpty ?? true) {
                        Circle().fill(Aurora.vermelho)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Aurora.base, lineWidth: 1.5))
                            .offset(x: 2, y: 0)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(Pressionavel())
            .help(abertas > 0 ? String(localized: "\(abertas) resposta(s) em aberto: abrir Esperando você")
                                     : String(localized: "Nada esperando por você"))
            .accessibilityLabel(abertas > 0
                                ? String(localized: "\(abertas) respostas em aberto")
                                : String(localized: "Nenhuma resposta em aberto"))
            .onAppear { caixa.iniciar() }
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(Color.white.opacity(0.012))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Aurora.hair).frame(height: 1)
        }
        .onChange(of: nav.pedidoFocoBusca) { _, _ in focoBusca = true }
    }

    /// Busca de vidro do cabeçalho.
    private var campoBusca: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(focoBusca ? Aurora.acento : Aurora.mudo)
            if foto {
                Text(busca.texto.isEmpty ? "Buscar lanes, builds, entregas..." : busca.texto)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(busca.texto.isEmpty ? Aurora.mudo : Aurora.texto)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $busca.texto,
                          prompt: Text("Buscar lanes, builds, entregas...").foregroundColor(Aurora.mudo))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded))
                    .focused($focoBusca)
                    .foregroundStyle(Aurora.texto)
                    .tint(Aurora.acento)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !busca.texto.isEmpty {
                    Button { busca.texto = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Aurora.apagado)
                    }
                    .buttonStyle(.plain)
                    .help("Limpar busca")
                    .accessibilityLabel("Limpar busca")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 34)
        .background(Capsule().fill(Color.black.opacity(0.24)))
        .overlay(Capsule().strokeBorder(focoBusca ? Aurora.acento.opacity(0.55) : Color.white.opacity(0.10),
                                        lineWidth: 1))
        .animation(DS.anim(DS.suave), value: focoBusca)
        .help("Filtra a página atual por texto (id, título ou lane)")
    }

    @ObservedObject private var caixa = EstadoCaixa.compartilhada
    /// Sem o arquivo da caixa (vigia parado), vale o contador antigo do log do dispatcher.
    private var abertas: Int { caixa.arquivoExiste ? caixa.abertas : (modelo.snapshot?.esperandoVoce ?? 0) }
}
