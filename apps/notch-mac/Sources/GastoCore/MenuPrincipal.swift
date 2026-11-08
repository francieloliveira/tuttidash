import Foundation

/// Tecla de um item do menu principal. O app traduz isto para `NSMenuItem`
/// porque o processo sobe sem storyboard e, sem menu Editar, ⌘C e ⌘V não existem.
public struct AtalhoMenu: Equatable, Sendable {
    public var tecla: String
    public var modificadores: ModificadoresAtalho

    public init(tecla: String, modificadores: ModificadoresAtalho) {
        self.tecla = tecla
        self.modificadores = modificadores
    }
}

public struct ModificadoresAtalho: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ModificadoresAtalho(rawValue: 1 << 0)
    public static let shift = ModificadoresAtalho(rawValue: 1 << 1)
    public static let option = ModificadoresAtalho(rawValue: 1 << 2)
    public static let control = ModificadoresAtalho(rawValue: 1 << 3)
}

public enum AcaoMenu: Equatable, Sendable {
    case sobre
    case ajustes
    case ocultar
    case ocultarOutros
    case mostrarTudo
    case sair
    case fecharJanela
    case abrirPainel
    case atualizar
    case buscar
    case desfazer
    case refazer
    case recortar
    case copiar
    case colar
    case colarEstilo
    case apagar
    case selecionarTudo
    case emoji
    case aumentarFonte
    case diminuirFonte
    case fontePadrao
    case telaCheia
    case minimizar
    case zoomJanela
    case trazerFrente
}

public struct ItemMenu: Equatable, Sendable {
    public var titulo: String
    public var acao: AcaoMenu?
    public var atalho: AtalhoMenu?
    /// ⌘= não cabe no mesmo item que ⌘+. Fica fora da lista visível e o app escuta a tecla.
    public var oculto: Bool
    public var servicos: Bool

    public init(titulo: String, acao: AcaoMenu? = nil, atalho: AtalhoMenu? = nil, oculto: Bool = false, servicos: Bool = false) {
        self.titulo = titulo
        self.acao = acao
        self.atalho = atalho
        self.oculto = oculto
        self.servicos = servicos
    }
}

public struct SubmenuMenu: Equatable, Sendable {
    public var titulo: String
    public var itens: [ItemMenu]

    public init(titulo: String, itens: [ItemMenu]) {
        self.titulo = titulo
        self.itens = itens
    }
}

/// Menu que o macOS mostraria se o app tivesse um MainMenu.xib.
public enum CatalogoMenu {
    public static let submenus: [SubmenuMenu] = [
        SubmenuMenu(titulo: "TuttiDash", itens: [
            comando("Sobre o TuttiDash", .sobre),
            comando("Ajustes…", .ajustes, ",", .command),
            separador(),
            ItemMenu(titulo: "Serviços", servicos: true),
            separador(),
            comando("Ocultar TuttiDash", .ocultar, "h", .command),
            comando("Ocultar Outros", .ocultarOutros, "h", [.command, .option]),
            comando("Mostrar Tudo", .mostrarTudo),
            separador(),
            comando("Sair", .sair, "q", .command),
        ]),
        SubmenuMenu(titulo: "Arquivo", itens: [
            comando("Fechar", .fecharJanela, "w", .command),
            separador(),
            comando("Abrir painel", .abrirPainel, "p", .command),
            comando("Atualizar agora", .atualizar, "r", .command),
            comando("Buscar", .buscar, "f", .command),
        ]),
        SubmenuMenu(titulo: "Editar", itens: [
            comando("Desfazer", .desfazer, "z", .command),
            comando("Refazer", .refazer, "z", [.command, .shift]),
            separador(),
            comando("Recortar", .recortar, "x", .command),
            comando("Copiar", .copiar, "c", .command),
            comando("Colar", .colar, "v", .command),
            comando("Colar e Manter o Estilo", .colarEstilo, "v", [.command, .option, .shift]),
            comando("Apagar", .apagar),
            comando("Selecionar Tudo", .selecionarTudo, "a", .command),
            separador(),
            comando("Emoji e Símbolos", .emoji, " ", [.command, .control]),
        ]),
        SubmenuMenu(titulo: "Visualizar", itens: [
            comando("Aumentar tamanho da fonte", .aumentarFonte, "+", .command),
            comando("Aumentar tamanho da fonte", .aumentarFonte, "=", .command, oculto: true),
            comando("Diminuir tamanho da fonte", .diminuirFonte, "-", .command),
            comando("Tamanho padrão", .fontePadrao, "0", .command),
            separador(),
            comando("Entrar em Tela Cheia", .telaCheia, "f", [.command, .control]),
        ]),
        SubmenuMenu(titulo: "Janela", itens: [
            comando("Minimizar", .minimizar, "m", .command),
            comando("Zoom", .zoomJanela),
            separador(),
            comando("Trazer Todas para a Frente", .trazerFrente),
        ]),
    ]

    private static func comando(_ titulo: String, _ acao: AcaoMenu, _ tecla: String, _ mods: ModificadoresAtalho, oculto: Bool = false) -> ItemMenu {
        ItemMenu(titulo: titulo, acao: acao, atalho: AtalhoMenu(tecla: tecla, modificadores: mods), oculto: oculto)
    }

    private static func comando(_ titulo: String, _ acao: AcaoMenu) -> ItemMenu {
        ItemMenu(titulo: titulo, acao: acao)
    }

    private static func separador() -> ItemMenu {
        ItemMenu(titulo: "")
    }
}

/// Graus do ⌘+ / ⌘−. O painel multiplica o tamanho de cada fonte por este fator.
public enum EscalaTexto {
    public static let graus: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    public static let padrao: Double = 1
    public static var minimo: Double { graus[0] }
    public static var maximo: Double { graus[graus.count - 1] }

    public static func aumentar(_ fator: Double) -> Double {
        graus.first { $0 > fator + 0.001 } ?? maximo
    }

    public static func diminuir(_ fator: Double) -> Double {
        graus.last { $0 < fator - 0.001 } ?? minimo
    }

    public static func podeAumentar(_ fator: Double) -> Bool {
        aumentar(fator) > fator + 0.001
    }

    public static func podeDiminuir(_ fator: Double) -> Bool {
        diminuir(fator) < fator - 0.001
    }

    /// Valor gravado fora da lista volta para o grau mais próximo.
    public static func normalizar(_ fator: Double) -> Double {
        graus.min { abs($0 - fator) < abs($1 - fator) } ?? padrao
    }

    public static func tamanho(_ base: Double, fator: Double) -> Double {
        base * fator
    }
}
