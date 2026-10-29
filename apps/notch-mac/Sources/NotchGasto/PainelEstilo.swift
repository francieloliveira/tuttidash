import AppKit
import SwiftUI
import GastoCore

/// Cores e medidas do painel v2. Amostradas da imagem de referência do design.
enum PV {
    static let fundo = Color(hex: 0x040B17)
    static let lateral = Color(hex: 0x020814)
    static let lateralBorda = Color(hex: 0x0D1828)
    static let divisor = Color(hex: 0x13213A)
    static let cartao = Color(hex: 0x081426)
    static let cartaoBorda = Color(hex: 0x15233A)
    static let interno = Color(hex: 0x0A1628)
    static let linha = Color(hex: 0x0C1A2E)
    static let linhaBorda = Color(hex: 0x13223A)
    static let kpiTopo = Color(hex: 0x071A2E)
    static let kpiBase = Color(hex: 0x061424)
    static let kpiBorda = Color(hex: 0x16273F)
    static let campo = Color(hex: 0x06101F)
    static let campoBorda = Color(hex: 0x1B2A44)
    static let tecla = Color(hex: 0x111D31)
    static let botao = Color(hex: 0x0A1A30)
    static let botaoBorda = Color(hex: 0x22344F)
    static let navSelecao = Color(hex: 0x0A2149)
    static let navSelecaoBorda = Color(hex: 0x17386E)
    static let tag = Color(hex: 0x1A2840)
    static let trilho = Color(hex: 0x22364F)
    static let grade = Color(hex: 0x15233A)
    static let eixo = Color(hex: 0x22324C)

    static let texto = Color(hex: 0xE6EDF7)
    static let texto2 = Color(hex: 0xC2CEDF)
    static let icone = Color(hex: 0xC9D4E4)
    static let mudo = Color(hex: 0xA9B6C9)
    static let apagado = Color(hex: 0x6B7C96)

    static let azul = Color(hex: 0x4FA3FF)
    static let azulForte = Color(hex: 0x3B82F6)
    static let azulBotao = Color(hex: 0x1F5FE0)
    static let azulIcone = Color(hex: 0x3B9BFF)
    static let azulFundo = Color(hex: 0x0B2B57)
    static let verde = Color(hex: 0x35D66E)
    static let verdeClaro = Color(hex: 0x22E5A0)
    static let verdeFundo = Color(hex: 0x0F3B33)
    static let vermelho = Color(hex: 0xFF4D6D)
    static let vermelhoPonto = Color(hex: 0xFF3B5C)
    static let vermelhoFundo = Color(hex: 0x4A1528)
    static let ambar = Color(hex: 0xF5A524)
    static let ambarFundo = Color(hex: 0x4A3416)
    static let dourado = Color(hex: 0xF2B544)
    static let teal = Color(hex: 0x3EE2DB)
    static let tealFundo = Color(hex: 0x0B3D44)
    static let ciano = Color(hex: 0x2EE6EA)
    static let cinzaPilula = Color(hex: 0x1C2A40)
    static let pontoPilula = Color(hex: 0xB9C7DD)

    /// Barras de «Gasto por lane», na ordem das lanes.
    static let barrasLane: [Color] = [
        Color(hex: 0x2EE6EA), Color(hex: 0x3D8BFD), Color(hex: 0x8B8CF8), Color(hex: 0xF45FBE), Color(hex: 0xF0A271),
        Color(hex: 0x5CFFC8), Color(hex: 0xFFD23F),
    ]

    static func fonte(_ tamanho: CGFloat, _ peso: Font.Weight = .regular) -> Font {
        .system(size: tamanho, weight: peso)
    }
}

/// Páginas da barra lateral.
enum PaginaPainel: String, CaseIterable, Identifiable {
    case dashboard, lanes, builds, entregas, testes, custos, esperando, ajustes

    var id: String { rawValue }
    /// Páginas da lista de cima; Ajustes fica abaixo do divisor, com sub-seções.
    static var principais: [PaginaPainel] { allCases.filter { $0 != .ajustes } }

    var titulo: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .lanes: return "Lanes"
        case .builds: return "Builds"
        case .entregas: return "Entregas"
        case .testes: return "Testes"
        case .custos: return "Custos"
        case .esperando: return "Esperando você"
        case .ajustes: return "Ajustes"
        }
    }

    var subtitulo: String {
        switch self {
        case .dashboard: return "Visão geral do ambiente de build, testes e entregas"
        case .lanes: return "Estado, branch e ações de cada lane"
        case .builds: return "Lock, fila, simulador e histórico de execuções"
        case .entregas: return "Cards fechados e o que está instalado nos aparelhos"
        case .testes: return "Provas em curso, fila do lock e histórico"
        case .custos: return "Gasto conhecido, uso das contas e cards mais caros"
        case .esperando: return "Cards que precisam de uma decisão sua, com a pendência resumida"
        case .ajustes: return "Tudo o que o TuttiDash e as lanes usam, num lugar só"
        }
    }

    var simbolo: String {
        switch self {
        case .dashboard: return "house.fill"
        case .lanes: return "list.bullet.rectangle"
        case .builds: return "server.rack"
        case .entregas: return "truck.box"
        case .testes: return "checkmark.circle"
        case .custos: return "gauge.with.dots.needle.33percent"
        case .esperando: return "bell.badge"
        case .ajustes: return "gearshape"
        }
    }
}

/// Estado da pílula da lane, como na imagem: Ativa, Pausada, Desligada.
enum EstadoPilula {
    case ativa, pausada, desligada

    init(_ estado: EstadoLanePainel) {
        switch estado {
        case .rodando, .livre: self = .ativa
        case .esperando, .semFolga: self = .pausada
        case .desligada: self = .desligada
        }
    }

    var rotulo: String {
        switch self {
        case .ativa: return "Ativa"
        case .pausada: return "Pausada"
        case .desligada: return "Desligada"
        }
    }

    /// Ponto antes do nome da lane.
    var corLane: Color {
        switch self {
        case .ativa: return PV.verde
        case .pausada: return PV.ambar
        case .desligada: return PV.vermelhoPonto
        }
    }
}

/// «há 8 min», «há 2 h», «há 1 h 6 min», «há 3 d». Futuro ou < 1 min: «agora».
func haPainel(_ data: Date?, agora: Date) -> String? {
    guard let data else { return nil }
    let s = Int(agora.timeIntervalSince(data))
    if s < 60 { return "agora" }
    let m = s / 60
    if m < 60 { return "há \(m) min" }
    let h = m / 60
    if h < 24 { return m % 60 == 0 ? "há \(h) h" : "há \(h) h \(m % 60) min" }
    return "há \(h / 24) d"
}

// MARK: - Componentes

/// Cartão do painel (fundo, borda e cantos da imagem).
struct CartaoPV<Conteudo: View>: View {
    var raio: CGFloat = 14
    var fundo: Color = PV.cartao
    @ViewBuilder var conteudo: Conteudo
    @State private var hover = false

    var body: some View {
        conteudo
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cartaoVivo(raio: raio, hover: hover)
            .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Quadrado colorido com o ícone do cartão.
struct IconeCartao: View {
    var simbolo: String? = nil
    var cor: Color = PV.azul
    var fundo: Color = PV.azulFundo
    var tamanho: CGFloat = 38
    var tamanhoIcone: CGFloat = 19
    var foguete = false

    var body: some View {
        RoundedRectangle(cornerRadius: tamanho * 0.27, style: .continuous)
            .fill(fundo)
            .frame(width: tamanho, height: tamanho)
            .overlay {
                if foguete {
                    Foguete().stroke(cor, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: tamanhoIcone + 2, height: tamanhoIcone + 2)
                } else if let simbolo {
                    Image(systemName: simbolo).font(.system(size: tamanhoIcone, weight: .medium)).foregroundStyle(cor)
                }
            }
    }
}

/// Foguete (o SF Symbols não tem). Desenhado em 24×24.
struct Foguete: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(14, 4))
        path.addCurve(to: p(20, 3.5), control1: p(17, 2.5), control2: p(19.5, 3))
        path.addCurve(to: p(19.5, 9.5), control1: p(21, 4.5), control2: p(21, 7))
        path.addLine(to: p(13, 16))
        path.addLine(to: p(8, 11))
        path.closeSubpath()
        path.move(to: p(8, 11)); path.addLine(to: p(4.5, 11)); path.addLine(to: p(7, 8)); path.addLine(to: p(11, 8))
        path.move(to: p(13, 16)); path.addLine(to: p(13, 19.5)); path.addLine(to: p(16, 17)); path.addLine(to: p(16, 13))
        path.move(to: p(6, 15)); path.addCurve(to: p(3.5, 20.5), control1: p(4.5, 15.5), control2: p(3.5, 17))
        path.addCurve(to: p(9, 18), control1: p(6.5, 20.5), control2: p(8, 19.5))
        path.addEllipse(in: CGRect(x: r.minX + 14.6 * s, y: r.minY + 6.6 * s, width: 2.8 * s, height: 2.8 * s))
        return path
    }
}

/// Título + subtítulo + ação à direita, no topo de cada cartão.
struct CabecalhoCartao<Direita: View>: View {
    var icone: IconeCartao
    var titulo: String
    var subtitulo: String
    @ViewBuilder var direita: Direita

    var body: some View {
        HStack(spacing: 0) {
            icone.padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(PV.fonte(17, .semibold)).foregroundStyle(PV.texto)
                Text(subtitulo).font(PV.fonte(12.5)).foregroundStyle(PV.mudo).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            direita
        }
    }
}

/// Versão do build no topo do app (29/10): «main-<sha>» discreto; num build de branch,
/// «branch-…» em laranja com o selo ALPHA TEST.
struct SeloVersao: View {
    var versao: VersaoApp = .atual
    var compacto = false

    var body: some View {
        HStack(spacing: 6) {
            if versao.alpha {
                Text(verbatim: "ALPHA TEST").font(PV.fonte(compacto ? 9.5 : 10, .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(PV.ambar))
            }
            Text(verbatim: versao.texto)
                .font(.system(size: compacto ? 10 : 10.5, design: .monospaced))
                .foregroundStyle(versao.alpha ? PV.ambar : PV.apagado)
                .lineLimit(1).truncationMode(.middle)
        }
        .help(versao.alpha ? String(localized: "Build de teste (fora da main do GitHub): \(versao.texto)")
                           : String(localized: "Build da main do GitHub: \(versao.texto)"))
    }
}

/// «Ver todas →».
struct BotaoVer: View {
    var texto: String
    var pequeno = false
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: pequeno ? 6 : 7) {
                Text(texto)
                Image(systemName: "arrow.right").font(.system(size: pequeno ? 10 : 11, weight: .semibold))
            }
            .fixedSize()
            .font(PV.fonte(pequeno ? 11.5 : 12.5))
            .foregroundStyle(PV.texto)
            .padding(.horizontal, pequeno ? 10 : 11)
            .frame(height: pequeno ? 26 : 32)
            .background(RoundedRectangle(cornerRadius: pequeno ? 7 : 8).fill(hover ? PV.azulFundo : PV.botao))
            .overlay(RoundedRectangle(cornerRadius: pequeno ? 7 : 8).strokeBorder(hover ? PV.azul.opacity(0.5) : PV.botaoBorda, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Pílula Ativa / Pausada / Desligada.
struct PilulaEstado: View {
    var estado: EstadoPilula

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(estado == .ativa ? PV.verde : PV.pontoPilula).frame(width: 8, height: 8)
            Text(estado.rotulo).font(PV.fonte(12, .medium)).foregroundStyle(PV.texto)
        }
        .padding(.leading, 11).padding(.trailing, 13)
        .frame(height: 28)
        .background(Capsule().fill(estado == .ativa ? PV.verdeFundo : PV.cinzaPilula))
    }
}

/// Barrinhas dos cartões do topo. Altura proporcional ao maior valor, mínimo visível.
struct Barrinhas: View {
    var valores: [Double]
    var cor: (Int, Double) -> Color
    var largura: CGFloat = 4
    var espaco: CGFloat = 3
    var altura: CGFloat = 30

    var body: some View {
        let maximo = valores.max() ?? 0
        HStack(alignment: .bottom, spacing: espaco) {
            ForEach(Array(valores.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(cor(i, v))
                    .frame(width: largura, height: maximo > 0 ? max(5, altura * v / maximo) : 5)
            }
        }
        .frame(height: altura, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Barra horizontal com trilho opcional.
struct BarraPV: View {
    var fracao: Double
    var cor: Color
    var altura: CGFloat = 10
    var trilho: Color? = nil

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let trilho { Capsule().fill(trilho) }
                Capsule().fill(cor)
                    .frame(width: fracao > 0 ? max(altura, g.size.width * min(fracao, 1)) : 0)
                    .animation(DS.anim(DS.barra), value: fracao)
            }
        }
        .frame(height: altura)
    }
}

/// Abre um comando de terminal configurável (mesmo comportamento do `BotaoAbrirComando`).
@MainActor
enum AbrirComando {
    static func abrir(chave: String, padrao: String) {
        let cfg = Configuracao.lerArquivo()
        let caminho = Configuracao.valor(chave, em: cfg).map { "\($0)" } ?? padrao
        let cmd = Configuracao.expandir(caminho, ambiente: [:], home: FileManager.default.homeDirectoryForCurrentUser)
        CentralAvisos.compartilhada.info(String(localized: "Abrindo no Terminal…"))
        NSWorkspace.shared.open([cmd], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { _, erro in
            guard let erro else { return }
            let m = erro.localizedDescription
            Task { @MainActor in CentralAvisos.compartilhada.erro(String(localized: "O Terminal não abriu"), m) }
        }
    }

    static func painelLogs() { abrir(chave: "painel.comando", padrao: Legado.painelComando) }
    static func janelaLanes() { abrir(chave: "painel.lanes_comando", padrao: Legado.lanesComando) }
}

/// Botão retangular das páginas (ferramentas, log).
struct BotaoPV: View {
    var texto: String
    var cor: Color = PV.texto
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            Text(texto).font(PV.fonte(12.5)).foregroundStyle(cor)
                .padding(.horizontal, 12).frame(minHeight: 34)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? PV.azulFundo : PV.botao))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hover ? PV.azul.opacity(0.5) : PV.botaoBorda, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Abas da lista de builds na tela Custos. A principal é a lista completa.
enum AbaListaCustos: String, CaseIterable, Equatable {
    case todos
    case maisCaros

    var rotulo: String {
        switch self {
        case .todos: return "Todos os builds"
        case .maisCaros: return "Builds mais caros"
        }
    }
}

/// Seletor Todos os builds / Builds mais caros, no mesmo desenho do período.
struct SeletorAbasCustos: View {
    @Binding var aba: AbaListaCustos
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AbaListaCustos.allCases, id: \.self) { item in
                Button { comAnimacao { aba = item } } label: {
                    Text(item.rotulo)
                        .font(PV.fonte(12.5, aba == item ? .semibold : .regular))
                        .foregroundStyle(aba == item ? Color.white : PV.texto)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if aba == item {
                                RoundedRectangle(cornerRadius: 7).fill(PV.azulBotao)
                                    .matchedGeometryEffect(id: "aba-custos", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(aba == item ? .isSelected : AccessibilityTraits())
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(PV.botao))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PV.campoBorda, lineWidth: 1))
    }
}

/// Seletor Semana / Mês / Ano.
struct SeletorPeriodo: View {
    @Binding var periodo: PeriodoCustos
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PeriodoCustos.allCases, id: \.self) { p in
                Button { comAnimacao { periodo = p } } label: {
                    Text(p.rotulo)
                        .font(PV.fonte(12.5, periodo == p ? .semibold : .regular))
                        .foregroundStyle(periodo == p ? Color.white : PV.texto)
                        .frame(width: p == .semana ? 78 : 66, height: 28)
                        .background { if periodo == p { RoundedRectangle(cornerRadius: 7).fill(PV.azulBotao).matchedGeometryEffect(id: "periodo", in: ns) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(PV.botao))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PV.campoBorda, lineWidth: 1))
    }
}

/// Rótulo de coluna das tabelas das páginas.
struct RotuloColuna: View {
    var texto: String
    var body: some View {
        Text(texto.uppercased()).font(PV.fonte(11)).tracking(0.6).foregroundStyle(Color(hex: 0x8FA0BA))
    }
}

extension View {
    /// Linha interna (fundo um pouco mais claro que o cartão).
    func linhaPV(raio: CGFloat = 8, borda: Bool = true) -> some View {
        background(RoundedRectangle(cornerRadius: raio, style: .continuous).fill(PV.linha))
            .overlay {
                if borda {
                    RoundedRectangle(cornerRadius: raio, style: .continuous).strokeBorder(PV.linhaBorda, lineWidth: 1)
                }
            }
    }
}
