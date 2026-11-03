import SwiftUI
import GastoCore

/// Lanes ACP de uma conta (PRD lanes-acp): adicionar com um clique, nome sugerido a partir do
/// modelo (editável), limite de lanes simultâneas da conta, "Testar lane" e custos.
/// O comando do agente nunca passa por aqui: vem do manifesto assinado.
@MainActor
final class EstadoLanesACP: ObservableObject {
    let modelo: ModeloAjustes
    let agente: Agentes.Def
    var aoSalvar: () -> Void = {}
    @Published var lanes: [LaneACP] = []
    @Published var erro: String?
    /// nil = sem limite (padrão): quem segura é a cota da conta.
    @Published var limite: Int?
    /// Modelo do agente por peso (o que o modo automático usa).
    @Published var porPeso: [String: String] = [:]
    @Published var precoTexto = ""
    @Published var testes: [String: ResultadoSonda] = [:]
    @Published var gasto: GastoConta?
    @Published var modelosDisponiveis: [String] = []

    struct ResultadoSonda: Equatable {
        var rodando: Bool
        var aprovada: Bool
        var texto: String
    }

    struct GastoConta: Equatable {
        var usd: Double
        var execucoes: Int
        var semCusto: Int
    }

    init(modelo: ModeloAjustes, agente: Agentes.Def) {
        self.modelo = modelo
        self.agente = agente
        recarregar()
    }

    var conta: String { agente.nome }
    var todas: [LaneACP] { LanesACP.ler(modelo.dados) }

    func recarregar() {
        lanes = todas.filter { $0.agente == agente.nome && $0.conta == conta }
        limite = LanesACP.limite(conta: conta, modelo.dados)
        precoTexto = LanesACP.preco(conta: conta, modelo.dados).map { String(format: "%.2f", $0) } ?? ""
        let cache = ListaModelos.ler(ListaModelos.arquivoCache())
        modelosDisponiveis = cache.listas[agente.nome] ?? []
        porPeso = LanesACP.modelosPorPeso(agente: agente.nome)
    }

    /// Modelo que a sonda usa para uma lane automática: o do peso médio (o padrão).
    func modeloDaSonda(_ l: LaneACP) -> String {
        l.modelo == LanesACP.modeloAuto ? (porPeso["medio"] ?? "") : l.modelo
    }

    func sugerir(modelo m: String) -> String {
        LanesACP.nomeSugerido(agente: agente.nome, modelo: m, usados: Set(todas.map(\.nome)))
    }

    private func gravar(_ novas: [LaneACP]) -> Bool {
        do {
            try modelo.definirValor("lanes.\(LanesACP.chave)", novas.map { $0.dict() })
            erro = nil
            recarregar()
            aoSalvar()
            return true
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func adicionar(nome: String, modeloEscolhido: String) -> Bool {
        let m = modeloEscolhido.trimmingCharacters(in: .whitespaces)
        let nova = LaneACP(nome: nome.trimmingCharacters(in: .whitespaces), agente: agente.nome, conta: conta,
                           modelo: m.isEmpty ? LanesACP.modeloAuto : m, ligada: false)
        let outras = todas
        if let p = LanesACP.problema(nova, outras: outras) {
            erro = p
            return false
        }
        return gravar(outras + [nova])
    }

    func alternar(_ l: LaneACP, _ ligada: Bool) {
        var lista = todas
        guard let i = lista.firstIndex(where: { $0.nome == l.nome }) else { return }
        if ligada, testes[l.nome]?.aprovada != true, !sondaGravadaAprovada() {
            erro = String(localized: "Rode «Testar lane» antes de ligar: a lane só roda com a sonda aprovada.")
            return
        }
        lista[i].ligada = ligada
        _ = gravar(lista)
    }

    func remover(_ l: LaneACP) {
        _ = gravar(todas.filter { $0.nome != l.nome })
    }

    func definirLimite(_ n: Int?) {
        do {
            try modelo.definirValor("lanes.\(LanesACP.chaveLimite).\(conta)", n.map { max(1, $0) as Any } ?? NSNull())
            limite = n.map { max(1, $0) }
            erro = nil
            aoSalvar()
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
        }
    }

    func salvarPreco() {
        let t = precoTexto.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let valor: Any
        if t.isEmpty {
            valor = NSNull()
        } else if let v = Double(t), v >= 0 {
            valor = v
        } else {
            erro = String(localized: "Preço inválido: use um número, como 20 ou 19,90.")
            return
        }
        do {
            try modelo.definirValor("lanes.\(LanesACP.chavePreco).\(conta)", valor)
            erro = nil
            aoSalvar()
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
        }
    }

    /// Sonda gravada pelo `sonda_acp.py` (mesmo arquivo que o runner confere).
    func sondaGravadaAprovada() -> Bool {
        let url = modelo.home.appendingPathComponent(".transcentia/lanes/sonda-acp-\(agente.nome).json")
        guard let d = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return (obj["aprovada"] as? Bool) == true
    }

    func testar(_ l: LaneACP) {
        testes[l.nome] = ResultadoSonda(rodando: true, aprovada: false,
                                        texto: String(localized: "Testando: edição, comando proibido e web…"))
        let script = ScriptsDoBundle.obrigatorio("lanes/sonda_acp.py").path
        var amb = ProcessInfo.processInfo.environment
        amb["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (amb["PATH"] ?? "/usr/bin:/bin")
        let args = [script, "--agente", l.agente, "--modelo", modeloDaSonda(l)]
        let nome = l.nome
        Task.detached(priority: .userInitiated) {
            let r = Subprocesso.rodar("/usr/bin/python3", args, ambiente: amb)
            let res = EstadoLanesACP.interpretarSonda(r.texto, codigo: r.codigo)
            await MainActor.run { self.testes[nome] = res }
        }
    }

    nonisolated static func interpretarSonda(_ texto: String, codigo: Int32) -> ResultadoSonda {
        guard let d = texto.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return ResultadoSonda(rodando: false, aprovada: false,
                                  texto: String(localized: "A sonda não respondeu (código \(codigo)). Confira se o agente está instalado e logado."))
        }
        if (obj["aprovada"] as? Bool) == true {
            let v = (obj["versao"] as? String).map { " \($0)" } ?? ""
            return ResultadoSonda(rodando: false, aprovada: true,
                                  texto: String(localized: "Aprovada\(v): pergunta antes de agir e respeita a negação."))
        }
        let motivos = (obj["motivos"] as? [String]) ?? []
        return ResultadoSonda(rodando: false, aprovada: false,
                              texto: String(localized: "Reprovada: \(motivos.joined(separator: "; "))"))
    }

    /// Gasto medido no mês pelo ledger: lane da conta + lanes ACP dela.
    func medirGasto() {
        let lanesDaConta = Set([agente.nome] + lanes.map(\.nome))
        Task.detached(priority: .utility) {
            let res = Carregador().carregar(config: Configuracao.resolver())
            let mes = String(ISO8601DateFormatter().string(from: Date()).prefix(7))
            let doMes = res.execucoes.filter { lanesDaConta.contains($0.lane) && $0.inicio.hasPrefix(mes) }
            let usd = doMes.compactMap(\.custoUSD).reduce(0, +)
            let sem = doMes.filter { $0.custoUSD == nil }.count
            let g = GastoConta(usd: usd, execucoes: doMes.count, semCusto: sem)
            await MainActor.run { self.gasto = g }
        }
    }
}

struct SecaoLanesDaConta: View {
    @StateObject private var estado: EstadoLanesACP
    @State private var modeloNovo = LanesACP.modeloAuto
    @State private var nomeNovo = ""
    @State private var nomeEditado = false

    init(modelo: ModeloAjustes, agente: Agentes.Def, aoSalvar: @escaping () -> Void) {
        let e = EstadoLanesACP(modelo: modelo, agente: agente)
        e.aoSalvar = aoSalvar
        _estado = StateObject(wrappedValue: e)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(String(localized: "Lanes desta conta (ACP)")).font(.headline)
            Text(String(localized: "Cada lane usa esta conta com um modelo fixo. O comando e as permissões vêm do app assinado; aqui você escolhe só o modelo e o nome."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = estado.erro {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(estado.lanes) { l in linha(l) }
            if estado.lanes.isEmpty {
                Text(String(localized: "Nenhuma lane ACP nesta conta.")).font(.caption).foregroundStyle(.secondary)
            }
            adicionar
            limiteDaConta
            custos
        }
        .onAppear {
            estado.recarregar()
            estado.medirGasto()
            if nomeNovo.isEmpty { sugerir(modeloNovo) }
        }
    }

    private func linha(_ l: LaneACP) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(isOn: Binding(get: { l.ligada }, set: { estado.alternar(l, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.nome).font(.system(size: 12, design: .monospaced))
                        Text(l.modelo == LanesACP.modeloAuto
                             ? String(localized: "Automático (segue o peso da task)") : l.modelo)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(String(localized: "Testar lane")) { estado.testar(l) }
                    .disabled(estado.testes[l.nome]?.rodando == true)
                Button { estado.remover(l) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Remover esta lane"))
            }
            if let t = estado.testes[l.nome] {
                HStack(spacing: 6) {
                    if t.rodando { ProgressView().controlSize(.small) }
                    Text(t.texto).font(.caption)
                        .foregroundStyle(t.rodando ? Color.secondary : (t.aprovada ? Color.green : Color.red))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var adicionar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Nova lane")).font(.subheadline.weight(.semibold))
            Picker(String(localized: "Modelo"), selection: $modeloNovo) {
                Text(String(localized: "Automático (segue o peso da task)")).tag(LanesACP.modeloAuto)
                ForEach(estado.modelosDisponiveis.filter { $0 != LanesACP.modeloAuto }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .onChange(of: modeloNovo) { _, m in sugerir(m) }
            if modeloNovo == LanesACP.modeloAuto {
                Text(textoAutomatico).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if estado.modelosDisponiveis.isEmpty {
                TextField(String(localized: "Modelo fixo (ex.: opencode/beam-free)"), text: $modeloNovo)
                    .font(.system(size: 11, design: .monospaced))
            }
            TextField(String(localized: "Nome da lane"), text: Binding(
                get: { nomeNovo }, set: { nomeNovo = $0; nomeEditado = true }))
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button {
                    if estado.adicionar(nome: nomeNovo, modeloEscolhido: modeloNovo) {
                        modeloNovo = LanesACP.modeloAuto
                        nomeEditado = false
                        sugerir(modeloNovo)
                    }
                } label: {
                    Label(String(localized: "Salvar lane"), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(nomeNovo.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(String(localized: "Nasce desligada: rode «Testar lane» e depois ligue."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var textoAutomatico: String {
        let p = estado.porPeso
        let medio = p["medio"] ?? "—"
        return String(localized: "Padrão (médio): \(medio). Baixo: \(p["baixo"] ?? "—"). Alto: \(p["alto"] ?? "—"). Igual às lanes de hoje: o modelo segue o peso do card e os seus ajustes de modelo do agente.")
    }

    private var limiteDaConta: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(String(localized: "Limitar lanes rodando ao mesmo tempo nesta conta"), isOn: Binding(
                get: { estado.limite != nil },
                set: { estado.definirLimite($0 ? (estado.limite ?? 2) : nil) }))
                .font(.caption)
            if let n = estado.limite {
                Stepper(value: Binding(get: { n }, set: { estado.definirLimite($0) }), in: 1...20) {
                    Text(String(localized: "No máximo \(n) ao mesmo tempo")).font(.caption)
                }
            } else {
                Text(String(localized: "Sem limite: todas as lanes desta conta podem rodar; a medida de cota da conta segura quando ela aperta."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sugerir(_ m: String) {
        if !nomeEditado || nomeNovo.isEmpty {
            nomeNovo = estado.sugerir(modelo: m.isEmpty ? LanesACP.modeloAuto : m)
            nomeEditado = false
        }
    }

    private var custos: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Custos da conta")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(String(localized: "Preço do plano por mês (US$)"), text: $estado.precoTexto)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { estado.salvarPreco() }
                Button(String(localized: "Salvar preço")) { estado.salvarPreco() }
            }
            if let g = estado.gasto {
                Text(String(localized: "Gasto medido no mês: US$ \(String(format: "%.2f", g.usd)) em \(g.execucoes) execução(ões)"))
                    .font(.caption)
                if g.semCusto > 0 {
                    Text(String(localized: "\(g.semCusto) execução(ões) sem custo informado (modelo free ou agente que não informa)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "Medindo o gasto…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
