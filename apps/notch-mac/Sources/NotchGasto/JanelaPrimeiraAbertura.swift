import AppKit
import SwiftUI
import GastoCore

/// Primeira abertura guiada: contas, Linear, projetos, agendas e pronto. Nenhum arquivo para editar à mão.
@MainActor
final class JanelaPrimeiraAbertura {
    static let compartilhada = JanelaPrimeiraAbertura()
    private var janela: NSWindow?

    func mostrar(aoConcluir: @escaping () -> Void) {
        let host = NSHostingController(rootView: TelaPrimeiraAbertura(aoConcluir: { [weak self] in
            self?.janela?.close(); aoConcluir()
        }))
        let w = NSWindow(contentViewController: host)
        w.title = String(localized: "Bem-vindo ao TuttiDash")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 620, height: 520))
        w.center()
        janela = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct TelaPrimeiraAbertura: View {
    var aoConcluir: () -> Void
    @State private var passo = 0
    @State private var erro: String?
    @State private var contas: Set<String> = Set(ContaUso.padrao.map(\.tipo))
    private let modelo = ModeloAjustes()
    private let deps = Dependencia.verificar()

    private var titulos: [String] {
        [String(localized: "Boas-vindas"), String(localized: "Contas para acompanhar"), String(localized: "Seu quadro no Linear"),
         String(localized: "Projetos e repositórios"), String(localized: "Tarefas automáticas"), String(localized: "Pronto")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titulos[passo]).font(.title2.bold())
            Group {
                switch passo {
                case 0: boasVindas
                case 1: escolhaContas
                case 2: AbaLinear(estado: EstadoLinear(modelo: modelo), aoSalvar: {})
                case 3: Form {
                    Text(String(localized: "Ligue cada projeto do Linear ao repositório do GitHub em que as lanes trabalham. As duas listas vêm das suas contas."))
                        .foregroundStyle(.secondary)
                    SecaoProjetos(estado: EstadoProjetos(modelo: modelo)) }.formStyle(.grouped)
                case 4: Form {
                    Text(String(localized: "Estas tarefas rodam sozinhas de tempos em tempos. Instale só as que você usa; dá para mudar depois."))
                        .foregroundStyle(.secondary)
                    SecaoAgendas(estado: EstadoAgendas(modelo: modelo)) }.formStyle(.grouped)
                default: Text(String(localized: "Tudo certo. Você pode mudar qualquer escolha depois na engrenagem do painel."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let erro { Text(erro).font(.caption).foregroundStyle(.red) }
            HStack {
                if passo > 0 { Button(String(localized: "Voltar")) { passo -= 1 } }
                Spacer()
                if (2...4).contains(passo) { Button(String(localized: "Pular")) { passo += 1 } }
                Button(passo == titulos.count - 1 ? String(localized: "Concluir") : String(localized: "Continuar")) { avancar() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 500)
    }

    private var boasVindas: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "O TuttiDash mostra no notch o gasto e o estado das suas lanes de agentes. Vamos configurar em poucos passos."))
            Text(String(localized: "Dependências (opcionais)")).font(.headline)
            ForEach(deps) { d in
                HStack {
                    Image(systemName: d.encontrada == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(d.encontrada == nil ? .orange : .green)
                    Text(d.nome).bold()
                    if let c = d.encontrada { Text(c).foregroundStyle(.secondary) } else {
                        Text(String(localized: "Instale com: \(d.comoInstalar)")).textSelection(.enabled)
                        Link(String(localized: "Homebrew"), destination: d.link)
                    }
                }
            }
            Text(String(localized: "Sem elas o app funciona; só o painel de logs e os scripts ficam indisponíveis."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var escolhaContas: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Quais agentes acompanhar? (vale para limites, gasto e retomadas)"))
            ForEach(ContaUso.todas, id: \.tipo) { c in
                let titulo = ClarezaCota.rotuloConta(tipo: c.tipo, rotuloSalvo: c.rotulo)
                Toggle(isOn: Binding(get: { contas.contains(c.tipo) },
                                     set: { if $0 { contas.insert(c.tipo) } else { contas.remove(c.tipo) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titulo)
                        if let detalhe = ClarezaCota.detalhe(nome: c.tipo) {
                            Text(detalhe).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func avancar() {
        do {
            if passo == 1 {
                try modelo.definirValor("contas", ContaUso.todas.filter { contas.contains($0.tipo) }.map(\.dict))
                try modelo.definirValor("uso_contas", !contas.isEmpty)
            }
            if passo == titulos.count - 1 {
                try PrimeiraAbertura.concluir(modelo); aoConcluir(); return
            }
            erro = nil; passo += 1
        } catch { erro = error.localizedDescription }
    }
}
