import AppKit
import SwiftUI
import GastoCore

// FRA-531: retorno ativo. Todo clique mostra que foi recebido (estado pressionado), mostra que está
// rodando (indicador) e termina com um aviso curto de sucesso ou erro, com o motivo em pt-BR.

/// Espaçamento, raios e animações do app num lugar só.
enum DS {
    static let e1: CGFloat = 4, e2: CGFloat = 8, e3: CGFloat = 12, e4: CGFloat = 16, e5: CGFloat = 22, e6: CGFloat = 32
    static let raioP: CGFloat = 7, raioM: CGFloat = 10, raioG: CGFloat = 14
    static let mola = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let suave = Animation.easeInOut(duration: 0.22)
    static let barra = Animation.spring(response: 0.6, dampingFraction: 0.9)

    /// Reduzir movimento ligado: sem animação.
    static var reduzir: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func anim(_ a: Animation) -> Animation? { reduzir ? nil : a }
}

/// Executa com animação (ou sem, com Reduzir movimento).
func comAnimacao(_ a: Animation = DS.mola, _ corpo: () -> Void) {
    if DS.reduzir { corpo() } else { withAnimation(a, corpo) }
}

// MARK: - Avisos (toast)

struct Aviso: Identifiable, Equatable {
    enum Tipo { case ok, erro, info }
    let id = UUID()
    let tipo: Tipo
    let titulo: String
    let detalhe: String?
}

/// Avisos curtos no canto da janela principal. Qualquer tela chama `CentralAvisos.compartilhada.ok(...)`.
@MainActor
final class CentralAvisos: ObservableObject {
    static let compartilhada = CentralAvisos()
    @Published private(set) var avisos: [Aviso] = []

    func ok(_ titulo: String, _ detalhe: String? = nil) { mostrar(Aviso(tipo: .ok, titulo: titulo, detalhe: detalhe)) }
    func erro(_ titulo: String, _ detalhe: String? = nil) { mostrar(Aviso(tipo: .erro, titulo: titulo, detalhe: detalhe)) }
    func info(_ titulo: String, _ detalhe: String? = nil) { mostrar(Aviso(tipo: .info, titulo: titulo, detalhe: detalhe)) }

    func mostrar(_ a: Aviso) {
        comAnimacao { avisos.append(a); if avisos.count > 3 { avisos.removeFirst() } }
        let tempo = a.tipo == .erro ? MaquinaAcao.tempoErro : MaquinaAcao.tempoOk + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + tempo) { [weak self] in self?.fechar(a) }
    }

    func fechar(_ a: Aviso) { comAnimacao { avisos.removeAll { $0.id == a.id } } }
}

struct CamadaAvisos: View {
    @ObservedObject var central = CentralAvisos.compartilhada

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.e2) {
            ForEach(central.avisos) { a in
                CartaoAviso(aviso: a) { central.fechar(a) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(DS.e5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!central.avisos.isEmpty)
    }
}

struct CartaoAviso: View {
    let aviso: Aviso
    var fechar: () -> Void

    private var cor: Color { aviso.tipo == .ok ? PV.verde : aviso.tipo == .erro ? PV.vermelho : PV.azul }
    private var simbolo: String {
        aviso.tipo == .ok ? "checkmark.circle.fill" : aviso.tipo == .erro ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.e3) {
            Image(systemName: simbolo).font(.system(size: 16, weight: .semibold)).foregroundStyle(cor)
            VStack(alignment: .leading, spacing: 2) {
                Text(aviso.titulo).font(PV.fonte(13, .semibold)).foregroundStyle(PV.texto)
                if let d = aviso.detalhe { Text(d).font(PV.fonte(12)).foregroundStyle(PV.mudo).lineLimit(3) }
            }
            Spacer(minLength: 0)
            Button(action: fechar) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(PV.apagado) }
                .buttonStyle(.plain).help(String(localized: "Fechar aviso"))
        }
        .padding(.horizontal, DS.e4).padding(.vertical, DS.e3)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.raioM, style: .continuous))
        .background(RoundedRectangle(cornerRadius: DS.raioM, style: .continuous).fill(PV.cartao.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: DS.raioM, style: .continuous).strokeBorder(cor.opacity(0.45), lineWidth: 1))
        .overlay(alignment: .leading) { Capsule().fill(cor).frame(width: 3).padding(.vertical, 8).padding(.leading, 2) }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ação com retorno

/// Estado de uma ação para a tela: guarda a máquina e some com o aviso sozinho.
@MainActor
final class EstadoAcaoTela: ObservableObject {
    @Published private(set) var maquina = MaquinaAcao()
    var estado: EstadoAcao { maquina.estado }

    /// Roda `trabalho` fora da main thread. O retorno é a mensagem de sucesso.
    func rodar(aviso: Bool = true, _ trabalho: @escaping @Sendable () async throws -> String) {
        guard maquina.iniciar() else { return }
        Task { @MainActor in
            do {
                let msg = try await trabalho()
                comAnimacao(DS.suave) { maquina.concluir(msg) }
                if aviso { CentralAvisos.compartilhada.ok(msg) }
            } catch {
                let m = MaquinaAcao.motivo(error)
                comAnimacao(DS.suave) { maquina.falhar(m) }
                if aviso { CentralAvisos.compartilhada.erro(String(localized: "Não deu certo"), m) }
            }
            var espera = MaquinaAcao.tempoOk
            if case .erro = maquina.estado { espera = MaquinaAcao.tempoErro }
            try? await Task.sleep(for: .seconds(espera))
            comAnimacao(DS.suave) { maquina.expirar() }
        }
    }
}

/// Ícone de estado ao lado de um controle: indicador rodando, ✓ verde, ! vermelho.
struct IndicadorAcao: View {
    let estado: EstadoAcao

    var body: some View {
        Group {
            switch estado {
            case .ocioso: Color.clear
            case .rodando: ProgressView().controlSize(.small)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(PV.verde)
            case let .erro(m, _): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PV.vermelho).help(m)
            }
        }
        .frame(width: 16, height: 16)
        .transition(.scale.combined(with: .opacity))
    }
}

/// Botão com estado pressionado, indicador enquanto roda e ✓ / ! no fim (AcaoComFeedback).
struct BotaoAcao: View {
    var titulo: String
    var simbolo: String? = nil
    var destaque = false
    var trabalho: @Sendable () async throws -> String
    @StateObject private var acao = EstadoAcaoTela()
    @State private var hover = false

    var body: some View {
        Button { acao.rodar(trabalho) } label: {
            HStack(spacing: 7) {
                if acao.estado.rodando { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
                else if case .ok = acao.estado { Image(systemName: "checkmark").foregroundStyle(PV.verde) }
                else if case .erro = acao.estado { Image(systemName: "exclamationmark.triangle").foregroundStyle(PV.vermelho) }
                else if let simbolo { Image(systemName: simbolo) }
                Text(titulo)
            }
            .font(PV.fonte(12.5, destaque ? .semibold : .regular))
            .foregroundStyle(destaque ? Color.white : PV.texto)
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DS.raioP + 1, style: .continuous)
                .fill(destaque ? PV.azulBotao.opacity(hover ? 0.9 : 1) : (hover ? PV.botao.opacity(0.6) : PV.botao)))
            .overlay(RoundedRectangle(cornerRadius: DS.raioP + 1, style: .continuous).strokeBorder(destaque ? Color.clear : PV.botaoBorda, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .disabled(acao.estado.rodando)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Encolhe um pouco ao apertar (sem animação com Reduzir movimento).
struct Pressionavel: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !DS.reduzir ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(DS.anim(.spring(response: 0.2, dampingFraction: 0.7)), value: configuration.isPressed)
    }
}

// MARK: - Progresso e uso

/// Barra de progresso de processo longo: com fração vira determinada; sem, uma faixa corre de lado a lado.
struct BarraProgresso: View {
    var progresso: ProgressoProcesso
    var cor: Color = PV.azul
    var altura: CGFloat = 6
    var mostrarLegenda = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(PV.trilho.opacity(0.6))
                    if let f = progresso.fracao {
                        Capsule().fill(LinearGradient(colors: [cor.opacity(0.75), cor], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(altura, g.size.width * f))
                            .animation(DS.anim(DS.barra), value: f)
                    } else {
                        FaixaIndeterminada(cor: cor, largura: g.size.width)
                    }
                }
            }
            .frame(height: altura)
            .clipShape(Capsule())
            if mostrarLegenda {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = progresso.legenda(agora: ctx.date)
                    if !t.isEmpty { Text(t).font(PV.fonte(11)).foregroundStyle(PV.mudo).monospacedDigit() }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(progresso.legenda())
        .accessibilityValue(progresso.fracao.map { "\(Int($0 * 100))%" } ?? String(localized: "em andamento"))
    }
}

private struct FaixaIndeterminada: View {
    var cor: Color
    var largura: CGFloat
    @State private var x: CGFloat = -0.35

    var body: some View {
        Capsule().fill(LinearGradient(colors: [cor.opacity(0), cor, cor.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: largura * 0.35)
            .offset(x: (DS.reduzir ? 0.3 : x) * largura)
            .onAppear {
                guard !DS.reduzir else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { x = 1 }
            }
    }
}

extension NivelUso {
    /// Mesma regra do resto do app (Uso.nivel: atenção a partir de 80%, crítico a partir de 95%).
    var cor: Color {
        switch self {
        case .ok: return PV.verde
        case .atencao: return PV.ambar
        case .critico: return PV.vermelho
        }
    }
}

/// % de uso de uma conta: barra que cresce animada, com cor por nível, e o número que rola.
struct BarraUso: View {
    var pct: Double?
    var altura: CGFloat = 7
    var mostrarNumero = true
    @State private var visivel: Double = 0

    var body: some View {
        HStack(spacing: DS.e2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(PV.trilho.opacity(0.55))
                    if let p = pct {
                        Capsule().fill(Uso.nivel(p).cor.gradient)
                            .frame(width: max(visivel > 0 ? altura : 0, g.size.width * min(visivel, 100) / 100))
                    }
                }
            }
            .frame(height: altura)
            if mostrarNumero {
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(PV.fonte(12, .semibold)).monospacedDigit()
                    .foregroundStyle(pct.map { Uso.nivel($0).cor } ?? PV.apagado)
                    .contentTransition(.numericText())
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .onAppear { comAnimacao(DS.barra) { visivel = pct ?? 0 } }
        .onChange(of: pct) { _, n in comAnimacao(DS.barra) { visivel = n ?? 0 } }
        .accessibilityElement()
        .accessibilityLabel(pct.map { String(localized: "Uso \(Int($0))%") } ?? String(localized: "Uso sem leitura"))
    }
}

/// «atualizado há 12 s», que se atualiza sozinho a cada segundo.
struct SeloAtualizado: View {
    var data: Date?
    var carregando = false

    var body: some View {
        HStack(spacing: 5) {
            if carregando { ProgressView().controlSize(.mini) }
            else { Circle().fill(data == nil ? PV.apagado : PV.verde).frame(width: 6, height: 6) }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(carregando ? String(localized: "atualizando…") : TextoTempo.atualizado(data, agora: ctx.date))
                    .font(PV.fonte(11)).foregroundStyle(PV.mudo).monospacedDigit()
            }
        }
    }
}

/// Retângulo pulsante enquanto o dado ainda não chegou (esqueleto).
struct Esqueleto: View {
    var altura: CGFloat = 14
    var largura: CGFloat? = nil
    @State private var claro = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(PV.trilho.opacity(claro ? 0.55 : 0.3))
            .frame(width: largura, height: altura)
            .onAppear {
                guard !DS.reduzir else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { claro = true }
            }
            .accessibilityLabel(String(localized: "Carregando"))
    }
}

extension View {
    /// Cartão com profundidade: leve gradiente, borda que acende no hover e sombra.
    func cartaoVivo(raio: CGFloat = DS.raioG, hover: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: raio, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x0B1A30), PV.cartao], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: raio, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(hover ? 0.16 : 0.08), PV.cartaoBorda],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.45 : 0.3), radius: hover ? 16 : 10, y: hover ? 8 : 4)
    }
}
