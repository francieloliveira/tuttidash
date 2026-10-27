import AppKit
import SwiftUI
import GastoCore

/// Estado e botões dos jobs do launchd (FRA-298). O painel de logs nunca vira job de login.
@MainActor
final class EstadoAgendas: ObservableObject {
    let modelo: ModeloAjustes
    @Published var estados: [String: EstadoTrabalho] = [:]
    @Published var status: [String: StatusAgente] = [:]
    @Published var instalados: Set<String> = []
    @Published var erro: String?

    init(modelo: ModeloAjustes) { self.modelo = modelo; atualizar() }

    var gerenciador: GerenciadorAgendas { GerenciadorAgendas(config: modelo.dados) }

    /// `launchctl` roda com `Process` + `waitUntilExit`: fica fora da main thread (FRA-339).
    func atualizar() {
        let g = gerenciador
        Task.detached(priority: .utility) { [weak self] in
            let inst = g.gerenciados()
            var est: [String: EstadoTrabalho] = [:]
            var st: [String: StatusAgente] = [:]
            let app = AgentesDoApp(registro: RegistroSMAppService())
            for t in g.trabalhos { est[t.label] = g.estado(t); if let a = AgentesDoApp.agente(antigo: t.label) { st[t.label] = app.status(a) } }
            let final = est, finalSt = st
            await MainActor.run { [weak self] in
                self?.instalados = inst
                self?.estados = final
                self?.status = finalSt
            }
        }
    }

    /// Labels com ação em andamento (o interruptor mostra o indicador).
    @Published var trabalhando: Set<String> = []

    /// Liga/desliga fora da main thread, com indicador na linha e aviso no fim (FRA-531).
    func alternarApp(_ t: Trabalho, ligar: Bool) {
        guard let agente = AgentesDoApp.agente(antigo: t.label), !trabalhando.contains(t.label) else { return }
        trabalhando.insert(t.label)
        let nome = t.nomeCurto
        Task.detached(priority: .userInitiated) { [weak self] in
            var falha: String?
            do {
                let app = AgentesDoApp(registro: RegistroSMAppService())
                if ligar { try app.ligar(agente) } else { try app.desligar(agente) }
            } catch { falha = MaquinaAcao.motivo(error) }
            let f = falha
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.trabalhando.remove(t.label)
                self.erro = f
                if let f { CentralAvisos.compartilhada.erro(String(localized: "Não deu para \(ligar ? "ligar" : "desligar") o \(nome)"), f) }
                else { CentralAvisos.compartilhada.ok(ligar ? String(localized: "\(nome) ligado") : String(localized: "\(nome) desligado")) }
                self.atualizar()
            }
        }
    }

    func executarApp(_ f: (AgentesDoApp) throws -> Void) {
        do { try f(AgentesDoApp(registro: RegistroSMAppService())); erro = nil } catch { erro = error.localizedDescription }
        atualizar()
    }

    func executar(_ f: (GerenciadorAgendas) throws -> Void) {
        do { try f(gerenciador); erro = nil } catch { erro = error.localizedDescription }
        atualizar()
    }
}

struct SecaoAgendas: View {
    @StateObject var estado: EstadoAgendas
    @State private var confirmar: Trabalho?

    /// O estado é criado uma vez só: a página se redesenha a cada poucos segundos (FRA-579).
    init(estado: @autoclosure @escaping () -> EstadoAgendas) {
        _estado = StateObject(wrappedValue: estado())
    }

    private func texto(_ e: EstadoTrabalho?) -> (String, Color) {
        switch e {
        case .ativo: return (String(localized: "ativo"), .green)
        case .erro(let m): return (String(localized: "erro: \(m)"), .red)
        default: return (String(localized: "parado"), .secondary)
        }
    }

    @State private var confirmarDesligar: Trabalho?

    private func chave(_ t: Trabalho) -> Binding<Bool> {
        Binding(get: { estado.status[t.label]?.ligado ?? false }, set: { novo in
            if novo { estado.alternarApp(t, ligar: true) }
            else if t.chave == "dispatcher" { confirmarDesligar = t }
            else { estado.alternarApp(t, ligar: false) }
        })
    }

    private func corStatus(_ s: StatusAgente?) -> Color {
        switch s {
        case .rodando: return PV.verde
        case .aguardando: return PV.azul
        case .precisaAprovacao: return PV.ambar
        default: return PV.apagado
        }
    }

    var body: some View {
        Section {
            ForEach(estado.gerenciador.trabalhos) { t in
                HStack(alignment: .center, spacing: DS.e3) {
                    IconeCartao(simbolo: t.simbolo, cor: corStatus(estado.status[t.label]),
                                fundo: corStatus(estado.status[t.label]).opacity(0.14), tamanho: 32, tamanhoIcone: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(t.nomeCurto).font(PV.fonte(13.5, .semibold))
                            HStack(spacing: 5) {
                                Circle().fill(corStatus(estado.status[t.label])).frame(width: 6, height: 6)
                                Text(estado.status[t.label]?.rotulo ?? String(localized: "lendo…"))
                            }
                            .font(PV.fonte(11)).foregroundStyle(corStatus(estado.status[t.label]))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(corStatus(estado.status[t.label]).opacity(0.12)))
                        }
                        Text(t.ajuda).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if estado.trabalhando.contains(t.label) { ProgressView().controlSize(.small) }
                    Toggle("", isOn: chave(t)).labelsHidden().toggleStyle(.switch)
                        .disabled(estado.trabalhando.contains(t.label))
                        .accessibilityLabel(t.nomeCurto)
                }
                .padding(.vertical, 3)
                .animation(DS.anim(DS.suave), value: estado.status[t.label])
            }
            if estado.status.values.contains(.precisaAprovacao) {
                Button(String(localized: "Abrir Itens de Login nos Ajustes do Sistema")) {
                    RegistroSMAppService.abrirItensDeLogin()
                }
            }
        }
        .confirmationDialog(String(localized: "Desligar o dispatcher?"),
                            isPresented: Binding(get: { confirmarDesligar != nil }, set: { if !$0 { confirmarDesligar = nil } })) {
            Button(String(localized: "Desligar"), role: .destructive) {
                if let t = confirmarDesligar { estado.alternarApp(t, ligar: false) }
                confirmarDesligar = nil
            }
        } message: {
            Text(String(localized: "As lanes param de receber cards novos até você ligar de novo. Isto não muda as lanes ligadas nem a pausa."))
        }
        .confirmationDialog(String(localized: "Substituir o agendamento atual deste job?"),
                            isPresented: Binding(get: { confirmar != nil }, set: { if !$0 { confirmar = nil } })) {
            Button(String(localized: "Instalar e recarregar")) {
                if let t = confirmar { estado.executar { try $0.instalar(t) } }
                confirmar = nil
            }
        } message: {
            Text(String(localized: "O plist e o lançador serão regravados a partir dos Ajustes e o job será recarregado."))
        }
    }
}
