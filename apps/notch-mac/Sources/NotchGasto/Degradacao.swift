import SwiftUI
import GastoCore

/// Entrega ao conteúdo o espaço real do card, medido no próprio card.
/// É o que permite degradar pelo espaço disponível em vez de olhar a janela.
struct ComEspacoDoCard<Conteudo: View>: View {
    private let conteudo: (EspacoCard) -> Conteudo

    init(@ViewBuilder conteudo: @escaping (EspacoCard) -> Conteudo) {
        self.conteudo = conteudo
    }

    var body: some View {
        GeometryReader { g in
            conteudo(EspacoCard(largura: Double(g.size.width), altura: Double(g.size.height)))
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}
