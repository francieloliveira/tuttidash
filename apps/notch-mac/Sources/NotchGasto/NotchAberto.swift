import SwiftUI
import GastoCore

/// Notch expandido: uma linha por lane, resumo de testes, lock, custo do dia e três ícones.
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
                    Text(aviso)
                        .font(.sf(11))
                        .foregroundStyle(TemaPainel.amarelo)
                        .padding(.top, 6)
                }
            } else {
                Text("Lendo o estado das lanes…")
                    .font(.sf(12))
                    .foregroundStyle(TemaPainel.mudo)
                    .padding(.vertical, 28)
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
                    .font(.sf(12, .semibold))
                    .foregroundStyle(TemaPainel.texto)
                Spacer(minLength: modelo.temNotch ? modelo.larguraNotch : 8)
                Text(hora(ctx.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TemaPainel.mudo)
            }
            .frame(height: modelo.alturaNotch)
        }
    }

    private func linhaLane(_ linha: LinhaLane, selecionada: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(linha.estado == .desligada ? TemaPainel.apagado : TemaPainel.cor(linha.lane))
                    .frame(width: 8, height: 8)
                Text(linha.lane)
                    .font(.sf(12, .semibold))
                    .foregroundStyle(TemaPainel.texto)
            }
            .frame(width: 92, alignment: .leading)
            .opacity(linha.estado == .desligada ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(linha.estado == .desligada ? "desligada" : linha.descricao)
                    .font(.sf(12))
                    .foregroundStyle(linha.estado == .desligada ? TemaPainel.mudo : TemaPainel.texto)
                    .lineLimit(1)
                if let texto = linha.textoModelo {
                    if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                        Text(texto + " · " + aviso)
                            .font(.system(size: 10))
                            .foregroundStyle(TemaPainel.amarelo)
                            .lineLimit(1)
                    } else {
                        Text(texto)
                            .font(.system(size: 10))
                            .foregroundStyle(TemaPainel.mudo)
                            .lineLimit(1)
                    }
                } else if let aviso = linha.avisoModelo, aviso != "modelo fixo" {
                    Text(aviso).font(.system(size: 10)).foregroundStyle(TemaPainel.amarelo).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if linha.estado != .desligada {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(textoUso(linha))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TemaPainel.mudo)
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
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TemaPainel.mudo)
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
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .background(selecionada ? TemaPainel.ciano.opacity(0.06) : Color.clear)
    }

    private func linhaResumo(_ titulo: String, _ valor: String, destaque: Bool) -> some View {
        HStack {
            Text(titulo).font(.sf(12)).foregroundStyle(TemaPainel.mudo)
            Spacer()
            Text(valor)
                .font(.sf(12, .medium))
                .foregroundStyle(destaque ? TemaPainel.vermelho : TemaPainel.texto)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private var rodape: some View {
        HStack {
            Spacer()
            BotaoNotch(simbolo: "macwindow", legenda: "painel", ajuda: "Abrir painel", perigo: false) {
                modelo.abrirPainel()
            }
            BotaoNotch(simbolo: "gearshape", legenda: "config", ajuda: "Configurações", perigo: false) {
                modelo.abrirConfig()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func textoUso(_ linha: LinhaLane) -> String {
        if let pct = linha.pct { return Formato.pct(pct) }
        return "sem medida"
    }

    private func barra(_ pct: Double?) -> some View {
        GeometryReader { g in
            let fracao = min(max((pct ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: (pct ?? 0) >= Uso.pctAtencao
                                         ? [TemaPainel.amarelo, TemaPainel.vermelho]
                                         : [TemaPainel.ciano, TemaPainel.violeta],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(g.size.width * fracao, pct == nil ? 0 : 2))
            }
        }
        .frame(height: 5)
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
    var perigo: Bool
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            VStack(spacing: 1) {
                Image(systemName: simbolo)
                    .font(.system(size: 12, weight: .regular))
                Text(legenda)
                    .font(.system(size: 7))
            }
            .foregroundStyle(cor)
            .frame(width: 46, height: 28)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(ajuda)
    }

    private var cor: Color {
        if perigo && hover { return Color(hex: 0xFFB347) }
        return TemaPainel.texto.opacity(hover ? 0.9 : 0.38)
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
                    .fill(Color.white.opacity(hover ? 0.12 : 0.08))
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ligada ? TemaPainel.verde : TemaPainel.vermelho)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
