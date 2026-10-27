import SwiftUI
import GastoCore

/// FRA-531: «Quem cuida das lanes». A TuttiChave não é um interruptor geral: ela decide quem cuida
/// das lanes, o gestor (Grok Bot) ou o vigia no Mac. A tela só grava `bots_chave.modo_forcado` e roda o
/// bots-chave; nunca cria nem apaga PAUSE, PAUSE.manual ou `enabled`.
@MainActor
final class EstadoGestaoLanes: ObservableObject {
    let gestao: GestaoLanes
    @Published var modo: ModoForcado
    @Published var quem: QuemCuida?
    @Published var lidoEm: Date?
    @Published var aplicando = false
    @Published var chaveLigada: Bool?

    init(modelo: ModeloAjustes) {
        gestao = GestaoLanes(modelo: modelo)
        modo = gestao.modo
        recarregar()
    }

    func recarregar() {
        let g = gestao
        Task.detached(priority: .utility) { [weak self] in
            let app = AgentesDoApp(registro: RegistroSMAppService())
            let chave = AgentesDoApp.todos.first { $0.novo.hasSuffix(".chave") }.map { app.status($0).ligado }
            let q = g.quemCuida(chaveLigada: chave)
            await MainActor.run { [weak self] in
                guard let self else { return }
                comAnimacao(DS.suave) { self.chaveLigada = chave; self.quem = q; self.lidoEm = Date() }
            }
        }
    }

    /// Grava e roda o bots-chave fora da main thread; depois relê quem está cuidando.
    func escolher(_ m: ModoForcado, aoSalvar: @escaping () -> Void) {
        guard m != modo, !aplicando else { return }
        let anterior = modo
        modo = m
        do { try gestao.modelo.definirValor(ModoForcado.chave, m.rawValue) } catch {
            modo = anterior
            CentralAvisos.compartilhada.erro(String(localized: "Não foi possível gravar a escolha"), MaquinaAcao.motivo(error))
            return
        }
        aoSalvar()
        aplicando = true
        let g = gestao, chave = chaveLigada
        Task.detached(priority: .userInitiated) { [weak self] in
            let codigo = g.executar(g.script)
            let q = g.quemCuida(chaveLigada: chave)
            await MainActor.run { [weak self] in
                guard let self else { return }
                comAnimacao(DS.suave) { self.quem = q; self.lidoEm = Date(); self.aplicando = false }
                if codigo != 0 {
                    CentralAvisos.compartilhada.erro(String(localized: "A TuttiChave não conseguiu aplicar"),
                                                     String(localized: "Ela saiu com código \(Int(codigo)). A escolha ficou gravada e vale na próxima conferência."))
                } else {
                    CentralAvisos.compartilhada.ok(String(localized: "Escolha aplicada: \(m.rotulo)"), q.titulo)
                }
            }
        }
    }
}

struct SecaoGestaoLanes: View {
    @ObservedObject var estado: EstadoGestaoLanes
    var aoSalvar: () -> Void

    private var cor: Color {
        switch estado.quem?.responsavel {
        case .gestor: return PV.azul
        case .vigia: return PV.teal
        case .pausaGeral: return PV.ambar
        default: return PV.mudo
        }
    }

    private var simbolo: String {
        switch estado.quem?.responsavel {
        case .gestor: return "person.crop.circle.badge.checkmark"
        case .vigia: return "eye.circle"
        case .pausaGeral: return "pause.circle"
        default: return "questionmark.circle"
        }
    }

    var body: some View {
        Section {
            // Quem está cuidando agora, e por quê.
            HStack(alignment: .top, spacing: DS.e3) {
                Image(systemName: simbolo).font(.system(size: 26, weight: .medium)).foregroundStyle(cor)
                    .frame(width: 34).contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 4) {
                    if let q = estado.quem {
                        Text(q.titulo).font(PV.fonte(15, .semibold)).foregroundStyle(PV.texto)
                        Text(q.motivo).font(PV.fonte(12.5)).foregroundStyle(PV.texto2).fixedSize(horizontal: false, vertical: true)
                        ForEach(q.avisos, id: \.self) { a in
                            Label(a, systemImage: "exclamationmark.triangle").font(PV.fonte(12)).foregroundStyle(PV.ambar)
                        }
                    } else {
                        Esqueleto(altura: 16, largura: 180); Esqueleto(altura: 12, largura: 320)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    SeloAtualizado(data: estado.lidoEm, carregando: estado.aplicando)
                    Button { estado.recarregar() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(String(localized: "Ler de novo"))
                }
            }
            .padding(.vertical, 4)
            .animation(DS.anim(DS.suave), value: estado.quem)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Quem decide"))
                    Text(String(localized: "No automático, o gestor cuida enquanto o uso do Grok Bot está abaixo do limite; depois, o vigia assume."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if estado.aplicando { ProgressView().controlSize(.small) }
                Picker("", selection: Binding(get: { estado.modo }, set: { estado.escolher($0, aoSalvar: aoSalvar) })) {
                    ForEach(ModoForcado.allCases) { Text($0.rotulo).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .disabled(estado.aplicando)
            }
        } header: {
            Text(String(localized: "Quem cuida das lanes")).font(.headline).foregroundStyle(.white)
        } footer: {
            Text(String(localized: "Uma pausa geral feita por você sempre vence esta escolha."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
