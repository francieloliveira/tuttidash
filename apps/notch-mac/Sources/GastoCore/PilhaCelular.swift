import Foundation

/// FRA-654. Faixa de altura de um card na pilha do celular.
///
/// O conteúdo pode pedir mais ou menos espaço, mas o card fica sempre dentro desta
/// faixa. É isso que impede um card grande de empurrar o vizinho e um card pequeno
/// de abrir buraco no meio da pilha.
public struct AlturaPilhaCelular: Equatable, Sendable {
    public let minima: Double
    public let padrao: Double
    public let maxima: Double

    public init(minima: Double, padrao: Double, maxima: Double) {
        self.minima = minima
        self.padrao = padrao
        self.maxima = maxima
    }

    /// Altura final do card: o pedido do conteúdo preso entre mínimo e máximo.
    /// Um pedido inválido (NaN, infinito) volta para a altura padrão do card.
    public func ajustada(_ alturaDoConteudo: Double) -> Double {
        guard alturaDoConteudo.isFinite else { return padrao }
        return min(max(alturaDoConteudo, minima), maxima)
    }
}

/// FRA-654. Onde um card caiu na pilha de uma coluna do celular.
///
/// `y` e `altura` são o contrato com a tela: cada card ocupa exatamente esse quadro,
/// recortando o conteúdo que não couber. O vizinho seguinte começa em `fim` mais o
/// espaçamento da pilha, nunca a partir do tamanho gravado no desktop.
public struct QuadroPilhaCelular: Equatable, Sendable {
    public let bloco: BlocoPainel
    public let ordem: Int
    public let x: Double
    public let y: Double
    public let largura: Double
    public let altura: Double

    public init(bloco: BlocoPainel, ordem: Int, x: Double, y: Double,
                largura: Double, altura: Double) {
        self.bloco = bloco
        self.ordem = ordem
        self.x = x
        self.y = y
        self.largura = largura
        self.altura = altura
    }

    /// Primeiro ponto depois do card (sem o espaçamento).
    public var fim: Double { y + altura }
}

/// FRA-654. A pilha do celular tem uma coluna, ordem fixa e altura de card que não
/// depende do tamanho escolhido na tela larga.
///
/// A ordem é a declarada em `BlocoPainel`: ela não muda com a largura, com o conteúdo
/// nem com o que a pessoa gravou no desktop. O tamanho gravado é aceito na chamada
/// apenas para deixar explícito que ele não entra na conta; a largura é sempre a da
/// coluna e a altura vem da faixa de cada card.
public enum PilhaCelular {
    /// Margem lateral da pilha no celular.
    public static let margem: Double = 16
    /// Espaço entre um card e o seguinte.
    public static let espacamento: Double = 12
    /// Número de colunas da pilha. O celular empilha; não usa a grade de 12 do desktop.
    public static let colunas = 1

    /// Prioridade fixa de cada card no celular. Menor vem primeiro.
    ///
    /// A prioridade é declarada aqui, fora de `SpanGrade` e de `TamanhosCards`: um
    /// span maior no desktop não sobe nem desce card nenhum na tela estreita.
    public static func prioridade(_ bloco: BlocoPainel) -> Int {
        switch bloco {
        case .alertas: return 0
        case .lanes: return 1
        case .testes: return 2
        case .builds: return 3
        case .dispatcher: return 4
        case .entregas: return 5
        case .custos: return 6
        case .log: return 7
        }
    }

    /// Ordena os cards pela prioridade fixa. Empates mantêm a ordem recebida, para a
    /// lista nunca ficar instável entre uma leitura e outra.
    public static func ordem(_ blocos: [BlocoPainel]) -> [BlocoPainel] {
        blocos.enumerated().sorted { a, b in
            let prioridadeA = prioridade(a.element)
            let prioridadeB = prioridade(b.element)
            if prioridadeA != prioridadeB { return prioridadeA < prioridadeB }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Coluna que o card ocupa na pilha. Sempre uma, mesmo que a pessoa tenha
    /// gravado um span largo no desktop.
    public static func span(_ bloco: BlocoPainel, tamanhoGravado: Int? = nil) -> Int {
        _ = bloco
        _ = tamanhoGravado
        return colunas
    }

    /// Faixa de altura do card no celular. A altura padrão acompanha o card do
    /// dashboard; o conteúdo só pode encolher ou crescer dentro da faixa.
    public static func altura(_ bloco: BlocoPainel) -> AlturaPilhaCelular {
        switch bloco {
        case .alertas:
            return AlturaPilhaCelular(minima: 44, padrao: 44, maxima: 44)
        case .lanes:
            return AlturaPilhaCelular(minima: 220, padrao: 320, maxima: 480)
        case .testes:
            return AlturaPilhaCelular(minima: 180, padrao: 254, maxima: 400)
        case .builds:
            return AlturaPilhaCelular(minima: 120, padrao: 164, maxima: 260)
        case .dispatcher:
            return AlturaPilhaCelular(minima: 150, padrao: 224, maxima: 340)
        case .entregas:
            return AlturaPilhaCelular(minima: 130, padrao: 194, maxima: 300)
        case .custos:
            return AlturaPilhaCelular(minima: 160, padrao: 228, maxima: 360)
        case .log:
            return AlturaPilhaCelular(minima: 120, padrao: 180, maxima: 300)
        }
    }

    /// Monta os quadros da pilha, um embaixo do outro.
    ///
    /// `alturaDoConteudo` existe para a tela dizer o que o conteúdo pediu; o valor é
    /// preso à faixa do card. `tamanhosGravados` é recebido só para deixar claro que
    /// a preferência do desktop não altera a pilha: ele não é lido.
    public static func molduras(largura: Double,
                                blocos: [BlocoPainel] = BlocoPainel.allCases,
                                tamanhosGravados: [String: Int] = [:],
                                alturaDoConteudo: ((BlocoPainel) -> Double)? = nil) -> [QuadroPilhaCelular] {
        _ = tamanhosGravados
        let larguraDaColuna = max(0, largura - 2 * margem)
        var y = margem
        return ordem(blocos).enumerated().map { indice, bloco in
            let faixa = altura(bloco)
            let alturaFinal = faixa.ajustada(alturaDoConteudo?(bloco) ?? faixa.padrao)
            let quadro = QuadroPilhaCelular(bloco: bloco, ordem: indice,
                                            x: margem, y: y,
                                            largura: larguraDaColuna,
                                            altura: alturaFinal)
            y = quadro.fim + espacamento
            return quadro
        }
    }
}
