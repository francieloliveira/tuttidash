import AppKit
import GastoCore

// Listas de modelos pelo login (não oficial): só das contas com `nao_oficial`. As leituras de uso
// já estão no GastoCore e respeitam a mesma chave, conta a conta.
FontesNaoOficiais.registrarListas(config: Configuracao.resolver())

// Arranca sem ícone no Dock (LSUIElement no Info.plist e .accessory aqui,
// inclusive no `swift run`). Com o painel aberto, JanelaPainel passa a .regular (FRA-553).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
