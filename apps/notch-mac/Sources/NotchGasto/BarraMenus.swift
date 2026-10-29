import AppKit
import Combine
import SwiftUI
import GastoCore

/// FRA-522: a pílula vira um item de verdade da barra de menus (NSStatusItem).
/// O macOS reserva o espaço e empurra os outros ícones; nada fica coberto.
/// Clique: abre o painel logo abaixo. Clique direito (ou ctrl+clique): o menu de sempre.
@MainActor
final class ControladorBarra: NSObject, NSPopoverDelegate {
    let item: NSStatusItem
    let modelo: ModeloNotch
    let menu: NSMenu
    private let popover = NSPopover()
    private let host: NSHostingView<PilulaBarra>
    private var assinatura: AnyCancellable?
    let estado = EstadoBarra()

    init(modelo: ModeloNotch, menu: NSMenu) {
        self.modelo = modelo
        self.menu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        host = NSHostingView(rootView: PilulaBarra(modelo: modelo, estado: estado))
        super.init()
        guard let botao = item.button else { return }
        botao.title = ""
        botao.image = nil
        botao.toolTip = "TuttiDash · lanes"
        botao.setAccessibilityLabel("TuttiDash")
        host.translatesAutoresizingMaskIntoConstraints = false
        botao.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerYAnchor.constraint(equalTo: botao.centerYAnchor),
            host.leadingAnchor.constraint(equalTo: botao.leadingAnchor),
        ])
        botao.target = self
        botao.action = #selector(clique(_:))
        botao.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hc = NSHostingController(rootView: PainelBarra(modelo: modelo) { [weak self] in
            self?.popover.performClose(nil)
        })
        hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc
        assinatura = modelo.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.ajustarLargura() }
        }
        ajustarLargura()
    }

    /// Largura do item = largura natural da pílula. O teto cabe as 5 lanes ligadas;
    /// acima disso o resumo já está no modo curto e a pílula é só o número.
    func ajustarLargura() {
        host.layoutSubtreeIfNeeded()
        let w = min(host.fittingSize.width, ResumoBarra.larguraMaximaBarra)
        item.length = max(w, 24)
    }

    @objc private func clique(_ botao: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            item.menu = menu
            botao.performClick(nil)
            item.menu = nil
            return
        }
        alternar()
    }

    func alternar() {
        if popover.isShown { popover.performClose(nil); return }
        guard let botao = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let v = popover.contentViewController?.view {
            v.layoutSubtreeIfNeeded()
            popover.contentSize = v.fittingSize
        }
        popover.show(relativeTo: botao.bounds, of: botao, preferredEdge: .minY)
        estado.aberto = true
    }

    /// `--foto-barra <png>`: desenha o painel da pílula num PNG (sem gravação de tela).
    func fotografarPainel(_ url: URL) {
        guard let v = popover.contentViewController?.view else { return }
        v.layoutSubtreeIfNeeded()
        let tam = v.fittingSize
        if v.frame.size != tam { v.setFrameSize(tam) }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func popoverDidClose(_ notification: Notification) { estado.aberto = false }
}

@MainActor
final class EstadoBarra: ObservableObject {
    @Published var aberto = false
}

/// A pílula escura da barra (a que o app mostra por padrão): logo + um ponto aceso
/// com % por lane ligada, ou «N rodando» no modo curto. O notch antigo fica à parte.
struct PilulaBarra: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject var estado: EstadoBarra

    var body: some View {
        let r = ResumoBarra.montar(modelo.snapshot)
        HStack(spacing: 6) {
            Image(nsImage: AppDelegate.iconeBarra())
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(.white)
            if r.compacto {
                Text(r.itens.isEmpty && modelo.snapshot != nil ? "0" : "\(r.rodando)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            } else {
                ForEach(r.itens, id: \.lane) { i in
                    HStack(spacing: 3) {
                        Circle().fill(TemaPainel.cor(i.lane)).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color.white.opacity(i.rodando ? 0.95 : 0), lineWidth: 1))
                        Text(ResumoBarra.textoPct(i.pct))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .help(i.titulo)
                }
            }
            if estado.aberto {
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResumoBarra.rotuloAcessivel(r))
    }
}

/// O painel que abre abaixo da pílula: lanes ligadas, card, modelo, % e a última linha do log.
struct PainelBarra: View {
    @ObservedObject var modelo: ModeloNotch
    var fechar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CirculoEstado(geral: modelo.snapshot?.geral, pulsar: false)
                Text(modelo.snapshot?.rotuloGeral ?? "Lendo")
                    .font(.sf(13, .semibold)).foregroundStyle(TemaPainel.texto)
                Spacer()
                Text(ResumoBarra.montar(modelo.snapshot).texto)
                    .font(.sf(11)).foregroundStyle(TemaPainel.mudo)
            }
            let linhas = (modelo.snapshot?.notch.linhas ?? []).filter { $0.estado != .desligada }
            if linhas.isEmpty {
                Text(modelo.snapshot == nil ? "Lendo o estado das lanes…" : "Nenhuma lane ligada.")
                    .font(.sf(12)).foregroundStyle(TemaPainel.mudo)
            }
            ForEach(linhas, id: \.lane) { l in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(TemaPainel.cor(l.lane)).frame(width: 9, height: 9).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ResumoBarra.titulo(l.lane)).font(.sf(12, .semibold)).foregroundStyle(TemaPainel.texto)
                            if let card = l.card {
                                Button(card) { modelo.abrirCard(card); fechar() }
                                    .buttonStyle(.link).font(.sf(12, .semibold))
                            }
                            Spacer()
                            Text(ResumoBarra.textoPct(l.pct)).font(.sf(12, .semibold).monospacedDigit())
                                .foregroundStyle(corConta(l.pct))
                        }
                        Text(l.descricao).font(.sf(11)).foregroundStyle(TemaPainel.texto).lineLimit(1)
                        if let m = l.textoModelo {
                            Text(m).font(.system(size: 10)).foregroundStyle(TemaPainel.mudo).lineLimit(1)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            }
            if let ultima = ResumoBarra.ultimaLinha(modelo.snapshot?.logTexto ?? "") {
                if ultima.lowercased().contains("fila vazia:") {
                    // Mensagem do vigia quando não há cards prontos no Todo nem no Backlog.
                    // Apresenta de forma amigável em vez da linha bruta do log.
                    HStack(spacing: 6) {
                        Image(systemName: "tray").font(.system(size: 11)).foregroundStyle(TemaPainel.amarelo)
                        Text("Sem cards prontos no Todo nem no Backlog")
                            .font(.system(size: 11)).foregroundStyle(TemaPainel.mudo)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(ultima)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TemaPainel.mudo)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Abrir painel") { fechar(); modelo.abrirPainel() }
                Button("Ajustes") { fechar(); modelo.abrirConfig() }
                Spacer()
                Button("Sair") { PresencaApp.sair() }
            }
            .font(.sf(11))
        }
        .padding(14)
        .frame(width: 360)
        .background(LinearGradient(colors: [Color(hex: 0x14102A), Color(hex: 0x05070F)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }
}
