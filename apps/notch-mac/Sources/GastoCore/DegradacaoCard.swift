import Foundation

/// Prioridade de uma peça de conteúdo de um card. Quanto menor o valor, mais cedo
/// a peça fica: o que é essencial aparece com pouco espaço; o resto só quando cabe.
public enum PrioridadeCard: Int, CaseIterable, Comparable, Sendable {
    case essencial = 0
    case secundaria = 1
    case detalhe = 2

    public static func < (lhs: PrioridadeCard, rhs: PrioridadeCard) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Espaço em pontos. Serve tanto para o espaço disponível no card quanto para o
/// mínimo que uma peça precisa para aparecer.
public struct EspacoCard: Equatable, Sendable {
    public let largura: Double
    public let altura: Double

    public init(largura: Double, altura: Double) {
        self.largura = largura
        self.altura = altura
    }

    public static let zero = EspacoCard(largura: 0, altura: 0)

    /// A peça cabe quando o card tem pelo menos a largura e a altura pedidas.
    public func cabe(_ minimo: EspacoCard) -> Bool {
        largura >= minimo.largura && altura >= minimo.altura
    }
}

/// Uma peça de conteúdo do card e o espaço mínimo para ela aparecer.
public struct PecaCard: Equatable, Sendable {
    public let id: String
    public let prioridade: PrioridadeCard
    public let minimo: EspacoCard

    public init(id: String, prioridade: PrioridadeCard, minimo: EspacoCard = .zero) {
        self.id = id
        self.prioridade = prioridade
        self.minimo = minimo
    }
}

/// Decide o que um card mostra a partir do espaço **do próprio card**.
///
/// A regra é uma só: as peças são ordenadas por prioridade e o card mostra um
/// prefixo delas. Quando uma peça não cabe, as menos essenciais também saem;
/// voltar a ter espaço faz o prefixo crescer de novo. A peça mais essencial fica
/// mesmo abaixo do mínimo, para o card nunca ficar vazio.
///
/// Nada aqui olha a largura da janela: o chamador passa o tamanho medido do card.
public enum DegradacaoCard {
    public static func visiveis(_ pecas: [PecaCard], em espaco: EspacoCard) -> [String] {
        let ordenadas = pecas.enumerated().sorted { a, b in
            if a.element.prioridade != b.element.prioridade {
                return a.element.prioridade < b.element.prioridade
            }
            return a.offset < b.offset
        }.map { $0.element }

        guard let primeira = ordenadas.first else { return [] }
        var saida = [primeira.id]
        for peca in ordenadas.dropFirst() {
            guard espaco.cabe(peca.minimo) else { break }
            saida.append(peca.id)
        }
        return saida
    }

    /// Atalho para cards cujo conteúdo só depende da altura (linhas de lane).
    public static func visiveis(_ pecas: [PecaCard], altura: Double) -> [String] {
        visiveis(pecas, em: EspacoCard(largura: .greatestFiniteMagnitude, altura: altura))
    }

    /// `true` quando alguma peça do conteúdo completo ficou de fora.
    public static func degradado(_ pecas: [PecaCard], em espaco: EspacoCard) -> Bool {
        visiveis(pecas, em: espaco).count < pecas.count
    }
}
