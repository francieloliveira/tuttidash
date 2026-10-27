import SwiftUI
import GastoCore

private struct ChaveAlturaPainel: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Conteúdo da janela: a forma preta do notch que muda de pílula para painel com animação.
struct RaizNotch: View {
    @ObservedObject var modelo: ModeloNotch

    static let animacao = Animation.spring(response: 0.42, dampingFraction: 0.84)

    var body: some View {
        let exp = modelo.expandido
        let orelha: CGFloat = Tema.orelha
        let largura = exp ? Tema.larguraNotchAberto : modelo.larguraPilula
        let altura = exp ? max(modelo.tamanhoPainel.height, modelo.alturaNotch) : modelo.alturaNotch
        let raioBaixo = exp ? Tema.raioPainel : Tema.raioPilula
        let forma = FormaNotch(raioBaixo: raioBaixo, orelha: orelha, raioTopo: 0)

        let deslocamento = exp ? 0 : modelo.deslocamentoCentroPilula

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if exp {
                    NotchAberto(modelo: modelo)
                        .environment(\.animarPonto, modelo.politica.animarPonto(expandido: exp))
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.10))))
                } else {
                    Pilula(modelo: modelo)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
            }
            .frame(width: largura, height: altura, alignment: .top)
            .padding(.horizontal, orelha)
            .background(fundo(exp))
            .clipShape(forma)
            .overlay(forma.stroke(Color.white.opacity(exp ? 0.07 : 0), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(exp ? 0.7 : 0.45), radius: exp ? 30 : 15, x: 0, y: exp ? 24 : 10)
            .offset(x: deslocamento)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Medição do painel (invisível, fora do layout), para animar a altura certa e para o hover.
        .background(alignment: .top) {
            NotchAberto(modelo: modelo)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChaveAlturaPainel.self, value: g.size.height)
                })
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onPreferenceChange(ChaveAlturaPainel.self) { h in
            if h > 0 { modelo.tamanhoPainel = CGSize(width: Tema.larguraNotchAberto, height: h) }
        }
        .animation(Self.animacao, value: exp)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func fundo(_ exp: Bool) -> some View {
        ZStack {
            FundoBlur().opacity(exp ? 1 : 0)
            GeometryReader { g in
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: min(60 / max(g.size.height, 1), 1)),
                    .init(color: Color(red: 6 / 255, green: 6 / 255, blue: 9 / 255, opacity: exp ? 0.94 : 1), location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
