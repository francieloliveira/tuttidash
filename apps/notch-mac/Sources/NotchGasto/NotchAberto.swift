import SwiftUI
import GastoCore

/// Notch expandido: uma linha por lane, resumo de testes, lock, custo do dia e três ícones.
/// O desenho segue a linguagem Aurora (vidro, tipografia arredondada, acentos ciano→violeta).
struct NotchAberto: View {
    @ObservedObject var modelo: ModeloNotch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cabecalho
            if let snap = modelo.snapshot {
                ForEach(snap.notch.linhas, id: \.lane) { linha in
                    linhaLane(linha, selecionada: foco == linha.lane)
                        .contentShape(Rectangle())
                        .onTapGesture { modelo.laneEmFoco = linha.lane }
                }
                linhaResumo("Testes", snap.notch.testes, destaque: snap.notch.testes.contains("falha") || snap.notch.testes.contains("0 testes"))
                linhaResumo("Build", snap.notch.build, destaque: false)
                linhaResumo("Custo hoje", snap.notch.custoHoje, destaque: false)
                if let aviso = modelo.avisoCtl {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(aviso)
                    }
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Aurora.ambar)
                    .padding(.top, 7)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lendo o estado das lanes…")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            }
            rodape
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .frame(width: Tema.larguraNotchAberto)
    }

    private var foco: String? { modelo.laneEmFoco ?? modelo.snapshot?.laneSugerida }

    private var cabecalho: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 8) {
                CirculoEstado(geral: modelo.snapshot?.geral, pulsar: true)
                Text(modelo.snapshot?.rotuloGeral ?? "Lendo")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                Spacer(minLength: modelo.temNotch ? modelo.larguraNotch : 8)
                Text(hora(ctx.date))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Aurora.apagado)
            }
            .frame(height: modelo.alturaNotch)
        }
    }

    private func linhaLane(_ linha: LinhaLane, selecionada: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(linha.estado == .desligada ? Aurora.apagado : TemaPainel.cor(linha.lane))
                    .frame(width: 7, height: 7)
                    .shadow(color: linha.estado == .desligada ? .clear : TemaPainel.cor(linha.lane).opacity(0.7),
                            radius: 3)
                Text(linha.lane)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                    .lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
            .opacity(linha.estado == .desligada ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(linha.estado == .desligada ? "desligada" : linha.descricao)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(linha.estado == .desligada ? Aurora.mudo : Aurora.texto2)
                    .lineLimit(1)
                if let texto = linha.textoModelo {
                    if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                        Text(texto + " · " + aviso)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Aurora.ambar)
                            .lineLimit(1)
                    } else {
                        Text(texto)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Aurora.apagado)
                            .lineLimit(1)
                    }
                } else if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                    Text(aviso)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Aurora.ambar)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if linha.estado != .desligada {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(textoUso(linha))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Aurora.mudo)
                    HStack(spacing: 8) {
                        barra(linha.pct)
                            .frame(width: 96)
                        BotaoLigarDesligar(ligada: !linha.desligadaPeloUsuario) {
                            modelo.desativarLane(linha.lane)
                        }
                        .help("Desativar \(linha.lane)")
                    }
                    if let reset = modelo.resetSemanal[linha.lane] {
                        Text("reseta \(Formato.quando(reset, agora: Date()))")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Aurora.apagado)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    BotaoLigarDesligar(ligada: false) {
                        modelo.ativarLane(linha.lane)
                    }
                    .help("Reativar \(linha.lane)")
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background {
            if selecionada {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Aurora.acento.opacity(0.09))
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Aurora.hair).frame(height: 1) }
    }

    private func linhaResumo(_ titulo: String, _ valor: String, destaque: Bool) -> some View {
        HStack {
            Text(titulo.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(Aurora.mudo)
            Spacer()
            Text(valor)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(destaque ? Aurora.vermelho : Aurora.texto2)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .overlay(alignment: .top) { Rectangle().fill(Aurora.hair).frame(height: 1) }
    }

    private var rodape: some View {
        HStack(spacing: 8) {
            Spacer()
            BotaoNotch(simbolo: "macwindow", legenda: "painel", ajuda: "Abrir painel") {
                modelo.abrirPainel()
            }
            BotaoNotch(simbolo: "gearshape", legenda: "config", ajuda: "Configurações") {
                modelo.abrirConfig()
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 10)
        .overlay(alignment: .top) { Rectangle().fill(Aurora.hair).frame(height: 1) }
    }

    private func textoUso(_ linha: LinhaLane) -> String {
        if let pct = linha.pct { return Formato.pct(pct) }
        return "sem medida"
    }

    private func barra(_ pct: Double?) -> some View {
        let atencao = (pct ?? 0) >= Uso.pctAtencao
        return BarraAurora(fracao: min(max((pct ?? 0) / 100, 0), 1),
                           cor: atencao ? Aurora.vermelho : Aurora.acento,
                           altura: 5)
    }

    private func hora(_ data: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: data)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

private struct BotaoNotch: View {
    var simbolo: String
    var legenda: String
    var ajuda: String
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 5) {
                Image(systemName: simbolo)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(legenda)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(hover ? Aurora.texto : Aurora.texto2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.10 : 0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
        .help(ajuda)
        .accessibilityLabel(ajuda)
    }
}

/// Botão circular de ligar/desligar lane no notch expandido.
/// Verde quando ativo, vermelho quando desativado.
struct BotaoLigarDesligar: View {
    var ligada: Bool
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hover ? 0.12 : 0.06))
                Circle()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ligada ? Aurora.verde : Aurora.vermelho)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
        .accessibilityLabel(ligada ? "Desativar lane" : "Reativar lane")
    }
}
