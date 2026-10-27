import AppKit
import SwiftUI
import GastoCore

/// Ferramentas e logins (FRA-570): o que falta, com Instalar e Entrar. Os botões abrem o Terminal
/// com o comando oficial; a tela confere de novo quando o app volta a ficar ativo.
@MainActor
final class EstadoFerramentas: ObservableObject {
    @Published var lista: [Ferramenta] = []
    @Published var conferindo = false
    @Published var erro: String?

    var temBrew: Bool { lista.first { $0.id == "brew" }?.encontrada != nil }

    func conferir() {
        guard !conferindo else { return }
        conferindo = true
        let todas = Ferramentas.base() + Ferramentas.agentes(CatalogoAgentes.carregar())
        Task.detached(priority: .userInitiated) {
            let r = Ferramentas.conferir(todas)
            await MainActor.run { self.lista = r; self.conferindo = false }
        }
    }

    func instalar(_ f: Ferramenta) {
        if f.precisaBrew && !temBrew {
            erro = String(localized: "Instale o Homebrew primeiro (primeira linha da lista).")
            return
        }
        abrir(f, titulo: String(localized: "Instalar \(f.nome)"), comando: f.instalar, dica: "")
    }

    func entrar(_ f: Ferramenta) {
        abrir(f, titulo: String(localized: "Entrar no \(f.nome)"), comando: f.entrar, dica: f.dicaEntrar)
    }

    private func abrir(_ f: Ferramenta, titulo: String, comando: String, dica: String) {
        erro = Ferramentas.abrirNoTerminal(id: f.id, titulo: titulo, comando: comando, dica: dica, docs: f.docs)
            ? nil : String(localized: "Não consegui abrir o Terminal. O comando é: \(comando)")
    }
}

struct SecaoFerramentas: View {
    @StateObject private var estado = EstadoFerramentas()

    var body: some View {
        Section {
            if let e = estado.erro {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(estado.lista) { f in
                LinhaFerramenta(f: f, estado: estado)
            }
            HStack {
                if estado.conferindo { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Conferir de novo")) { estado.conferir() }
                    .disabled(estado.conferindo)
            }
        } header: {
            Text(String(localized: "Ferramentas e logins"))
        } footer: {
            Text(String(localized: "Instalar e Entrar abrem o Terminal com o comando oficial. Ele mostra o comando e só roda depois do Enter. Para os agentes, Entrar abre o CLI: na primeira vez ele pede o login."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { estado.conferir() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            estado.conferir()
        }
    }
}

private struct LinhaFerramenta: View {
    let f: Ferramenta
    @ObservedObject var estado: EstadoFerramentas

    private var icone: (String, Color) {
        if f.encontrada == nil { return f.opcional ? ("circle.dashed", .secondary) : ("exclamationmark.triangle.fill", .orange) }
        if f.conectada == false { return ("person.crop.circle.badge.exclamationmark", .orange) }
        return ("checkmark.circle.fill", .green)
    }

    private var situacao: String {
        if f.encontrada == nil { return f.opcional ? String(localized: "Opcional, não instalado") : String(localized: "Não instalado") }
        if f.conectada == false { return String(localized: "Instalado, falta entrar") }
        if f.conectada == true { return String(localized: "Instalado e conectado") }
        return String(localized: "Instalado")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icone.0).foregroundStyle(icone.1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.nome).bold()
                    Text(situacao).font(.caption).foregroundStyle(.secondary)
                }
                Text(f.paraQue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = f.docs {
                Link(destination: d) { Image(systemName: "book") }
                    .help(String(localized: "Documentação oficial"))
            }
            if f.encontrada == nil {
                Button(String(localized: "Instalar")) { estado.instalar(f) }
                    .disabled(f.precisaBrew && !estado.temBrew)
                    .help(f.precisaBrew && !estado.temBrew ? String(localized: "Precisa do Homebrew") : f.instalar)
            } else if !f.entrar.isEmpty {
                Button(f.conectada == true ? String(localized: "Entrar de novo") : String(localized: "Entrar")) { estado.entrar(f) }
                    .help(f.entrar)
            }
        }
    }
}
