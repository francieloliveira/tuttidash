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
    private var assinaturas: [AnyCancellable] = []
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
        let assinaturaAberto = estado.$aberto.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.ajustarLargura() }
        }
        assinaturas.append(assinaturaAberto)
        ajustarLargura()
    }

    /// Largura do item = largura natural da pílula, limitada para não colar na borda direita.
    /// O teto cabe ~8 lanes com % e a seta aberta; acima disso entra no modo curto.
    /// 460 fica próximo do tamanho da pílula do relógio do sistema.
    public static let larguraMaximaBarra = 460.0
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

/// A pílula da barra de menus: logo, contagem de lanes ativas e um indicador
/// animado quando há trabalho em curso. Sem porcentagens — foco no essencial.
/// Ponto vermelho no ícone quando alguma lane está em atenção (≥ 80%).
struct PilulaBarra: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject var estado: EstadoBarra

    /// Alguma lane ligada está em atenção ou sem folga?
    private var temAlerta: Bool {
        r.itens.contains { $0.pct.map { $0 >= Uso.pctAtencao } == true }
    }

    private var r: ResumoBarra { ResumoBarra.montar(modelo.snapshot) }

    /// Cores das lanes ativas para o mosaico de pontos (a contagem fica visual).
    private var coresAtivas: [Color] { r.itens.map { TemaPainel.cor($0.lane) } }

    var body: some View {
        HStack(spacing: 7) {
            // Marca "TD" no lugar do ícone (mais legível no tamanho da barra).
            ZStack(alignment: .topTrailing) {
                Text("TD")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .tracking(-0.3)
                if temAlerta {
                    Circle().fill(PV.vermelho).frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }

            if modelo.snapshot == nil {
                Text("…")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PV.mudo)
            } else {
                MosaicoLanes(cores: coresAtivas, rodando: r.rodando)
            }

            if estado.aberto {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(
                    LinearGradient(colors: [Color(hex: 0x18213A), Color(hex: 0x080C16)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(r.rodando > 0 ? Aurora.acento.opacity(0.28) : .clear, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 3)
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResumoBarra.rotuloAcessivel(r))
    }
}

/// Mosaico criativo das lanes ativas: pontos coloridos + número.
/// Quando há lanes rodando, um pulso vivo acompanha a contagem.
private struct MosaicoLanes: View {
    let cores: [Color]
    let rodando: Int
    @State private var pulso = false
    @Environment(\.accessibilityReduceMotion) private var reduzirMovimento

    var body: some View {
        HStack(spacing: 6) {
            if cores.isEmpty {
                Text("0")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PV.apagado)
                Text("ativas")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PV.apagado)
            } else {
                // Pontos das lanes ativas: a quantidade é lida de relance, sem porcentagem.
                HStack(spacing: 3) {
                    let visiveis = Array(cores.prefix(6))
                    ForEach(Array(visiveis.enumerated()), id: \.offset) { _, cor in
                        Circle()
                            .fill(cor)
                            .frame(width: 5.5, height: 5.5)
                            .shadow(color: cor.opacity(0.55), radius: 2)
                    }
                    if cores.count > 6 {
                        Text("+\(cores.count - 6)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(PV.mudo)
                    }
                }

                Text("\(cores.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)

                if rodando > 0 {
                    IndicadorRodando(ativo: pulso && !reduzirMovimento)
                        .onAppear { iniciarPulso() }
                }
            }
        }
    }

    private func iniciarPulso() {
        guard !reduzirMovimento else { pulso = false; return }
        pulso = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulso = true
        }
    }
}

/// Pulso vivo: núcleo verde que respira, sinalizando lanes em execução.
private struct IndicadorRodando: View {
    let ativo: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(PV.verde.opacity(ativo ? 0.0 : 0.28))
                .frame(width: ativo ? 14 : 8, height: ativo ? 14 : 8)
            Circle()
                .fill(PV.verde.opacity(0.25))
                .frame(width: 8, height: 8)
            Circle()
                .fill(PV.verde)
                .frame(width: 4.5, height: 4.5)
                .shadow(color: PV.verde.opacity(0.9), radius: ativo ? 4 : 2)
        }
        .frame(width: 14, height: 14)
        .help(Text("Lanes em execução"))
    }
}

/// O painel que abre abaixo da pílula: lanes ligadas, card, modelo, % e a última linha do log.
/// Fundo aurora + cartões de vidro, igual às outras superfícies do app.
struct PainelBarra: View {
    @ObservedObject var modelo: ModeloNotch
    var fechar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MarcaAurora(tamanho: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("TuttiDash")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Aurora.texto)
                    SeloVersao(compacto: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                CirculoEstado(geral: modelo.snapshot?.geral, pulsar: false)
                Text(modelo.snapshot?.rotuloGeral ?? "Lendo")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                Spacer()
                Text(ResumoBarra.montar(modelo.snapshot).texto)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.045)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            let linhas = (modelo.snapshot?.notch.linhas ?? []).filter { $0.estado != .desligada }
            if linhas.isEmpty {
                Text(modelo.snapshot == nil ? "Lendo o estado das lanes…" : "Nenhuma lane ligada.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Aurora.mudo)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(linhas, id: \.lane) { l in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(TemaPainel.cor(l.lane))
                        .frame(width: 7, height: 7)
                        .shadow(color: TemaPainel.cor(l.lane).opacity(0.6), radius: 3)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ResumoBarra.titulo(l.lane))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Aurora.texto)
                            if let card = l.card {
                                Button { modelo.abrirCard(card); fechar() } label: {
                                    Text(card)
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Aurora.azul)
                                }
                                .buttonStyle(.plain)
                                .help("Abrir \(card) no Linear")
                            }
                            Spacer()
                            Text(ResumoBarra.textoPct(l.pct))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(corConta(l.pct))
                        }
                        Text(l.descricao)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Aurora.texto2)
                            .lineLimit(1)
                        if let m = l.textoModelo {
                            Text(m)
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(Aurora.apagado)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
            if let m = MensagemLog.resumir(modelo.snapshot?.logTexto ?? "") {
                LinhaMensagemBarra(mensagem: m)
            }
            HStack(spacing: 7) {
                Button { fechar(); modelo.abrirPainel() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow").font(.system(size: 9.5, weight: .semibold))
                        Text("Abrir painel")
                    }
                }
                .buttonStyle(EstiloBotaoPrincipal(compacto: true))
                Button { fechar(); modelo.abrirConfig() } label: {
                    Text("Ajustes")
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                Spacer()
                Button { PresencaApp.sair() } label: {
                    Text("Sair").foregroundStyle(Aurora.vermelho.opacity(0.85))
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                .help("Encerrar o TuttiDash")
            }
        }
        .padding(14)
        .frame(width: 372)
        .background(FundoAurora(intensidade: 0.8))
        .environment(\.colorScheme, .dark)
    }
}

/// A última novidade do dispatcher/vigia em frase clara (`MensagemLog`), não a linha crua do log.
private struct LinhaMensagemBarra: View {
    let mensagem: MensagemBarra

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icone).font(.system(size: 11)).foregroundStyle(cor).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mensagem.texto).font(.sf(11)).foregroundStyle(TemaPainel.texto).lineLimit(2)
                    if let q = mensagem.quando {
                        Text("· " + Formato.ha(q, agora: Date())).font(.sf(10)).foregroundStyle(TemaPainel.mudo)
                            .fixedSize()
                    }
                }
                if let d = mensagem.detalhe {
                    Text(d).font(.sf(10.5)).foregroundStyle(TemaPainel.mudo).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var icone: String {
        switch mensagem.tipo {
        case .trabalho: return "hammer"
        case .entrega: return "checkmark.circle"
        case .alerta: return "exclamationmark.triangle"
        case .fila: return "tray"
        case .info: return "info.circle"
        }
    }

    private var cor: Color {
        switch mensagem.tipo {
        case .trabalho: return TemaPainel.ciano
        case .entrega: return TemaPainel.verde
        case .alerta: return TemaPainel.amarelo
        case .fila: return TemaPainel.amarelo
        case .info: return TemaPainel.mudo
        }
    }
}
