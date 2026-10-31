import SwiftUI
import GastoCore

/// Toggles de enable das lanes (arquivo `enabled`): mesma fonte do dispatcher e da
/// janela tmux. Lane sem execução real continua ignorada pelo dispatcher (ver log).
@MainActor
final class EstadoLanesHabilitadas: ObservableObject {
    let stateDir: URL
    @Published var ligadas: Set<String>
    @Published var erro: String?
    /// Relê o painel e a pílula. Não grava `enabled` de novo.
    var aoMudar: () -> Void = {}

    init(stateDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".transcentia/lanes")) {
        self.stateDir = stateDir
        ligadas = LanesHabilitadas.ler(stateDir: stateDir)
    }

    /// FRA-421: verifica se o dispatcher existe no Mac.
    var dispatcherExiste: Bool {
        LanesHabilitadas.dispatcherExiste(stateDir: stateDir)
    }

    /// Alinha o interruptor ao arquivo, sem gravar. Vale ao abrir a seção.
    func recarregar() {
        let lidas = LanesHabilitadas.ler(stateDir: stateDir)
        if lidas != ligadas { ligadas = lidas }
        if erro != nil { erro = nil }
    }

    func alternar(_ lane: String, _ ligada: Bool) {
        // FRA-421: não gravar se o dispatcher não existe.
        guard dispatcherExiste else {
            erro = String(localized: "dispatcher não encontrado. Nada foi alterado.")
            CentralAvisos.compartilhada.erro(String(localized: "Dispatcher não encontrado"), String(localized: "Instale o dispatcher primeiro."))
            return
        }
        let anterior = ligadas
        if ligada { ligadas.insert(lane) } else { ligadas.remove(lane) }
        let titulo = ClarezaCota.titulo(nome: lane, rotulo: Agentes.def(lane)?.rotulo ?? lane)
        do {
            try LanesHabilitadas.gravar(ligadas, stateDir: stateDir)
            erro = nil
            CentralAvisos.compartilhada.ok(ligada ? String(localized: "Lane \(titulo) ligada") : String(localized: "Lane \(titulo) desligada"),
                                           ligada ? String(localized: "Ela pode receber cards no próximo ciclo do dispatcher.") : String(localized: "Ela termina o card atual e não pega outro."))
        } catch {
            ligadas = anterior
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            CentralAvisos.compartilhada.erro(String(localized: "Não deu para mudar a lane \(titulo)"), MaquinaAcao.motivo(error))
            return
        }
        aoMudar()
        atualizarJanela()
    }

    /// Recria os painéis que faltarem na janela tmux (melhor esforço, fora da UI).
    private func atualizarJanela() {
        let script = stateDir.appendingPathComponent("lanes_window.py")
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path, "ensure"]
            try? p.run()
            p.waitUntilExit()
        }
    }
}

struct SecaoLanesHabilitadas: View {
    @StateObject private var estado: EstadoLanesHabilitadas
    /// Embutido nos Ajustes: o título «Lanes ligadas» vem do grupo, não de outro Section.
    var embutido = false

    init(embutido: Bool = false) {
        let estado = EstadoLanesHabilitadas()
        estado.aoMudar = { NavegacaoPainel.compartilhada.aoSalvar() }
        _estado = StateObject(wrappedValue: estado)
        self.embutido = embutido
    }

    /// Só quem pega card. SuperGrok (via Cursor) fica na seção de baixo, sem interruptor,
    /// e essa linha não grava `enabled`.
    private var lanesQuePegamCard: [Agentes.Def] { Agentes.todos.filter(ClarezaCota.recebeCard) }
    private var contasDeUso: [Agentes.Def] { Agentes.todos.filter(ClarezaCota.contaDeUso) }

    var body: some View {
        Group {
            if embutido {
                conteudo
                if !contasDeUso.isEmpty {
                    let nomes = contasDeUso.map(\.nome)
                    SubtituloAjuste(texto: ClarezaCota.tituloSecaoUso(nomes: nomes),
                                    ajuda: ClarezaCota.ajudaSecaoUso(nomes: nomes))
                    linhasContas
                }
            } else {
                Section {
                    conteudo
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Lanes ligadas")).font(.headline).foregroundStyle(.white)
                        Text(ClarezaCota.ajudaLanesLigadas)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !contasDeUso.isEmpty {
                    let nomes = contasDeUso.map(\.nome)
                    Section {
                        linhasContas
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ClarezaCota.tituloSecaoUso(nomes: nomes)).font(.headline).foregroundStyle(.white)
                            Text(ClarezaCota.ajudaSecaoUso(nomes: nomes))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear { estado.recarregar() }
    }

    @ViewBuilder
    private var conteudo: some View {
        if !estado.dispatcherExiste {
            // FRA-421: estado vazio claro quando não há dispatcher.
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Dispatcher não encontrado")).font(.headline).foregroundStyle(.white)
                Text(String(localized: "O TuttiDash precisa do dispatcher para gerenciar lanes. Instale o dispatcher e tente novamente."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        } else {
            ForEach(lanesQuePegamCard, id: \.nome) { lane in
                linhaToggle(lane)
            }
            if let e = estado.erro { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var linhasContas: some View {
        ForEach(contasDeUso, id: \.nome) { conta in
            let textos = ClarezaCota.linhaLane(conta)
            HStack(alignment: .center, spacing: 8) {
                rotulo(textos, ligada: nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ClarezaCota.seloNaoELane)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PV.azul)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(textos.titulo). \(textos.detalhe ?? "") \(ClarezaCota.seloNaoELane)")
        }
    }

    /// Uma linha só: título, ponto e interruptor. O subtítulo longo ia só no Grok e,
    /// com o rodapé da Section, o Form desenhava essa lane fora do grupo.
    private func linhaToggle(_ lane: Agentes.Def) -> some View {
        let textos = ClarezaCota.linhaLista(lane)
        let ligada = estado.ligadas.contains(lane.nome)
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(ligada ? PV.verde : PV.apagado)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(textos.titulo)
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            Toggle(isOn: Binding(
                get: { estado.ligadas.contains(lane.nome) },
                set: { novo in comAnimacao(DS.suave) { estado.alternar(lane.nome, novo) } })) {
                Text(textos.titulo)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .id(ligada)
            .accessibilityHint(ClarezaCota.detalhe(nome: lane.nome) ?? ClarezaCota.ajudaLanesLigadas)
        }
        .help(ClarezaCota.detalhe(nome: lane.nome) ?? textos.titulo)
    }

    /// `ligada == nil`: conta de uso, ponto azul (não é um interruptor desligado).
    private func rotulo(_ textos: ClarezaCota.LinhaAjuste, ligada: Bool?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(ligada.map { $0 ? PV.verde : PV.apagado } ?? PV.azul)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(textos.titulo)
                if let detalhe = textos.detalhe {
                    Text(detalhe)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
