import AppKit
import SwiftUI
import GastoCore

/// Modelo do Ollama nos Ajustes: escolha entre os baixados, estado do Ollama e «Baixar»
/// com progresso. Nada é baixado nem instalado sem clique.
@MainActor
final class EstadoOllama: ObservableObject {
    @Published var instalado = false
    @Published var modelos: [String]?
    @Published var conferindo = false
    @Published var baixando: String?
    @Published var progresso: Double?
    @Published var etapa = ""
    @Published var erro: String?

    func conferir() {
        conferindo = true
        Task {
            let lista = await OllamaLocal.modelos()
            self.instalado = OllamaLocal.instalado()
            self.modelos = lista
            self.conferindo = false
        }
    }

    func baixar(_ modelo: String) {
        let m = modelo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, baixando == nil else { return }
        baixando = m; progresso = nil; etapa = String(localized: "começando"); erro = nil
        Task {
            do {
                try await OllamaLocal.baixar(m) { p in
                    Task { @MainActor in
                        self.etapa = p.status
                        if let f = p.fracao { self.progresso = f }
                    }
                }
            } catch {
                self.erro = error.localizedDescription
            }
            self.baixando = nil
            self.progresso = nil
            self.conferir()
        }
    }

    func abrirOllama() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.conferir()
            }
        }
    }
}

struct BlocoOllama: View {
    let modelo: ModeloAjustes
    var aoSalvar: () -> Void
    @StateObject private var estado = EstadoOllama()
    @State private var escolhido = ""
    @State private var outro = ""

    private var gravado: String {
        (Configuracao.valor(OllamaLocal.chaveModelo, em: modelo.dados) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var situacao: OllamaLocal.Estado {
        OllamaLocal.estado(instalado: estado.instalado, modelos: estado.modelos, escolhido: escolhido)
    }

    /// Baixados + o gravado (mesmo se não baixado, para não sumir da tela).
    private var opcoes: [String] {
        var lista = estado.modelos ?? []
        if !escolhido.isEmpty, !lista.contains(where: { OllamaLocal.mesmoModelo($0, escolhido) }) { lista.insert(escolhido, at: 0) }
        return lista
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.e2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: situacao.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(situacao.ok ? Color.green : Color.orange)
                Text(situacao.texto).fontePainel(12.5).foregroundStyle(PV.texto)
                Spacer()
                if estado.conferindo { ProgressView().controlSize(.small) }
                acao
            }
            Picker(String(localized: "Modelo da triagem"), selection: $escolhido) {
                Text(String(localized: "Primeiro baixado")).tag("")
                ForEach(opcoes, id: \.self) { m in
                    let baixado = (estado.modelos ?? []).contains { OllamaLocal.mesmoModelo($0, m) }
                    Text(baixado ? m : String(localized: "\(m) (não baixado)")).tag(m)
                }
            }
            .onChange(of: escolhido) { _, novo in gravar(novo) }
            HStack(spacing: 8) {
                TextField(String(localized: "Baixar outro modelo (ex.: qwen2.5-coder:14b)"), text: $outro)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { estado.baixar(outro) }
                Button(String(localized: "Baixar")) { estado.baixar(outro) }
                    .disabled(outro.trimmingCharacters(in: .whitespaces).isEmpty || estado.baixando != nil
                              || estado.modelos == nil)
            }
            if let m = estado.baixando {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = estado.progresso {
                        ProgressView(value: p) {
                            Text(String(localized: "Baixando \(m): \(Int((p * 100).rounded()))%"))
                                .fontePainel(11.5).foregroundStyle(PV.texto2)
                        }
                    } else {
                        ProgressView { Text(String(localized: "Baixando \(m)")).fontePainel(11.5).foregroundStyle(PV.texto2) }
                    }
                    Text(estado.etapa).fontePainel(11).foregroundStyle(PV.mudo).lineLimit(1).truncationMode(.middle)
                }
            }
            if let e = estado.erro {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(String(localized: "Modelos têm vários GB: o download só começa com o clique e continua em segundo plano no Ollama."))
                .fontePainel(11.5).foregroundStyle(PV.mudo)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            escolhido = gravado
            estado.conferir()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            estado.conferir()
        }
    }

    @ViewBuilder
    private var acao: some View {
        switch situacao {
        case .naoInstalado:
            Link(String(localized: "Baixar o Ollama"), destination: OllamaLocal.paginaDownload)
        case .parado:
            Button(String(localized: "Abrir Ollama")) { estado.abrirOllama() }
        case .naoBaixado(let m):
            Button(String(localized: "Baixar")) { estado.baixar(m) }
                .disabled(estado.baixando != nil)
        case .semModelo, .pronto:
            Button(String(localized: "Conferir de novo")) { estado.conferir() }
                .disabled(estado.conferindo)
        }
    }

    private func gravar(_ valor: String) {
        guard valor != gravado else { return }
        do {
            try modelo.definirValor(OllamaLocal.chaveModelo, valor)
            aoSalvar()
        } catch {
            estado.erro = error.localizedDescription
        }
    }
}
