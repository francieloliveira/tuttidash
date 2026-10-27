import Foundation

/// Fatia 1-based de uma lista. Página fora do intervalo encosta na última que existe.
/// Custos e Entregas usam o mesmo corte.
public struct ListaPaginada<Item: Sendable>: Sendable {
    public var itens: [Item]
    /// 1-based.
    public var pagina: Int
    public var tamanho: Int
    public var total: Int
    public var paginas: Int
    /// Texto do intervalo quando não há item, ex.: "0 builds".
    public var vazio: String

    public var temAnterior: Bool { pagina > 1 }
    public var temProxima: Bool { pagina < paginas }

    /// "1 a 25 de 80", "3 de 40" ou `vazio`.
    public var intervalo: String {
        guard total > 0, !itens.isEmpty else { return vazio }
        let inicio = (pagina - 1) * tamanho + 1
        let fim = inicio + itens.count - 1
        if inicio == fim { return "\(inicio) de \(total)" }
        return "\(inicio) a \(fim) de \(total)"
    }

    /// Quantos itens a tabela do painel mostra por vez.
    /// Calculado: tipo genérico não pode ter propriedade estática armazenada.
    public static var tamanhoPadrao: Int { 25 }

    public static func cortar(_ lista: [Item], numero: Int, tamanho: Int = tamanhoPadrao,
                              vazio: String) -> ListaPaginada<Item> {
        let tamanho = max(1, tamanho)
        let total = lista.count
        let paginas = total == 0 ? 1 : (total + tamanho - 1) / tamanho
        let pagina = min(max(1, numero), paginas)
        let inicio = (pagina - 1) * tamanho
        let fim = min(inicio + tamanho, total)
        let itens = inicio < fim ? Array(lista[inicio..<fim]) : []
        return ListaPaginada(itens: itens, pagina: pagina, tamanho: tamanho, total: total,
                             paginas: paginas, vazio: vazio)
    }
}

extension ListaPaginada: Equatable where Item: Equatable {}

/// Fechadas hoje, na semana ISO e no registro já carregado em `snapshot.entregas`.
public struct ResumoEntregas: Equatable, Sendable {
    public var hoje: Int
    public var semana: Int
    public var registro: Int

    public static let vazio = ResumoEntregas(hoje: 0, semana: 0, registro: 0)

    /// Sem `quandoData`, o card entra só em `registro`.
    public static func contar(_ entregas: [EntregaPainel], agora: Date,
                              calendario: Calendar = Datas.calendarioISO) -> ResumoEntregas {
        let semanaAtual = Datas.rotuloSemana(agora, calendario: calendario)
        var hoje = 0
        var semana = 0
        for entrega in entregas {
            guard let data = entrega.quandoData else { continue }
            if calendario.isDate(data, inSameDayAs: agora) { hoje += 1 }
            if Datas.rotuloSemana(data, calendario: calendario) == semanaAtual { semana += 1 }
        }
        return ResumoEntregas(hoje: hoje, semana: semana, registro: entregas.count)
    }
}
