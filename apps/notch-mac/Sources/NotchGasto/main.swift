import AppKit
#if canImport(GastoPrivado)
import GastoPrivado
#endif

// Build pessoal: liga as leituras de uso de fora (antes do AppDelegate criar o coletor).
#if canImport(GastoPrivado)
GastoPrivado.registrar()
#endif

// Arranca sem ícone no Dock (LSUIElement no Info.plist e .accessory aqui,
// inclusive no `swift run`). Com o painel aberto, JanelaPainel passa a .regular (FRA-553).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
