import Foundation

/// FRA-650. Papel de um bloco no mapa de uma largura do dashboard.
///
/// Cada largura (celular, tablet, tela larga) tem o próprio mapa: o que fica na
/// fileira, o que empilha e o que some. O papel é o desfecho que o mapa dá ao
/// bloco — não é uma escolha do bloco nem de outra largura.
public enum PapelBlocoMapa: String, Equatable, Sendable, CaseIterable {
    /// Fica na fileira, ao lado do bloco anterior, sem trocar de eixo.
    case permanece
    /// Troca de eixo: começa a fileira de baixo em vez de apertar o vizinho.
    case empilha
    /// Some do mapa nesta largura: não ocupa espaço nenhum.
    case some
}

/// FRA-650. O mapa de uma largura: a grade, o que some e o span de cada bloco.
///
/// O mapa é fechado em si: a tabela de spans e a lista de ocultos desta largura
/// não leem nada da outra largura. Só a tela larga aceita a escolha gravada por
/// pessoa (FRA-653); celular e tablet usam a tabela fixa do próprio mapa.
public struct MapaLargura: Equatable, Sendable {
    /// Largura a que este mapa pertence.
    public let tela: ClasseTelaDashboard
    /// Colunas da grade desta largura. O celular empilha: grade de uma coluna.
    public let colunas: Int
    /// Blocos que somem nesta largura.
    public let ocultos: Set<BlocoPainel>
    /// Span fixo de cada bloco nesta largura, em células da grade. O celular
    /// declara a tabela vazia: todo bloco visível ocupa a coluna cheia (span 1).
    public let spans: [BlocoPainel: Int]
    /// Só a tela larga lê a escolha gravada por pessoa (FRA-653).
    public let usaTamanhosGravados: Bool

    public init(tela: ClasseTelaDashboard, colunas: Int, ocultos: Set<BlocoPainel>,
                spans: [BlocoPainel: Int], usaTamanhosGravados: Bool) {
        self.tela = tela
        self.colunas = colunas
        self.ocultos = ocultos
        self.spans = spans
        self.usaTamanhosGravados = usaTamanhosGravados
    }

    /// Declaração de um mapa do app. Grade sem coluna ou span fora dela é erro de
    /// cadastro e para na hora, como em `SpanGrade.declarado`: um mapa torto
    /// forçaria o layout a comprimir um bloco ou a vazar da grade.
    static func declarado(tela: ClasseTelaDashboard, colunas: Int,
                          ocultos: Set<BlocoPainel>, spans: [BlocoPainel: Int],
                          usaTamanhosGravados: Bool) -> MapaLargura {
        let mapa = MapaLargura(tela: tela, colunas: colunas, ocultos: ocultos,
                               spans: spans, usaTamanhosGravados: usaTamanhosGravados)
        guard mapa.colunas >= 1,
              mapa.spans.allSatisfy({ $0.value >= 1 && $0.value <= mapa.colunas })
        else {
            preconditionFailure("mapa inválido para \(tela.rawValue)")
        }
        return mapa
    }

    /// O bloco some nesta largura?
    public func oculto(_ bloco: BlocoPainel) -> Bool { ocultos.contains(bloco) }

    /// Papel declarado do bloco nesta largura. O bloco oculto some; os demais
    /// ficam no fluxo da grade, e o papel final (`permanece` ou `empilha`) sai
    /// da montagem das fileiras, nunca da declaração.
    public func papel(_ bloco: BlocoPainel) -> PapelBlocoMapa {
        oculto(bloco) ? .some : .permanece
    }

    /// Span do bloco nesta largura, em células. Na tela larga é a escolha gravada
    /// por pessoa, presa à faixa do card e com o máximo declarado como padrão
    /// (FRA-653). Nas outras larguras é a tabela fixa do mapa: a escolha de
    /// desktop é recebida mas não entra na conta.
    public func span(_ bloco: BlocoPainel, tamanhos: TamanhosCards = TamanhosCards()) -> Int {
        if usaTamanhosGravados {
            return tamanhos.span(bloco, em: tela)
        }
        return spans[bloco] ?? 1
    }
}

/// FRA-650. Onde um bloco caiu no mapa da largura, em células da grade.
///
/// `fileira`, `coluna` e `span` são o contrato com a tela: o bloco ocupa
/// exatamente esse retângulo da grade, com o span inteiro, nunca comprimido.
public struct QuadroMapaLargura: Equatable, Sendable {
    public let bloco: BlocoPainel
    public let papel: PapelBlocoMapa
    /// Fileira da grade (0 no topo). Uma fileira só nasce quando um bloco troca
    /// de eixo; ela nunca nasce por causa de um bloco que sumiu.
    public let fileira: Int
    /// Coluna inicial, em células da grade desta largura.
    public let coluna: Int
    /// Largura em células: o span inteiro do bloco.
    public let span: Int

    public init(bloco: BlocoPainel, papel: PapelBlocoMapa,
                fileira: Int, coluna: Int, span: Int) {
        self.bloco = bloco
        self.papel = papel
        self.fileira = fileira
        self.coluna = coluna
        self.span = span
    }

    /// Primeira célula depois do bloco.
    public var fim: Int { coluna + span }
}

/// FRA-650. Os três mapas de largura do dashboard: celular, tablet e tela larga.
///
/// Cada largura define o que permanece, o que empilha e o que some, e a troca de
/// largura troca o mapa inteiro — nada de uma largura vaza para a outra. O que
/// some deixa de ocupar espaço: não ganha quadro, nem célula, nem fileira.
public enum MapasTresLarguras {
    /// Grade da tela larga (desktop), a mesma declarada pelos cards (FRA-651).
    public static let colunasDesktop = 12
    /// Grade do tablet: metade da do desktop.
    public static let colunasTablet = 6
    /// O celular empilha: uma coluna só.
    public static let colunasCelular = 1

    /// Tela larga: nada some; o que não cabe na fileira empilha. O span é a
    /// escolha gravada por pessoa (FRA-653); sem escolha, o máximo declarado
    /// pelo card (FRA-651).
    public static let desktop = MapaLargura.declarado(
        tela: .telaLarga, colunas: colunasDesktop, ocultos: [],
        spans: [.alertas: 12, .lanes: 6, .testes: 4, .builds: 4,
                .dispatcher: 4, .entregas: 4, .custos: 12, .log: 12],
        usaTamanhosGravados: true)

    /// Tablet: o log some (bloco auxiliar de tela larga); os demais usam a grade
    /// de 6 colunas com span fixo — metade do máximo do desktop, declarado aqui
    /// e sem ler a escolha da pessoa.
    public static let tablet = MapaLargura.declarado(
        tela: .tablet, colunas: colunasTablet, ocultos: [.log],
        spans: [.alertas: 6, .lanes: 3, .testes: 2, .builds: 2,
                .dispatcher: 2, .entregas: 2, .custos: 6, .log: 6],
        usaTamanhosGravados: false)

    /// Celular: pilha de uma coluna, na ordem recebida. Log e custos somem: são
    /// blocos de tela larga — o log é auxiliar e a tabela de custos pede largura.
    /// Os demais empilham um embaixo do outro.
    public static let celular = MapaLargura.declarado(
        tela: .celular, colunas: colunasCelular, ocultos: [.log, .custos],
        spans: [:], usaTamanhosGravados: false)

    /// O mapa da largura.
    public static func mapa(em tela: ClasseTelaDashboard) -> MapaLargura {
        switch tela {
        case .celular: return celular
        case .tablet: return tablet
        case .telaLarga: return desktop
        }
    }

    /// Aplica o mapa da largura aos blocos, na ordem recebida.
    ///
    /// O bloco que some não ganha quadro nenhum: não ocupa célula nem empurra
    /// fileira. O bloco que não cabe na fileira empilha: desce com o span
    /// inteiro, sem comprimir o vizinho. Na tela larga o span vem da escolha da
    /// pessoa; nas outras larguras, da tabela fixa do mapa.
    public static func molduras(_ blocos: [BlocoPainel],
                                em tela: ClasseTelaDashboard,
                                tamanhos: TamanhosCards = TamanhosCards()) -> [QuadroMapaLargura] {
        molduras(blocos, mapa: mapa(em: tela), tamanhos: tamanhos)
    }

    /// Aplica um mapa específico. Existe para quem já tem o mapa na mão (testes e
    /// a futura montagem da tela) e para deixar explícito que a largura inteira
    /// troca de uma vez: quem chama não mistura peças de dois mapas.
    public static func molduras(_ blocos: [BlocoPainel],
                                mapa: MapaLargura,
                                tamanhos: TamanhosCards = TamanhosCards()) -> [QuadroMapaLargura] {
        var quadros: [QuadroMapaLargura] = []
        var fileira = 0
        var coluna = 0
        for bloco in blocos {
            guard !mapa.oculto(bloco) else { continue }
            let span = mapa.span(bloco, tamanhos: tamanhos)
            if coluna > 0, coluna + span > mapa.colunas {
                fileira += 1
                coluna = 0
            }
            let papel: PapelBlocoMapa = coluna == 0 && fileira > 0 ? .empilha : .permanece
            quadros.append(QuadroMapaLargura(bloco: bloco, papel: papel,
                                             fileira: fileira, coluna: coluna, span: span))
            coluna += span
        }
        return quadros
    }
}
