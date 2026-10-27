import Foundation

/// Busca das listas do painel (FRA-563). O termo é preparado uma vez por tela e cada linha só
/// compara: nada de montar texto em minúsculas a cada item, a cada redesenho. Ignora maiúsculas
/// e acentos ("producao" acha "Produção"). Várias palavras: cada uma precisa aparecer em algum
/// campo, em qualquer ordem ("claude 563" acha a lane claude no card FRA-563).
public struct FiltroBusca: Equatable, Sendable {
    public let palavras: [String]

    public init(_ bruto: String) {
        palavras = bruto.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var vazio: Bool { palavras.isEmpty }

    public func casa(_ campos: [String?]) -> Bool {
        guard !palavras.isEmpty else { return true }
        return palavras.allSatisfy { palavra in
            campos.contains { campo in
                guard let campo, !campo.isEmpty else { return false }
                return campo.range(of: palavra, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Lista vazia de palavras devolve a própria lista, sem copiar.
    public func filtrar<T>(_ itens: [T], campos: (T) -> [String?]) -> [T] {
        guard !palavras.isEmpty else { return itens }
        return itens.filter { casa(campos($0)) }
    }
}
