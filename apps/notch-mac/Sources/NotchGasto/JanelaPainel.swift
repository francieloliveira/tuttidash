import AppKit
import SwiftUI
import GastoCore

/// Janela do painel completo. Não é o notch: abre pelo ícone ou pelo menu.
/// Com ela aberta o app vai para o Dock; ao fechar a janela volta à pílula (FRA-553).
@MainActor
final class JanelaPainel: NSObject, NSWindowDelegate {
    static let compartilhada = JanelaPainel()
    private var janela: NSWindow?
    /// Sobe a cada `mostrar`. O fecho guarda o valor e ignora a volta à pílula se o painel reabriu.
    private var epocaPainel = 0

    var modeloAtual: ModeloNotch? { modeloFoto }

    func mostrar(modelo: ModeloNotch) {
        modeloFoto = modelo
        epocaPainel += 1
        // Dock e Cmd-Tab enquanto esta janela existir na tela.
        PresencaApp.aplicar(PoliticaDock.aoMostrarPainel())
        if janela == nil {
            let host = NSHostingController(rootView: PainelTela(modelo: modelo))
            host.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: host)
            w.title = "TuttiDash"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            // Painel v2: desenhado para 1600×900 (imagem de referência); abaixo disso rola.
            w.setContentSize(NSSize(width: 1600, height: 900))
            w.minSize = NSSize(width: 1280, height: 800)
            w.backgroundColor = NSColor(srgbRed: 2 / 255, green: 8 / 255, blue: 20 / 255, alpha: 1)
            w.center()
            w.delegate = self
            janela = w
        }
        janela?.makeKeyAndOrderFront(nil)
    }

    /// Botão de fechar ou ⌘W. Não encerra: a política pede `.accessory` e o processo fica.
    /// Adiado para o `close()` acabar antes de tirar o app do Dock. Minimizar não passa por aqui.
    func windowWillClose(_ notification: Notification) {
        let epoca = epocaPainel
        Task { @MainActor [weak self] in
            guard let self, epoca == self.epocaPainel else { return }
            let efeito = PoliticaDock.aoFecharPainel()
            PresencaApp.aplicar(efeito.politica)
            PresencaApp.cumprir(efeito.destino)
        }
    }

    private var modeloFoto: ModeloNotch?
    private var janelaFoto: NSWindow?

    /// Desenha o painel num PNG (sem captura de tela), sempre em 1600×900, o tamanho da imagem de
    /// referência. Usa uma janela sem borda fora da tela, que não é limitada ao tamanho do monitor.
    func fotografar(_ url: URL, pagina: PaginaPainel = .dashboard, secao: IdSecaoAjustes? = nil, tamanho: NSSize = NSSize(width: 1600, height: 900)) {
        guard let modelo = modeloFoto else { return }
        if let secao { NavegacaoPainel.compartilhada.abrirAjustes(secao) } else { NavegacaoPainel.compartilhada.pagina = pagina }
        let host = NSHostingView(rootView: PainelTela(modelo: modelo))
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: tamanho),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: tamanho), display: true)
        w.orderFrontRegardless()
        janelaFoto = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            w.orderOut(nil)
            self?.janelaFoto = nil
        }
    }
}
