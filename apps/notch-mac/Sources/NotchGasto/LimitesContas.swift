import SwiftUI
import GastoCore

/// Nome curto da conta no painel, no selo do recolhido e no menu.
/// Apelido da config (`contas[].nome`) fica; `cursor` e `grok` crus viram SuperGrok e Grok CLI.
func nomeConta(_ uso: UsoConta) -> String {
    ClarezaCota.nomeCurto(tipo: uso.tipo.isEmpty ? uso.conta : uso.tipo, nome: uso.nome, rotulo: uso.rotulo)
}

/// Card "Limites das contas": uma barra por conta (as da lista `contas` da config) com o % da janela mais
/// apertada e o horário do reset. Verde até 80%, amarelo de 80 a 95%, vermelho de 95% em diante.
/// Conta sem fonte real de dado mostra "sem dado" e o motivo — nunca um número inventado.
struct LimitesContas: View {
    var usos: [UsoConta]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TituloCard(texto: "Limites das contas") {
                Text("janela mais apertada").font(.sf(11, .medium)).foregroundStyle(Tema.t4)
            }
            if usos.isEmpty {
                Text("Lendo os limites das contas…")
                    .font(.sf(11)).foregroundStyle(Tema.t3).padding(.top, 8)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(spacing: 0) {
                        ForEach(Array(usos.enumerated()), id: \.element.conta) { i, u in
                            if i > 0 { Rectangle().fill(Tema.hair).frame(height: 0.5).padding(.vertical, 2) }
                            LinhaUsoConta(uso: u, agora: ctx.date)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.top, 11).padding(.horizontal, 14).padding(.bottom, 11)
    }
}

struct LinhaUsoConta: View {
    var uso: UsoConta
    var agora: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            selo
            VStack(alignment: .leading, spacing: 5) {
                cabecalho
                HStack(spacing: 9) {
                    barra
                    detalhe
                }
            }
        }
        .padding(.vertical, 5)
        .help(ajuda)
    }

    private var cor: Color {
        uso.nivel.map { Tema.cor(nivelUso: $0) } ?? Tema.t3
    }

    private var selo: some View {
        let base = Tema.cor(lane: uso.tipo)
        let sigla = uso.sigla.isEmpty ? String(uso.conta.prefix(1)).uppercased() : uso.sigla
        return Text(sigla)
            .font(.sf(12, .bold)).foregroundStyle(base)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(base.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(base.opacity(0.35), lineWidth: 0.5))
    }

    private var cabecalho: some View {
        HStack(spacing: 7) {
            Text(nomeConta(uso)).font(.sf(12.5, .semibold)).foregroundStyle(Tema.t1)
            if let j = uso.critica {
                Text(j.rotulo).font(.sf(11)).foregroundStyle(Tema.t3)
                Text(Formato.pct(j.pct)).font(.sf(12.5, .bold)).monospacedDigit().foregroundStyle(cor)
                Text("usado · falta \(Formato.pct(j.faltaPct))").font(.sf(11)).foregroundStyle(Tema.t3)
            } else {
                Text("sem dado").font(.sf(11.5, .medium)).foregroundStyle(Tema.t3)
            }
            Spacer(minLength: 4)
            if let j = uso.critica, let r = j.resetEm {
                Text("reseta \(Formato.quando(r, agora: agora)) · \(Formato.faltam(r, agora: agora))")
                    .font(.sf(11)).monospacedDigit().foregroundStyle(Tema.t2)
            } else if uso.critica != nil {
                Text("reset não informado").font(.sf(11)).foregroundStyle(Tema.t3)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var barra: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                if let pct = uso.pct {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [cor.opacity(0.75), cor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(g.size.width * min(pct / 100, 1), 3))
                }
            }
        }
        .frame(height: 5)
    }

    private var detalhe: some View {
        Group {
            if precisaLogin {
                Button(action: abrirLogin) {
                    Text(detalheTexto).font(.sf(10.5)).monospacedDigit()
                        .foregroundStyle(Tema.warn.opacity(0.85))
                        .lineLimit(1).fixedSize()
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Clique para abrir o login no Terminal")
            } else {
                Text(detalheTexto).font(.sf(10.5)).monospacedDigit()
                    .foregroundStyle(uso.temDado ? Tema.t3 : Tema.warn.opacity(0.85))
                    .lineLimit(1).fixedSize()
            }
        }
    }

    /// Com dado: todas as janelas em sequência. Sem dado: o motivo.
    private var detalheTexto: String {
        guard uso.temDado else { return uso.motivo ?? "sem dado" }
        var partes = uso.janelas.map { "\($0.rotulo) \(Formato.pct($0.pct))" }
        // dado antigo guardado em memória: diz desde quando e por quê
        if let motivo = uso.motivo {
            if let em = uso.atualizadoEm { partes.append(Formato.ha(em, agora: agora)) }
            partes.append(motivo)
        }
        return partes.joined(separator: " · ")
    }

    private var ajuda: String {
        let tipo = uso.tipo.isEmpty ? uso.conta : uso.tipo
        let metodo = (tipo == "cursor" || tipo == "gemini") ? "POST de consulta" : "GET"
        let nome = ClarezaCota.rotuloAjuda(tipo: tipo, rotulo: uso.rotulo)
        var t = "\(nome) · fonte: \(uso.fonte) (só leitura, \(metodo))"
        if let nota = ClarezaCota.notaCota(tipo) { t += "\n\(nota)" }
        if let em = uso.atualizadoEm { t += "\nlido \(Formato.ha(em, agora: agora))" }
        if let m = uso.motivo { t += "\n\(m)" }
        if precisaLogin { t += "\nClique para abrir o login no Terminal." }
        return t
    }

    /// Sem credencial local: o login é interativo (OAuth no navegador), então o app não
    /// consegue fazer sozinho — mas o clique abre a janela do Terminal com o comando pronto.
    private var precisaLogin: Bool {
        !uso.temDado && (uso.motivo?.contains("sem credencial") ?? false)
    }

    private var comandoLogin: String? {
        // O comando base é o `cli` do manifesto (`agents.d/`); só o subcomando de
        // login é específico de cada CLI. Conta sem CLI (cursor) não tem comando.
        guard let cli = Agentes.def(uso.tipo)?.cli else { return nil }
        return uso.tipo == "opencode" ? "\(cli) auth login" : cli
    }

    private func abrirLogin() {
        if uso.tipo == "cursor" {
            NSWorkspace.shared.launchApplication("Cursor")
            return
        }
        guard let cmd = comandoLogin else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuttidash-login-\(uso.conta).command")
        try? ("#!/bin/zsh\n\(cmd)\n".write(to: url, atomically: true, encoding: .utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open([url],
                                 withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                 configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Selo de alerta do estado recolhido ("⚠ claude · semana 93%").
/// Sempre diz a conta (e a janela, quando há espaço): o selo fica ao lado da lane do card rodando,
/// e sem o nome o % parecia ser daquela lane. O número é o mesmo da linha em "Limites das contas".
struct AvisoUso: View {
    var uso: UsoConta
    var nivel: NivelAviso

    var body: some View {
        let cor = uso.nivel.map { Tema.cor(nivelUso: $0) } ?? Tema.warn
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            if nivel < .soPct { Text(nomeConta(uso)).font(.sf(11, .semibold)) }
            if nivel == .completo, let j = uso.critica { Text(j.rotulo).font(.sf(10.5)).opacity(0.8) }
            Text(Formato.pct(uso.pct ?? 0)).font(.sf(11.5, .bold)).monospacedDigit()
        }
        .foregroundStyle(cor)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(cor.opacity(0.14)))
        .overlay(Capsule().strokeBorder(cor.opacity(0.4), lineWidth: 0.5))
        .help(ajuda)
    }

    private var ajuda: String {
        let tipo = uso.tipo.isEmpty ? uso.conta : uso.tipo
        let nome = ClarezaCota.rotuloAjuda(tipo: tipo, rotulo: uso.rotulo)
        let nota = ClarezaCota.notaCota(tipo).map { "\n\($0)" } ?? ""
        guard let j = uso.critica else { return "\(nome): sem dado\(nota)" }
        return "\(nome): \(Formato.pct(j.pct)) da janela de \(j.rotulo) · falta \(Formato.pct(j.faltaPct))\(nota)"
    }
}
