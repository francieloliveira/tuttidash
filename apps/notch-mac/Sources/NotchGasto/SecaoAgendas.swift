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
    @Published var avisoIntegridade: String?
    @Published var doutorTexto: String?

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
            let home = FileManager.default.homeDirectoryForCurrentUser
            let veredito = IntegridadeControle.atual()
            let agente = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tuttidash-agente").path
            let extra = FileManager.default.isExecutableFile(atPath: agente) ? agente : nil
            let doutor = DoutorControle.avaliar(pistas: DoutorControle.pistas(home: home, bundleAgente: extra), veredito: veredito)
            let aviso = veredito.aviso
            let textoDoutor = doutor.texto
            let final = est, finalSt = st
            await MainActor.run { [weak self] in
                self?.instalados = inst
                self?.estados = final
                self?.status = finalSt
                self?.avisoIntegridade = aviso
                self?.doutorTexto = textoDoutor
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

    /// Chave Geral (FRA-682): liga/desliga o lote fora da main thread, com um refresh só no fim.
    /// Um serviço que falha não impede o outro: no fim, o erro aparece e o estado relido manda.
    func alternarTodos(_ lista: [Trabalho], ligar: Bool) {
        let alvos = lista.filter { !trabalhando.contains($0.label) }
        guard !alvos.isEmpty else { return }
        for t in alvos { trabalhando.insert(t.label) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var falha: String?
            let app = AgentesDoApp(registro: RegistroSMAppService())
            for t in alvos {
                guard let agente = AgentesDoApp.agente(antigo: t.label) else { continue }
                do { if ligar { try app.ligar(agente) } else { try app.desligar(agente) } }
                catch { falha = "\(t.nomeCurto): \(MaquinaAcao.motivo(error))" }
            }
            let f = falha
            await MainActor.run { [weak self] in
                guard let self else { return }
                for t in alvos { self.trabalhando.remove(t.label) }
                self.erro = f
                if let f {
                    CentralAvisos.compartilhada.erro(String(localized: "Não deu para \(ligar ? "ligar" : "desligar") a automação"), f)
                } else {
                    CentralAvisos.compartilhada.ok(ligar ? String(localized: "Chave Geral ligada") : String(localized: "Chave Geral desligada"))
                }
                self.atualizar()
            }
        }
    }

    func executarApp(_ f: @escaping (AgentesDoApp) throws -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            var falha: String?
            do { try f(AgentesDoApp(registro: RegistroSMAppService())) } catch { falha = error.localizedDescription }
            let msg = falha
            await MainActor.run { [weak self] in
                self?.erro = msg
                self?.atualizar()
            }
        }
    }

    /// `launchctl` fica fora da MainActor: `waitUntilExit` reentra no run loop (FRA-608).
    func executar(_ f: @escaping (GerenciadorAgendas) throws -> Void) {
        let g = gerenciador
        Task.detached(priority: .userInitiated) { [weak self] in
            var falha: String?
            do { try f(g) } catch { falha = error.localizedDescription }
            let msg = falha
            await MainActor.run { [weak self] in
                self?.erro = msg
                self?.atualizar()
            }
        }
    }
}

struct SecaoAgendas: View {
    @StateObject var estado: EstadoAgendas
    /// Embutido nos Ajustes: o título vem do grupo, não de outro Section.
    var embutido = false
    @State private var confirmar: Trabalho?

    /// O estado é criado uma vez só: a página se redesenha a cada poucos segundos (FRA-579).
    init(estado: @autoclosure @escaping () -> EstadoAgendas, embutido: Bool = false) {
        _estado = StateObject(wrappedValue: estado())
        self.embutido = embutido
    }

    @State private var confirmarDesligar: Trabalho?

    /// Os serviços que a Chave Geral comanda (a TuttiChave saiu da lista: FRA-682).
    private var servicos: [Trabalho] { estado.gerenciador.trabalhos }

    /// Chave Geral ligada = pelo menos um dos dois serviços está de pé.
    private var chaveGeralLigada: Bool {
        servicos.contains { estado.status[$0.label]?.ligado ?? false }
    }

    /// Ainda não leu o launchd: não deixa clicar em cima de um estado desconhecido.
    private var lendo: Bool { servicos.contains { estado.status[$0.label] == nil } }

    private var seloChaveGeral: (String, Color) {
        guard !lendo else { return (String(localized: "lendo…"), PV.apagado) }
        let ligados = servicos.filter { estado.status[$0.label]?.ligado ?? false }.count
        if ligados == 0 { return (String(localized: "desligada"), PV.apagado) }
        return (String(localized: "ligada · \(ligados) de \(servicos.count)"), PV.verde)
    }

    /// Chave Geral: liga ou desliga o Dispatcher e o Vigia de uma vez (FRA-682).
    /// Não interrompe lane nenhuma: para isso existe «Sair e parar as lanes».
    private func alternarChaveGeral(_ ligar: Bool) {
        estado.alternarTodos(servicos, ligar: ligar)
    }

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

    @ViewBuilder
    private var conteudo: some View {
        if let aviso = estado.avisoIntegridade {
            Text(aviso)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("integridade-controle")
        }
        if let doutor = estado.doutorTexto {
            Text(doutor)
                .font(.caption)
                .foregroundStyle(doutor.contains("não confere") || doutor.contains("legado") ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("doutor-controle")
        }
        // Chave Geral: o interruptor único. Fica acima dos dois serviços e reflete o conjunto.
        HStack(alignment: .center, spacing: DS.e3) {
            let selo = seloChaveGeral
            IconeCartao(simbolo: "power", cor: chaveGeralLigada ? PV.verde : PV.apagado,
                        fundo: (chaveGeralLigada ? PV.verde : PV.apagado).opacity(0.14), tamanho: 32, tamanhoIcone: 15)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(String(localized: "Chave Geral")).fontePainel(13.5, .semibold)
                    HStack(spacing: 5) {
                        Circle().fill(selo.1).frame(width: 6, height: 6)
                        Text(selo.0)
                    }
                    .fontePainel(11).foregroundStyle(selo.1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(selo.1.opacity(0.12)))
                }
                Text(String(localized: "Liga ou desliga o Dispatcher e o Vigia de uma vez. Para controle pontual, use o interruptor de cada um. As lanes que já estão rodando continuam; para interrompê-las, use TuttiDash › Sair e parar as lanes."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !estado.trabalhando.isEmpty { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { chaveGeralLigada }, set: { alternarChaveGeral($0) }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(lendo || !estado.trabalhando.isEmpty)
                .accessibilityLabel(String(localized: "Chave Geral"))
                .accessibilityIdentifier("chave-geral")
        }
        .padding(.vertical, 3)
        .animation(DS.anim(DS.suave), value: chaveGeralLigada)

        Divider().padding(.vertical, 2)

        ForEach(servicos) { t in
            HStack(alignment: .center, spacing: DS.e3) {
                IconeCartao(simbolo: t.simbolo, cor: corStatus(estado.status[t.label]),
                            fundo: corStatus(estado.status[t.label]).opacity(0.14), tamanho: 32, tamanhoIcone: 15)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(t.nomeCurto).fontePainel(13.5, .semibold)
                        HStack(spacing: 5) {
                            Circle().fill(corStatus(estado.status[t.label])).frame(width: 6, height: 6)
                            Text(estado.status[t.label]?.rotulo ?? String(localized: "lendo…"))
                        }
                        .fontePainel(11).foregroundStyle(corStatus(estado.status[t.label]))
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

    var body: some View {
        Group {
            if embutido {
                conteudo
            } else {
                Section { conteudo }
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
