import AppKit
import SwiftUI
import GastoCore

/// Destino dos itens que o painel trata. Copiar, colar e fechar vão para a janela
/// (target nil): o campo com foco é quem executa.
@MainActor
final class AcoesMenu: NSObject, NSMenuItemValidation {
    var aoAbrirPainel: () -> Void = {}
    var aoAtualizar: () -> Void = {}
    var aoAjustes: () -> Void = {}
    var aoSair: () -> Void = {}
    var aoBuscar: () -> Void = {}

    @objc func abrirPainel(_ sender: Any?) { aoAbrirPainel() }
    @objc func atualizar(_ sender: Any?) { aoAtualizar() }
    @objc func ajustes(_ sender: Any?) { aoAjustes() }
    @objc func sair(_ sender: Any?) { aoSair() }
    @objc func buscar(_ sender: Any?) { aoBuscar() }
    @objc func aumentarFonte(_ sender: Any?) { EscalaTextoApp.compartilhada.aumentar() }
    @objc func diminuirFonte(_ sender: Any?) { EscalaTextoApp.compartilhada.diminuir() }
    @objc func fontePadrao(_ sender: Any?) { EscalaTextoApp.compartilhada.redefinir() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(aumentarFonte(_:)):
            return EscalaTexto.podeAumentar(EscalaTextoApp.compartilhada.fator)
        case #selector(diminuirFonte(_:)):
            return EscalaTexto.podeDiminuir(EscalaTextoApp.compartilhada.fator)
        default:
            return true
        }
    }

}

/// Instala `NSApp.mainMenu`. Sem isto o AppKit não entrega ⌘C, ⌘V, ⌘Z, ⌘W nem ⌘+.
@MainActor
enum MenuPrincipalApp {
    private static var monitor: Any?

    static func instalar(acoes: AcoesMenu) {
        let principal = NSMenu()
        for submenu in CatalogoMenu.submenus {
            let item = NSMenuItem()
            let menu = NSMenu(title: submenu.titulo)
            for entrada in submenu.itens where !entrada.oculto {
                menu.addItem(itemMenu(entrada, acoes: acoes))
            }
            item.submenu = menu
            principal.addItem(item)
            if submenu.titulo == "Janela" { NSApp.windowsMenu = menu }
        }
        NSApp.mainMenu = principal
        AtalhosTeclado.acoes = acoes
        instalarOcultos()
    }

    /// Com `LSUIElement`, o menu instalado no arranque só aparece depois de virar app normal.
    static func reexibir() {
        guard let menu = NSApp.mainMenu else { return }
        NSApp.mainMenu = nil
        NSApp.mainMenu = menu
    }

    /// O menu sozinho não entrega ⌘C no campo do SwiftUI, e ⌘= não é o item ⌘+.
    private static func instalarOcultos() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let tratado = MainActor.assumeIsolated { AtalhosTeclado.tentar(event) }
            return tratado ? nil : event
        }
    }

    private static func itemMenu(_ entrada: ItemMenu, acoes: AcoesMenu) -> NSMenuItem {
        if entrada.servicos {
            let item = NSMenuItem(title: entrada.titulo, action: nil, keyEquivalent: "")
            let servicos = NSMenu(title: entrada.titulo)
            item.submenu = servicos
            NSApp.servicesMenu = servicos
            return item
        }
        guard let acao = entrada.acao else { return .separator() }
        let item = NSMenuItem(title: entrada.titulo, action: seletor(acao), keyEquivalent: "")
        item.target = alvo(acao, acoes: acoes)
        if let atalho = entrada.atalho { aplicar(atalho, em: item) }
        return item
    }

    private static func aplicar(_ atalho: AtalhoMenu, em item: NSMenuItem) {
        var tecla = atalho.tecla
        var mods = atalho.modificadores
        if mods.contains(.shift), tecla.count == 1, let c = tecla.first, c.isLetter, c.isLowercase {
            tecla = tecla.uppercased()
            mods.remove(.shift)
        }
        item.keyEquivalent = tecla
        var mask = mascara(mods)
        // "+" só existe com Shift. Sem ele no mask, ⌘+ não dispara.
        if tecla == "+" { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    nonisolated private static func mascara(_ mods: ModificadoresAtalho) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if mods.contains(.command) { mask.insert(.command) }
        if mods.contains(.shift) { mask.insert(.shift) }
        if mods.contains(.option) { mask.insert(.option) }
        if mods.contains(.control) { mask.insert(.control) }
        return mask
    }

    private static func alvo(_ acao: AcaoMenu, acoes: AcoesMenu) -> AnyObject? {
        switch acao {
        case .ajustes, .sair, .abrirPainel, .atualizar, .buscar, .aumentarFonte, .diminuirFonte, .fontePadrao:
            return acoes
        case .sobre, .ocultar, .ocultarOutros, .mostrarTudo, .emoji, .trazerFrente:
            return NSApp
        case .fecharJanela, .desfazer, .refazer, .recortar, .copiar, .colar, .colarEstilo, .apagar,
             .selecionarTudo, .telaCheia, .minimizar, .zoomJanela:
            return nil
        }
    }

    private static func seletor(_ acao: AcaoMenu) -> Selector {
        switch acao {
        case .sobre: return #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        case .ajustes: return #selector(AcoesMenu.ajustes(_:))
        case .ocultar: return #selector(NSApplication.hide(_:))
        case .ocultarOutros: return #selector(NSApplication.hideOtherApplications(_:))
        case .mostrarTudo: return #selector(NSApplication.unhideAllApplications(_:))
        case .sair: return #selector(AcoesMenu.sair(_:))
        case .fecharJanela: return #selector(NSWindow.performClose(_:))
        case .abrirPainel: return #selector(AcoesMenu.abrirPainel(_:))
        case .atualizar: return #selector(AcoesMenu.atualizar(_:))
        case .buscar: return #selector(AcoesMenu.buscar(_:))
        case .desfazer: return Selector(("undo:"))
        case .refazer: return Selector(("redo:"))
        case .recortar: return #selector(NSText.cut(_:))
        case .copiar: return #selector(NSText.copy(_:))
        case .colar: return #selector(NSText.paste(_:))
        case .colarEstilo: return #selector(NSTextView.pasteAsPlainText(_:))
        case .apagar: return #selector(NSText.delete(_:))
        case .selecionarTudo: return #selector(NSText.selectAll(_:))
        case .emoji: return #selector(NSApplication.orderFrontCharacterPalette(_:))
        case .aumentarFonte: return #selector(AcoesMenu.aumentarFonte(_:))
        case .diminuirFonte: return #selector(AcoesMenu.diminuirFonte(_:))
        case .fontePadrao: return #selector(AcoesMenu.fontePadrao(_:))
        case .telaCheia: return #selector(NSWindow.toggleFullScreen(_:))
        case .minimizar: return #selector(NSWindow.performMiniaturize(_:))
        case .zoomJanela: return #selector(NSWindow.performZoom(_:))
        case .trazerFrente: return #selector(NSApplication.arrangeInFront(_:))
        }
    }
}

/// Fator vivo da interface. O painel observa e cada `fontePainel` lê o ambiente.
@MainActor
final class EscalaTextoApp: ObservableObject {
    static let compartilhada = EscalaTextoApp()
    @Published private(set) var fator: Double
    private let chave = "escalaTexto"

    private init() {
        let salvo = UserDefaults.standard.object(forKey: chave) as? Double
        fator = salvo.map { EscalaTexto.normalizar($0) } ?? EscalaTexto.padrao
    }

    func aumentar() { definir(EscalaTexto.aumentar(fator)) }
    func diminuir() { definir(EscalaTexto.diminuir(fator)) }
    func redefinir() { definir(EscalaTexto.padrao) }

    private func definir(_ novo: Double) {
        guard novo != fator else { return }
        fator = novo
        UserDefaults.standard.set(novo, forKey: chave)
    }
}

private struct FatorTextoKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var fatorTexto: CGFloat {
        get { self[FatorTextoKey.self] }
        set { self[FatorTextoKey.self] = newValue }
    }
}

/// Envolve uma janela para o ⌘+ / ⌘− redesenhar o texto sem recriar os campos.
struct ComEscalaTexto<Conteudo: View>: View {
    @ObservedObject private var escala = EscalaTextoApp.compartilhada
    private var conteudo: Conteudo

    init(@ViewBuilder conteudo: () -> Conteudo) {
        self.conteudo = conteudo()
    }

    var body: some View {
        conteudo
            .environment(\.fatorTexto, CGFloat(escala.fator))
            .environment(\.dynamicTypeSize, TipoDinamico.para(escala.fator))
    }
}

/// Os textos com `.body` e `.caption` seguem o tipo dinâmico. `fontePainel` usa o fator direto.
private enum TipoDinamico {
    static func para(_ fator: Double) -> DynamicTypeSize {
        let tipos: [DynamicTypeSize] = [
            .small, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2,
        ]
        let normal = EscalaTexto.normalizar(fator)
        let indice = EscalaTexto.graus.firstIndex(of: normal) ?? 1
        return tipos[indice]
    }
}

private struct FontePainel: ViewModifier {
    @Environment(\.fatorTexto) private var fator
    var tamanho: CGFloat
    var peso: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: tamanho * fator, weight: peso, design: .rounded))
    }
}

extension View {
    /// Tamanho de painel. Lê a escala do ambiente, então ⌘+ atualiza o texto que já está na tela.
    func fontePainel(_ tamanho: CGFloat, _ peso: Font.Weight = .regular) -> some View {
        modifier(FontePainel(tamanho: tamanho, peso: peso))
    }
}

/// Atalhos que o menu não consegue entregar ao campo. O monitor e a janela chamam isto.
@MainActor
enum AtalhosTeclado {
    static weak var acoes: AcoesMenu?

    static func tentar(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let acoes else { return false }
        let tecla = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch tecla {
            case "c": return enviar(#selector(NSText.copy(_:)))
            case "v": return enviar(#selector(NSText.paste(_:)))
            case "x": return enviar(#selector(NSText.cut(_:)))
            case "a": return enviar(#selector(NSText.selectAll(_:)))
            case "z": return enviar(Selector(("undo:")))
            case "=", "+": acoes.aumentarFonte(nil); return true
            case "-": acoes.diminuirFonte(nil); return true
            case "0": acoes.fontePadrao(nil); return true
            case "w": return enviar(#selector(NSWindow.performClose(_:)))
            case "q": acoes.sair(nil); return true
            case ",": acoes.ajustes(nil); return true
            case "f": acoes.buscar(nil); return true
            case "p": acoes.abrirPainel(nil); return true
            case "r": acoes.atualizar(nil); return true
            case "m": return enviar(#selector(NSWindow.performMiniaturize(_:)))
            case "h": return enviar(#selector(NSApplication.hide(_:)))
            default: return false
            }
        }
        if mods == [.command, .shift] {
            switch tecla {
            case "z": return enviar(Selector(("redo:")))
            case "=", "+": acoes.aumentarFonte(nil); return true
            default: return false
            }
        }
        if mods == [.command, .option], tecla == "h" {
            return enviar(#selector(NSApplication.hideOtherApplications(_:)))
        }
        if mods == [.command, .option, .shift], tecla == "v" {
            return enviar(#selector(NSTextView.pasteAsPlainText(_:)))
        }
        if mods == [.command, .control], tecla == "f" {
            return enviar(#selector(NSWindow.toggleFullScreen(_:)))
        }
        if mods == [.command, .control], tecla == " " {
            return enviar(#selector(NSApplication.orderFrontCharacterPalette(_:)))
        }
        return false
    }

    private static func enviar(_ acao: Selector) -> Bool {
        NSApp.sendAction(acao, to: nil, from: nil)
    }
}

/// Se o item do menu estiver desligado, o ⌘C ainda chega no campo com foco.
final class JanelaComAtalhos: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return MainActor.assumeIsolated { AtalhosTeclado.tentar(event) }
    }
}
