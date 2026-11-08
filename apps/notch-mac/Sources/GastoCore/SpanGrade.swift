import Foundation

/// FRA-651. Quanto um card ocupa na grade do painel, em células inteiras.
///
/// Cada card declara o mínimo e o máximo de span que aceita. O span efetivo nunca
/// sai desse intervalo. Um pedido entre células (2,5) não fecha na grade: é
/// rejeitado, em vez de arredondado para o vizinho.
public struct SpanGrade: Equatable, Sendable {
    /// Menor número de células que o card aceita.
    public let minimo: Int
    /// Maior número de células que o card aceita.
    public let maximo: Int

    /// Declaração do card. Devolve nil quando não fecha: mínimo abaixo de uma célula
    /// ou máximo menor que o mínimo.
    public init?(minimo: Int, maximo: Int) {
        guard minimo >= 1, maximo >= minimo else { return nil }
        self.minimo = minimo
        self.maximo = maximo
    }

    /// Células que o card aceita, do mínimo ao máximo.
    public var faixa: ClosedRange<Int> { minimo...maximo }

    /// Span efetivo de um pedido em células: preso entre o mínimo e o máximo.
    public func efetivo(_ pedido: Int) -> Int {
        min(max(pedido, minimo), maximo)
    }

    /// Encaixa um pedido medido nas células da grade. Um valor entre células (2,5),
    /// negativo, infinito ou não numérico não fecha na grade e devolve nil.
    public func encaixe(_ pedido: Double) -> Int? {
        guard pedido.isFinite, pedido >= 0, pedido < Double(Int.max),
              pedido == pedido.rounded() else { return nil }
        return efetivo(Int(pedido))
    }

    /// O pedido já cai numa célula da faixa declarada?
    public func aceita(_ pedido: Int) -> Bool { faixa.contains(pedido) }

    /// Declaração de um card do app. Os literais de `BlocoPainel` passam por aqui;
    /// um valor inválido é erro de cadastro e para na hora, em vez de virar span torto.
    static func declarado(minimo: Int, maximo: Int) -> SpanGrade {
        guard let span = SpanGrade(minimo: minimo, maximo: maximo) else {
            preconditionFailure("span inválido: \(minimo)...\(maximo)")
        }
        return span
    }
}

/// FRA-651. Cada card do painel declara o mínimo e o máximo de span na grade.
/// O dashboard v2 é montado em 12 colunas: o mínimo é o que o card aceita com o
/// espaço apertado e o máximo, o que ele ocupa com folga. O span efetivo fica
/// nesse intervalo e só anda em células inteiras.
extension BlocoPainel {
    public var span: SpanGrade {
        switch self {
        case .alertas: return SpanGrade.declarado(minimo: 12, maximo: 12)
        case .lanes: return SpanGrade.declarado(minimo: 4, maximo: 6)
        case .testes: return SpanGrade.declarado(minimo: 3, maximo: 4)
        case .builds: return SpanGrade.declarado(minimo: 3, maximo: 4)
        case .dispatcher: return SpanGrade.declarado(minimo: 3, maximo: 4)
        case .entregas: return SpanGrade.declarado(minimo: 3, maximo: 4)
        case .custos: return SpanGrade.declarado(minimo: 8, maximo: 12)
        case .log: return SpanGrade.declarado(minimo: 6, maximo: 12)
        }
    }
}
