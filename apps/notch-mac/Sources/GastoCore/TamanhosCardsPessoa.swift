import Foundation

/// FRA-653. Em que tipo de tela o dashboard está desenhado.
///
/// Celular e tablet têm mapas próprios de layout; a escolha de tamanho dos cards é
/// uma preferência de desktop. Por isso só a tela larga aplica o que a pessoa gravou.
public enum ClasseTelaDashboard: String, Equatable, Sendable, CaseIterable {
    case celular
    case tablet
    case telaLarga

    /// Abaixo disso é celular. O tablet começa em 600 pt, como nas larguras mínimas
    /// usuais de tablet em retrato.
    public static let larguraTablet: Double = 600
    /// A partir disso a tela é larga. 1024 pt é o primeiro desktop; o painel do app
    /// só abre a partir de 1280, então na janela real ele sempre cai aqui.
    public static let larguraTelaLarga: Double = 1024

    public init(largura: Double) {
        if largura >= Self.larguraTelaLarga {
            self = .telaLarga
        } else if largura >= Self.larguraTablet {
            self = .tablet
        } else {
            self = .celular
        }
    }

    /// Só a tela larga lê o que a pessoa gravou. Celular e tablet ignoram.
    public var usaTamanhosGravados: Bool { self == .telaLarga }
}

/// FRA-653. Os tamanhos de card que uma pessoa escolheu, um span por bloco.
///
/// O valor fica preso à faixa que o próprio card declara em `SpanGrade`. Sem escolha
/// gravada, vale o máximo declarado; assim o dashboard abre no layout completo.
public struct TamanhosCards: Equatable, Sendable {
    /// Guardado pelo rawValue para não depender de `BlocoPainel` ser `Hashable`.
    fileprivate var porBloco: [String: Int]

    public init() {
        self.porBloco = [:]
    }

    /// Span efetivo do card nesta tela. Em celular e tablet a escolha gravada não
    /// entra: devolve o padrão, como se a pessoa nunca tivesse ajustado o desktop.
    public func span(_ bloco: BlocoPainel, em tela: ClasseTelaDashboard) -> Int {
        guard tela.usaTamanhosGravados,
              let escolhido = porBloco[bloco.rawValue]
        else { return bloco.span.maximo }
        return bloco.span.efetivo(escolhido)
    }

    /// Escolha gravada para o card, já presa à faixa declarada. `nil` quando a
    /// pessoa nunca ajustou esse card.
    public func escolhido(_ bloco: BlocoPainel) -> Int? {
        porBloco[bloco.rawValue].map { bloco.span.efetivo($0) }
    }

    /// Grava a escolha de um card. Um valor fora da faixa encosta no mínimo ou no
    /// máximo; ele nunca vira um span inválido.
    public mutating func escolher(_ span: Int, para bloco: BlocoPainel) {
        porBloco[bloco.rawValue] = bloco.span.efetivo(span)
    }

    /// Todos os cards, na ordem do painel, com o span efetivo desta tela.
    public func spans(em tela: ClasseTelaDashboard) -> [(bloco: BlocoPainel, span: Int)] {
        BlocoPainel.allCases.map { (bloco: $0, span: span($0, em: tela)) }
    }

    public var vazio: Bool { porBloco.isEmpty }
}

/// FRA-653. Onde os tamanhos ficam gravados, por pessoa.
///
/// Cada pessoa tem a própria chave no `UserDefaults` (que já é separado por conta do
/// macOS): gravar uma não lê nem escreve a chave da outra. Nada vai para o
/// `config.json` compartilhado, para o worktree ou para as lanes.
public struct ArmazemTamanhosCards {
    /// Prefixo da chave de uma pessoa no `UserDefaults`.
    public static let prefixoChave = "dashboard.tamanhos."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Chave da pessoa. `nil` para um identificador vazio: sem pessoa não há o que
    /// associar, e o chamador não deve gravar num balde comum.
    public static func chave(pessoa: String) -> String? {
        let limpa = pessoa.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpa.isEmpty else { return nil }
        return prefixoChave + limpa
    }

    /// Lê o que a pessoa gravou, sem olhar a tela. Dado corrompido ou bloco que não
    /// existe mais voltam ao padrão, sem derrubar o dashboard.
    public func ler(pessoa: String) -> TamanhosCards {
        guard let chave = Self.chave(pessoa: pessoa),
              let dados = defaults.data(forKey: chave),
              let bruto = try? JSONDecoder().decode([String: Int].self, from: dados)
        else { return TamanhosCards() }

        var tamanhos = TamanhosCards()
        for (nome, valor) in bruto {
            guard let bloco = BlocoPainel(rawValue: nome) else { continue }
            tamanhos.escolher(valor, para: bloco)
        }
        return tamanhos
    }

    /// Lê respeitando a classe de tela: celular e tablet devolvem o padrão e não
    /// aplicam o tamanho que a pessoa gravou para a tela larga.
    public func ler(pessoa: String, em tela: ClasseTelaDashboard) -> TamanhosCards {
        guard tela.usaTamanhosGravados else { return TamanhosCards() }
        return ler(pessoa: pessoa)
    }

    /// Grava só a chave da pessoa. As outras pessoas continuam com o que tinham.
    public func gravar(_ tamanhos: TamanhosCards, para pessoa: String) {
        guard let chave = Self.chave(pessoa: pessoa),
              let dados = try? JSONEncoder().encode(tamanhos.porBloco)
        else { return }
        defaults.set(dados, forKey: chave)
    }

    /// Remove a escolha da pessoa, sem tocar nas demais.
    public func apagar(pessoa: String) {
        guard let chave = Self.chave(pessoa: pessoa) else { return }
        defaults.removeObject(forKey: chave)
    }
}
