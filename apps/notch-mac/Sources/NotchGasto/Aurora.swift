import AppKit
import SwiftUI
import GastoCore

// MARK: - Linguagem visual

/// A linguagem visual do TuttiDash, alinhada ao IntegraNotes/VaultAI:
/// fundo aurora escuro, vidro com borda luminosa, tipografia arredondada,
/// rótulos em caixa alta e acentos em ciano → azul → violeta.
///
/// A regra é simples: nenhuma tela inventa cor ou raio. Tudo sai daqui,
/// e `PV` (PainelEstilo) aponta para estes valores para o código antigo
/// continuar funcionando com o visual novo.
enum Aurora {
    // Fundo
    static let topo = Color(hex: 0x0B1020)
    static let base = Color(hex: 0x06070D)
    static let tinta = Color(hex: 0x061018)
    static let vidro = Color(hex: 0x0C1322)
    static let vidroClaro = Color(hex: 0x111B2E)

    // Acentos
    static let acento = Color(hex: 0x5EEAD4)
    static let azul = Color(hex: 0x60A5FA)
    static let azulForte = Color(hex: 0x3B82F6)
    static let violeta = Color(hex: 0xA78BFA)
    static let verde = Color(hex: 0x34D399)
    static let vermelho = Color(hex: 0xF87171)
    static let ambar = Color(hex: 0xFBBF24)
    static let ciano = Color(hex: 0x22D3EE)
    static let rosa = Color(hex: 0xF472B6)

    // Texto
    static let texto = Color(hex: 0xF1F5FB)
    static let texto2 = Color(hex: 0xC7D2E4)
    static let mudo = Color(hex: 0x8B93A7)
    static let apagado = Color(hex: 0x5D6779)
    static let hair = Color.white.opacity(0.08)

    /// Gradiente da marca: ciano → azul → violeta.
    static let gradienteMarca = LinearGradient(
        colors: [acento, azul, violeta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// Gradiente dos botões principais (texto em tinta escura).
    static let gradienteBotao = LinearGradient(
        colors: [acento, azul],
        startPoint: .leading,
        endPoint: .trailing)

    /// Preenchimento padrão de um cartão de vidro.
    static let preenchimentoVidro = LinearGradient(
        colors: [Color.white.opacity(0.065), Color.white.opacity(0.018)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// Borda padrão de um cartão de vidro.
    static let bordaVidro = LinearGradient(
        colors: [Color.white.opacity(0.16), Color.white.opacity(0.035)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    static func cor(_ estado: EstadoGeral) -> Color {
        switch estado {
        case .tudoOk: return verde
        case .atencao: return ambar
        case .parado: return vermelho
        }
    }

    /// Cor de uma lane: a do manifesto, senão a matiz determinística do nome.
    static func cor(lane: String) -> Color {
        TemaPainel.cor(lane)
    }
}

// MARK: - Fundo

/// Fundo aurora: gradiente escuro com três focos de luz (azul, violeta e ciano).
/// Feito com `RadialGradient` de propósito: desenha barato e aparece no `ImageRenderer`
/// usado nas transições de página (um `blur` grande ficaria pesado e sumiria na foto).
struct FundoAurora: View {
    var intensidade: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Aurora.topo, Aurora.base],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(colors: [Aurora.azul.opacity(0.30 * intensidade), .clear],
                           center: UnitPoint(x: 0.12, y: 0.02),
                           startRadius: 10, endRadius: 760)

            RadialGradient(colors: [Aurora.violeta.opacity(0.22 * intensidade), .clear],
                           center: UnitPoint(x: 0.92, y: 0.72),
                           startRadius: 10, endRadius: 680)

            RadialGradient(colors: [Aurora.acento.opacity(0.15 * intensidade), .clear],
                           center: UnitPoint(x: 0.78, y: -0.04),
                           startRadius: 10, endRadius: 560)

            LinearGradient(colors: [Color.white.opacity(0.02), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cartões

/// Fundo de vidro padrão. Um só desenho para todos os cartões do app.
struct FundoVidro: ViewModifier {
    var raio: CGFloat = 20
    var brilho: Color? = nil
    var hover = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: raio, style: .continuous)
                        .fill(Aurora.vidro.opacity(0.58))
                    RoundedRectangle(cornerRadius: raio, style: .continuous)
                        .fill(Aurora.preenchimentoVidro)
                    RoundedRectangle(cornerRadius: raio, style: .continuous)
                        .fill(Color.white.opacity(hover ? 0.025 : 0))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: raio, style: .continuous)
                    .strokeBorder(Aurora.bordaVidro, lineWidth: 1)
            }
            .overlay {
                if let brilho {
                    RoundedRectangle(cornerRadius: raio, style: .continuous)
                        .strokeBorder(brilho.opacity(0.28), lineWidth: 1)
                        .shadow(color: brilho.opacity(0.22), radius: 16)
                }
            }
            .shadow(color: .black.opacity(hover ? 0.42 : (brilho == nil ? 0.34 : 0.24)),
                    radius: hover ? 22 : 18, y: hover ? 12 : 9)
    }
}

extension View {
    /// Vidro do app: fundo, borda e sombra num lugar só.
    func vidroAurora(raio: CGFloat = 20, brilho: Color? = nil, hover: Bool = false) -> some View {
        modifier(FundoVidro(raio: raio, brilho: brilho, hover: hover))
    }
}

/// Cartão de vidro com o padding da referência.
struct CartaoVidro<Conteudo: View>: View {
    var padding: CGFloat = 18
    var raio: CGFloat = 20
    var brilho: Color? = nil
    @ViewBuilder var conteudo: Conteudo

    var body: some View {
        conteudo
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .vidroAurora(raio: raio, brilho: brilho)
    }
}

// MARK: - Rótulos e selos

/// Título de seção em caixa alta, 10 pt, com ícone opcional. O mesmo da referência.
struct RotuloSecao: View {
    var titulo: String
    var icone: String? = nil
    var cor: Color = Aurora.mudo

    var body: some View {
        HStack(spacing: 5) {
            if let icone {
                Image(systemName: icone).font(.system(size: 9.5, weight: .semibold))
            }
            Text(titulo.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.05)
                .lineLimit(1)
        }
        .foregroundStyle(cor)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Pílula de estado: ponto aceso + rótulo, com fundo e borda na cor.
struct PilulaAurora: View {
    var titulo: String
    var cor: Color
    var simbolo: String? = nil
    var compacta = false

    var body: some View {
        HStack(spacing: compacta ? 5 : 7) {
            if let simbolo {
                Image(systemName: simbolo).font(.system(size: compacta ? 8 : 9, weight: .bold))
            } else {
                Circle().fill(cor)
                    .frame(width: compacta ? 6 : 7, height: compacta ? 6 : 7)
                    .shadow(color: cor.opacity(0.9), radius: 4)
            }
            Text(titulo)
                .font(.system(size: compacta ? 10 : 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(cor)
        .padding(.horizontal, compacta ? 9 : 11)
        .padding(.vertical, compacta ? 3 : 5)
        .background(Capsule().fill(cor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(cor.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Etiqueta pequena (lane, tentativa, tag).
struct EtiquetaAurora: View {
    var texto: String
    var cor: Color = Aurora.mudo

    var body: some View {
        Text(texto)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(cor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(cor.opacity(0.12)))
    }
}

// MARK: - Botões

/// Botão principal: pílula com gradiente ciano → azul e texto escuro.
struct EstiloBotaoPrincipal: ButtonStyle {
    var compacto = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compacto ? 12 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Aurora.tinta)
            .frame(maxWidth: compacto ? nil : .infinity)
            .padding(.horizontal, compacto ? 14 : 0)
            .padding(.vertical, compacto ? 7 : 11)
            .background(Capsule().fill(Aurora.gradienteBotao))
            .shadow(color: Aurora.acento.opacity(configuration.isPressed ? 0.18 : 0.32),
                    radius: configuration.isPressed ? 6 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Botão secundário: pílula de vidro com texto claro.
struct EstiloBotaoSecundario: ButtonStyle {
    var compacto = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compacto ? 11 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.75 : 0.92))
            .lineLimit(1)
            .frame(maxWidth: compacto ? nil : .infinity)
            .padding(.horizontal, compacto ? 10 : 0)
            .padding(.vertical, compacto ? 5 : 9)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.055)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Ícone redondo do cabeçalho (atualizar, sino, busca).
struct BotaoIconeAurora: View {
    var simbolo: String
    var ajuda: String = ""
    var cor: Color = Aurora.mudo
    var tamanho: CGFloat = 32
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: tamanho * 0.40, weight: .semibold))
                .foregroundStyle(hover ? Color.white : cor)
                .frame(width: tamanho, height: tamanho)
                .background(Circle().fill(Color.white.opacity(hover ? 0.11 : 0.045)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.18 : 0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
        .help(ajuda)
        .accessibilityLabel(ajuda.isEmpty ? simbolo : ajuda)
    }
}

// MARK: - Métricas

/// Azulejo de métrica da referência: ícone e rótulo em caixa alta, valor grande.
struct LadrilhoMetrica: View {
    var icone: String
    var titulo: String
    var valor: String
    var cor: Color
    var detalhe: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icone)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(cor)
                Text(titulo.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Aurora.mudo)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(valor)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(valor == "—" || valor == "sem dado" ? Aurora.mudo : cor)
                .contentTransition(.numericText())
            if let detalhe {
                Text(detalhe)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(cor.opacity(0.18), lineWidth: 1))
    }
}

/// Métrica compacta de uma linha (pílula da barra de menus e cabeçalhos).
struct MetricaCompacta: View {
    var icone: String
    var titulo: String
    var valor: String
    var cor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icone)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(cor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(cor.opacity(0.13)))
            VStack(alignment: .leading, spacing: 0) {
                Text(valor)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Aurora.texto)
                    .lineLimit(1)
                Text(titulo)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Barras

/// Barra de progresso com trilho, gradiente e brilho. Aceita fração desconhecida
/// (barra animada) ou 0...1.
struct BarraAurora: View {
    var fracao: Double?
    var cor: Color = Aurora.acento
    var altura: CGFloat = 6
    var trilho: Color = Color.white.opacity(0.08)
    var animada = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(trilho)

                if let f = fracao {
                    Capsule()
                        .fill(LinearGradient(colors: [cor, Aurora.azul],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: f > 0 ? max(altura, g.size.width * min(max(f, 0), 1)) : 0)
                        .shadow(color: cor.opacity(0.45), radius: 4)
                        .animation(DS.anim(DS.barra), value: f)
                } else if animada {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        let ciclo = ctx.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        let faixa = max(70, g.size.width * 0.45)
                        Capsule()
                            .fill(LinearGradient(
                                stops: [
                                    .init(color: cor.opacity(0), location: 0),
                                    .init(color: cor, location: 0.5),
                                    .init(color: cor.opacity(0), location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: faixa)
                            .offset(x: -faixa + (g.size.width + faixa) * ciclo)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: altura)
        .accessibilityHidden(true)
    }
}

// MARK: - Anel

/// Anel de progresso da referência. Sem valor, mostra um símbolo ou o traço.
struct AnelAurora: View {
    var percent: Int?
    var cor: Color = Aurora.acento
    var tamanho: CGFloat = 84
    var legenda: String = ""
    var simbolo: String? = nil
    var ativo = false
    @State private var girando = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: max(5, tamanho * 0.085))

            if let percent {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, Double(percent) / 100)))
                    .stroke(AngularGradient(colors: [cor, Aurora.azul, cor], center: .center),
                            style: StrokeStyle(lineWidth: max(5, tamanho * 0.085), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: cor.opacity(0.45), radius: 6)
                    .animation(.easeInOut(duration: 0.55), value: percent)
            } else if ativo {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(AngularGradient(colors: [cor.opacity(0.08), cor, cor.opacity(0.08)], center: .center),
                            style: StrokeStyle(lineWidth: max(5, tamanho * 0.085), lineCap: .round))
                    .rotationEffect(.degrees(girando ? 360 : 0))
                    .onAppear {
                        guard !DS.reduzir else { return }
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { girando = true }
                    }
            }

            VStack(spacing: 1) {
                if let percent {
                    Text("\(percent)%")
                        .font(.system(size: tamanho * 0.235, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Aurora.texto)
                } else if let simbolo {
                    Image(systemName: simbolo)
                        .font(.system(size: tamanho * 0.26, weight: .bold))
                        .foregroundStyle(cor)
                } else {
                    Text("—")
                        .font(.system(size: tamanho * 0.22, weight: .bold, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                }
                if !legenda.isEmpty {
                    Text(legenda.uppercased())
                        .font(.system(size: max(7, tamanho * 0.082), weight: .semibold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Aurora.mudo)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: tamanho, height: tamanho)
    }
}

// MARK: - Marca

/// Marca do app: o ícone no bundle dentro de um quadrado de vidro com a borda do gradiente.
/// É a mesma peça em todos os tamanhos (barra lateral, cabeçalho, primeira abertura).
struct MarcaAurora: View {
    var tamanho: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tamanho * 0.29, style: .continuous)
                .fill(Aurora.gradienteMarca)
                .opacity(0.22)
            RoundedRectangle(cornerRadius: tamanho * 0.29, style: .continuous)
                .fill(Aurora.vidro.opacity(0.9))
            Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: tamanho * 0.74, height: tamanho * 0.74)
                .clipShape(RoundedRectangle(cornerRadius: tamanho * 0.22, style: .continuous))
        }
        .frame(width: tamanho, height: tamanho)
        .overlay(
            RoundedRectangle(cornerRadius: tamanho * 0.29, style: .continuous)
                .strokeBorder(Aurora.bordaVidro, lineWidth: 1))
        .shadow(color: Aurora.azul.opacity(0.35), radius: tamanho * 0.35, y: tamanho * 0.10)
        .accessibilityHidden(true)
    }
}

// MARK: - Campos

/// Campo de texto de vidro dos formulários e buscas.
struct CampoAurora<Conteudo: View>: View {
    var altura: CGFloat = 34
    var raio: CGFloat = 11
    var focado = false
    @ViewBuilder var conteudo: Conteudo

    var body: some View {
        conteudo
            .padding(.horizontal, 11)
            .frame(height: altura)
            .background(RoundedRectangle(cornerRadius: raio, style: .continuous)
                .fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: raio, style: .continuous)
                .strokeBorder(focado ? Aurora.acento.opacity(0.65) : Color.white.opacity(0.10),
                              lineWidth: 1))
            .animation(DS.anim(DS.suave), value: focado)
    }
}

// MARK: - Compatibilidade

/// Converte as cores antigas (`PV`) para as da Aurora sem tocar em cada tela.
enum AuroraCompat {
    /// Brilho do cartão a partir de uma cor de estado.
    static func brilho(_ cor: Color?) -> Color? {
        guard let cor else { return nil }
        return cor.opacity(0.9)
    }
}
