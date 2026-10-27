import SwiftUI
import GastoCore

/// Notch recolhido: um ponto por lane de desenvolvimento. Só aparece com
/// `PreferenciaNotch` ligada; o padrão do app é a pílula da barra de menus.
struct Pilula: View {
    @ObservedObject var modelo: ModeloNotch

    var body: some View {
        let snap = modelo.snapshot
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(snap?.notch.pontos ?? pontosVazios, id: \.lane) { ponto in
                    Circle()
                        .fill(corPonto(ponto))
                        .frame(width: 8, height: 8)
                        .shadow(color: ponto.aceso ? corPonto(ponto).opacity(0.8) : .clear, radius: 3)
                }
            }
            .fixedSize()
            .medirLargura(ChaveLadoEsquerdo.self)
            Spacer(minLength: modelo.temNotch ? modelo.larguraNotch : 12)
        }
        .padding(.leading, 12)
        .padding(.bottom, 1)
        .frame(width: modelo.larguraPilula, height: modelo.alturaNotch)
        .onPreferenceChange(ChaveLadoEsquerdo.self) { w in
            if w > 0, w != modelo.conteudoEsquerda {
                modelo.conteudoEsquerda = w
                modelo.conferirAviso()
            }
        }
    }

    private var pontosVazios: [PontoNotch] {
        LanesPainel.ordem.map { PontoNotch(lane: $0, aceso: false, atencao: false) }
    }
}

struct ChaveLadoEsquerdo: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ChaveLadoDireito: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Publica a largura natural da view (já com `.fixedSize()`), sem mudar o layout.
    func medirLargura<K: PreferenceKey>(_ chave: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { g in Color.clear.preference(key: chave, value: g.size.width) })
    }
}

func corPonto(_ ponto: PontoNotch) -> Color {
    if !ponto.aceso { return TemaPainel.apagado }
    if ponto.atencao { return TemaPainel.amarelo }
    return TemaPainel.cor(ponto.lane)
}

func corConta(_ pct: Double?) -> Color {
    guard let pct else { return TemaPainel.mudo }
    if pct >= Uso.pctCritico { return TemaPainel.vermelho }
    if pct >= Uso.pctAtencao { return TemaPainel.amarelo }
    return TemaPainel.texto
}

struct CirculoEstado: View {
    var geral: EstadoGeral?
    var pulsar: Bool
    @Environment(\.animarPonto) private var animar

    var body: some View {
        let cor = geral.map { TemaPainel.cor($0) } ?? TemaPainel.mudo
        Circle()
            .fill(cor)
            .frame(width: 8, height: 8)
            .shadow(color: cor.opacity(0.9), radius: 4)
            .scaleEffect(pulsar && animar ? 1.15 : 1)
            .animation(pulsar && animar ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulsar && animar)
    }
}
