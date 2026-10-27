import SwiftUI
import GastoCore

/// Anel de progresso semanal. `fracao` nil = sem teto (anel neutro, sem progresso).
struct Anel: View {
    var fracao: Double?
    var nivel: NivelTeto
    var tamanho: CGFloat
    var espessura: CGFloat
    var brilho: Bool = false

    var body: some View {
        let cor = Tema.cor(nivel: nivel)
        let f = min(max(fracao ?? 0, 0), 1)
        ZStack {
            Circle()
                .stroke(nivel == .semTeto ? Color.white.opacity(0.12) : cor.opacity(brilho ? 0.13 : 0.18),
                        lineWidth: espessura)
            if fracao != nil, f > 0 {
                if brilho {
                    Circle().trim(from: 0, to: f)
                        .stroke(cor.opacity(0.45), style: StrokeStyle(lineWidth: espessura, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .blur(radius: 3)
                }
                Circle().trim(from: 0, to: f)
                    .stroke(LinearGradient(colors: Tema.gradienteAnel(nivel: nivel),
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: espessura, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: tamanho - espessura, height: tamanho - espessura)
        .frame(width: tamanho, height: tamanho)
    }
}

/// Ponto verde pulsando (lane em execução). Cinza e parado quando `ativo` é false.
struct PontoPulsando: View {
    var ativo: Bool = true
    var cor: Color = Tema.ok
    /// Só anima quando o ambiente pede (painel expandido e visível). Na pílula e na medição
    /// invisível fica estático: a animação infinita redesenhava a janela sem parar (FRA-339).
    @Environment(\.animarPonto) private var animar
    @State private var pulso = false

    var body: some View {
        ZStack {
            if ativo && animar {
                Circle().stroke(cor.opacity(0.18), lineWidth: 1)
                    .frame(width: 24, height: 24)
                    .scaleEffect(pulso ? 1.0 : 0.55)
                    .opacity(pulso ? 0 : 1)
                Circle().stroke(cor.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulso ? 1.0 : 0.6)
                    .opacity(pulso ? 0.2 : 1)
            }
            Circle().fill(ativo ? cor : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
                .shadow(color: ativo ? cor.opacity(0.9) : .clear, radius: 4)
        }
        .frame(width: 8, height: 8)
        .onAppear { ajustarPulso() }
        .onChange(of: animar) { _, _ in ajustarPulso() }
    }

    private func ajustarPulso() {
        if ativo && animar {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulso = true }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { pulso = false }
        }
    }
}

private struct ChaveAnimarPonto: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Liga a animação do `PontoPulsando`. Padrão: desligada.
    var animarPonto: Bool {
        get { self[ChaveAnimarPonto.self] }
        set { self[ChaveAnimarPonto.self] = newValue }
    }
}

/// Fundo dos cards internos do painel.
struct FundoCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }
}

extension View {
    func fundoCard() -> some View { modifier(FundoCard()) }
}

/// Título de card em caixa alta ("ÚLTIMOS 7 DIAS").
struct TituloCard<Direita: View>: View {
    var texto: String
    @ViewBuilder var direita: Direita

    var body: some View {
        HStack(alignment: .center) {
            Text(texto.uppercased())
                .font(.sf(11, .semibold)).tracking(0.7)
                .foregroundStyle(Tema.t3)
            Spacer(minLength: 6)
            direita
        }
    }
}

struct ChipLane: View {
    var lane: String
    var body: some View {
        Text(lane)
            .font(.sf(9.5, .semibold))
            .foregroundStyle(Tema.cor(lane: lane))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Tema.cor(lane: lane).opacity(0.12)))
    }
}

/// Gradiente horizontal da lane (trilhas e segmentos).
func gradienteLane(_ lane: String) -> LinearGradient {
    LinearGradient(colors: [Tema.cor2(lane: lane), Tema.cor(lane: lane)], startPoint: .leading, endPoint: .trailing)
}
