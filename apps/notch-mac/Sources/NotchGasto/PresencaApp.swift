import AppKit
import GastoCore

/// FRA-553: aplica `PoliticaDock` no `NSApplication`.
/// `.regular` mostra o TuttiDash no Dock e no Cmd-Tab; `.accessory` deixa só a pílula.
@MainActor
enum PresencaApp {
    static func aplicar(_ politica: PoliticaAtivacao) {
        switch politica {
        case .regular:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func cumprir(_ destino: DestinoProcesso) {
        switch destino {
        case .permanecer:
            break
        case .encerrar:
            NSApp.terminate(nil)
        }
    }

    /// «Sair» da pílula, do menu e do botão do painel.
    static func sair() {
        cumprir(PoliticaDock.aoSair())
    }
}
