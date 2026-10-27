import AppKit
import SwiftUI
import GastoCore

/// Painel sem borda, acima da barra de menus, que não ativa o app ao ser clicado.
final class JanelaNotch: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Aceita o primeiro clique (o app nunca fica ativo).
final class HostNotch<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Posiciona a janela colada ao notch da tela principal e controla o hover (expandir/recolher).
@MainActor
final class ControladorNotch {
    let modelo: ModeloNotch
    let janela: JanelaNotch
    /// `--expandido`: deixa o painel aberto (útil para conferir o layout e tirar screenshot).
    let fixo: Bool
    var aoExpandir: () -> Void = {}

    private var topo: CGFloat = 0
    private var quadroTela: NSRect = .zero
    private var meioX: CGFloat = 0
    private var monitores: [Any] = []
    private var timer: Timer?
    private var expandirPendente: Task<Void, Never>?
    private var recolherPendente: Task<Void, Never>?

    private let margem: CGFloat = 44      // espaço para a sombra
    private let margemBaixo: CGFloat = 56

    init(modelo: ModeloNotch, fixo: Bool) {
        self.modelo = modelo
        self.fixo = fixo
        janela = JanelaNotch(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        janela.isOpaque = false
        janela.backgroundColor = .clear
        janela.hasShadow = false
        janela.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        janela.isMovable = false
        janela.hidesOnDeactivate = false
        janela.isFloatingPanel = true
        // depois de isFloatingPanel (que volta o nível para .floating): acima da barra de menus
        janela.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        janela.becomesKeyOnlyIfNeeded = true
        janela.isReleasedWhenClosed = false
        let host = HostNotch(rootView: RaizNotch(modelo: modelo))
        host.sizingOptions = []
        janela.contentView = host

        modelo.aoMudarTamanho = { [weak self] in self?.painelMudou() }
        modelo.aoMudarPilula = { [weak self] in self?.pilulaMudou() }
        posicionar()
        if fixo { modelo.expandido = true; aplicarFrame() }
        janela.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.posicionar() }
        }
        let tipos: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Os monitores entregam na main thread: chama direto, sem criar uma Task por evento (FRA-339).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: tipos, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.avaliarMouse() }
        }) { monitores.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: tipos, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.avaliarMouse() }
            return e
        }) { monitores.append(l) }
        ajustarReserva()
    }

    /// Timer de reserva (pega saídas rápidas que os monitores não entregam): só com o painel expandido,
    /// no intervalo da `PoliticaAtualizacao`. Recolhido, nada fica rodando.
    private func ajustarReserva() {
        timer?.invalidate(); timer = nil
        guard let intervalo = modelo.politica.reservaMouse(expandido: modelo.expandido) else { return }
        let t = Timer(timeInterval: intervalo, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.avaliarMouse() }
        }
        t.tolerance = intervalo / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Preferência do próprio app (UserDefaults, nada das lanes): forçar a tela principal
    /// (a da barra de menus) mesmo quando existe outra tela com notch.
    static var usarTelaPrincipal: Bool {
        get { UserDefaults.standard.bool(forKey: "usarTelaPrincipal")
              || ProcessInfo.processInfo.arguments.contains("--tela-principal") }
        set { UserDefaults.standard.set(newValue, forKey: "usarTelaPrincipal") }
    }

    /// Tela com notch (MacBook) se houver; senão a principal (a da barra de menus).
    private var tela: NSScreen? {
        let principal = NSScreen.screens.first ?? NSScreen.main
        if !Self.usarTelaPrincipal, let n = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return n
        }
        return principal
    }

    /// Cola a forma na borda de cima da tela, centrada no notch (recolhida e expandida).
    func posicionar() {
        guard let tela else { return }
        let f = tela.frame
        var barra = f.maxY - tela.visibleFrame.maxY
        if barra <= 0 { barra = NSStatusBar.system.thickness }
        if tela.safeAreaInsets.top > 0, let l = tela.auxiliaryTopLeftArea, let r = tela.auxiliaryTopRightArea {
            // notch = o que sobra entre as áreas auxiliares da esquerda e da direita
            let larguraNotch = max(f.width - l.width - r.width, 120)
            modelo.temNotch = true
            modelo.larguraNotch = larguraNotch
            modelo.alturaNotch = tela.safeAreaInsets.top
            meioX = f.minX + l.width + larguraNotch / 2
        } else {
            // Sem notch: mesma forma, colada no topo e centrada, com a altura da barra de menus.
            modelo.temNotch = false
            modelo.larguraNotch = 0
            modelo.alturaNotch = barra
            meioX = f.midX
        }
        topo = f.maxY
        quadroTela = f
        aplicarFrame()
    }

    private func larguraJanela() -> CGFloat {
        let orelha: CGFloat = Tema.orelha
        let deslocamento = abs(modelo.deslocamentoCentroPilula)
        return max(Tema.larguraNotchAberto, modelo.larguraPilula + 2 * deslocamento) + 2 * orelha
    }

    private func larguraForma(_ expandido: Bool) -> CGFloat {
        let orelha: CGFloat = Tema.orelha
        return (expandido ? Tema.larguraNotchAberto : modelo.larguraPilula) + 2 * orelha
    }

    private func alturaForma(_ expandido: Bool) -> CGFloat {
        expandido ? max(modelo.tamanhoPainel.height, modelo.alturaNotch) : modelo.alturaNotch
    }

    /// Frame da janela para o estado atual (ou expandido, se `expandido` for true).
    /// A largura e o X da janela ficam fixos centrados em `meioX` para que a transição
    /// entre recolhida (assimétrica) e expandida (centrada) anime suavemente no SwiftUI, sem jitter.
    func aplicarFrame(expandido: Bool? = nil) {
        let e = expandido ?? modelo.expandido
        let w = larguraJanela() + 2 * margem
        let h = alturaForma(e) + margemBaixo
        let w2 = w.rounded()
        var x = (meioX - w2 / 2).rounded()
        // Não deixar a pílula cobrir ícones da barra de menus nas bordas da tela.
        let margemLateral: CGFloat = 30
        let tela = quadroTela
        if x < tela.minX + margemLateral { x = tela.minX + margemLateral }
        if x + w2 > tela.maxX - margemLateral { x = tela.maxX - margemLateral - w2 }
        let frame = NSRect(x: x, y: topo - h, width: w2, height: h)
        if janela.frame != frame {
            janela.setFrame(frame, display: true)
        }
    }

    private func retangulo(_ expandido: Bool) -> NSRect {
        let w = larguraForma(expandido)
        let h = alturaForma(expandido)
        let centroX = meioX + (expandido ? 0 : modelo.deslocamentoCentroPilula)
        // só dentro da própria tela: com telas empilhadas, o Dock da outra tela não abre o painel
        return NSRect(x: centroX - w / 2, y: topo - h, width: w, height: h + 2).intersection(quadroTela)
    }

    func avaliarMouse() {
        guard !fixo else { return }
        let p = NSEvent.mouseLocation
        if modelo.expandido {
            if dentroDoPainel(p) {
                recolherPendente?.cancel(); recolherPendente = nil
            } else if recolherPendente == nil {
                recolherPendente = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.recolherPendente = nil
                    if !self.dentroDoPainel(NSEvent.mouseLocation) { self.recolher() }
                }
            }
        } else {
            if retangulo(false).contains(p) {
                guard expandirPendente == nil else { return }
                expandirPendente = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, !Task.isCancelled else { return }
                    self.expandirPendente = nil
                    if self.retangulo(false).contains(NSEvent.mouseLocation) { self.expandir() }
                }
            } else {
                expandirPendente?.cancel(); expandirPendente = nil
            }
        }
    }

    private func dentroDoPainel(_ p: NSPoint) -> Bool {
        retangulo(true).insetBy(dx: -8, dy: -8).contains(p)
    }

    func expandir() {
        guard !modelo.expandido else { return }
        aoExpandir()
        aplicarFrame(expandido: true)
        modelo.expandido = true
        ajustarReserva()
    }

    func recolher() {
        guard modelo.expandido, !fixo else { return }
        modelo.expandido = false
        ajustarReserva()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.modelo.expandido else { return }
            self.aplicarFrame(expandido: false)
        }
    }

    /// Desenha o conteúdo da janela num PNG (sem captura de tela: não precisa de permissão).
    /// O blur de fundo não aparece; o fundo vira um tom escuro parecido com o papel de parede do mockup.
    func fotografar(_ url: URL) {
        guard let v = janela.contentView else { return }
        let escala = janela.backingScaleFactor
        let w = Int(v.bounds.width * escala), h = Int(v.bounds.height * escala)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.10, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: escala, y: escala)
        ctx.translateBy(x: 0, y: v.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        v.layer?.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Altura do painel mudou (dados novos): ajusta a janela se estiver aberta.
    func painelMudou() {
        if modelo.expandido { aplicarFrame(expandido: true) }
    }

    /// A largura da pílula mudou (alerta de limite apareceu ou sumiu): ajusta a janela recolhida.
    func pilulaMudou() {
        if !modelo.expandido { aplicarFrame(expandido: false) }
    }
}
