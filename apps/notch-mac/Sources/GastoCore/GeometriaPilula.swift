import Foundation

/// Quanto o aviso de limite aparece na pílula recolhida, do mais longo ao mais curto.
public enum NivelAviso: Int, CaseIterable, Comparable, Sendable {
    /// "⚠ grok bot · semana 89%"
    case completo
    /// "⚠ grok bot 89%"
    case semJanela
    /// "⚠ 89%"
    case soPct

    public static func < (a: NivelAviso, b: NivelAviso) -> Bool { a.rawValue < b.rawValue }
    public var proximo: NivelAviso? { NivelAviso(rawValue: rawValue + 1) }
}

/// Regra de largura da pílula (FRA-339): cresce com o conteúdo, simétrica em volta do notch,
/// e nunca corta. Se passar do teto, encurta o aviso.
public struct GeometriaPilula: Equatable, Sendable {
    /// Largura mínima de cada lado (visual de antes).
    public var ladoMinimo: Double
    /// Maior lado aceito antes de encurtar o aviso (não cobrir a barra de menus).
    public var ladoMaximo: Double
    /// Respiro entre o conteúdo e a borda (padding externo + folga).
    public var respiro: Double
    /// Folga mínima sem notch entre os dois lados.
    public var vaoSemNotch: Double

    public init(ladoMinimo: Double = 60, ladoMaximo: Double = 270, respiro: Double = 22, vaoSemNotch: Double = 24) {
        self.ladoMinimo = ladoMinimo
        self.ladoMaximo = ladoMaximo
        self.respiro = respiro
        self.vaoSemNotch = vaoSemNotch
    }

    public static let padrao = GeometriaPilula()

    /// Largura de um lado para caber o conteúdo maior dos dois (simetria mantém o notch centrado).
    public func lado(esquerda: Double, direita: Double) -> Double {
        max(ladoMinimo, (max(esquerda, direita) + respiro).rounded(.up))
    }

    public func largura(temNotch: Bool, larguraNotch: Double, esquerda: Double, direita: Double) -> Double {
        let vao = temNotch ? larguraNotch : vaoSemNotch
        return vao + 2 * lado(esquerda: esquerda, direita: direita)
    }

    /// O conteúdo cabe sem encurtar?
    public func cabe(esquerda: Double, direita: Double) -> Bool {
        lado(esquerda: esquerda, direita: direita) <= ladoMaximo
    }

    /// Próximo nível do aviso dado o que foi medido: encurta enquanto não couber.
    /// Retorna o mesmo nível se coube ou se já está no mais curto (aí a pílula só cresce).
    public func nivelAviso(atual: NivelAviso, esquerda: Double, direita: Double) -> NivelAviso {
        guard !cabe(esquerda: esquerda, direita: direita), let p = atual.proximo else { return atual }
        return p
    }

    /// Escolhe o nível com larguras já conhecidas do lado direito por nível.
    public func melhorNivel(esquerda: Double, direitaPorNivel: [NivelAviso: Double]) -> NivelAviso {
        for n in NivelAviso.allCases {
            if let d = direitaPorNivel[n], cabe(esquerda: esquerda, direita: d) { return n }
        }
        return .soPct
    }
}
