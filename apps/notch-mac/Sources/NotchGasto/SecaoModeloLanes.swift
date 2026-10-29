import SwiftUI
import GastoCore

/// Lista viva de modelos, atualizada uma vez ao abrir os Ajustes. A espera do CLI
/// fica fora da thread da interface.
@MainActor
final class EstadoListaModelos: ObservableObject {
    @Published var cache: CacheModelos
    @Published var atualizando = false
    /// FRA-564: por lane, por que a lista não veio (login vencido, comando falhou…).
    @Published var motivos: [String: String] = [:]
    private var geracao = 0
    private var jaPediu = false

    init(cache: CacheModelos = ListaModelos.ler(ListaModelos.arquivoCache())) {
        self.cache = cache
    }

    func abrir(_ pedidos: [ListaModelos.Pedido]) {
        guard !jaPediu else { return }
        jaPediu = true
        let atual = cache
        geracao += 1
        let g = geracao
        atualizando = true
        let url = ListaModelos.arquivoCache()
        Task.detached(priority: .utility) {
            let novo = ListaModelos.atualizarNoMac(pedidos: pedidos, cache: atual)
            await MainActor.run { [weak self] in
                guard let self, self.geracao == g else { return }
                self.cache = novo.cache
                self.motivos = novo.motivos
                self.atualizando = false
                try? ListaModelos.gravar(novo.cache, em: url)
            }
        }
    }
}

struct SecaoModeloLanes: View {
    let modelo: ModeloAjustes
    var aoSalvar: () -> Void
    @StateObject private var listas = EstadoListaModelos()
    @State private var agentes: [CatalogoAgentes.ModeloAgente] = []
    @State private var externas: [String: ConfigModelo] = [:]
    @State private var erro: String?

    var body: some View {
        Section {
            if listas.atualizando {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Atualizando a lista de modelos…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(agentes, id: \.nome) { agente in
                BlocoModeloLane(agente: agente, lista: listas.cache.listas[agente.nome] ?? [],
                                cache: listas.cache, motivo: listas.motivos[agente.nome],
                                imposta: externas[agente.nome], modelo: modelo, aoSalvar: aoSalvar)
            }
            if let erro {
                Text(erro).font(.caption).foregroundStyle(.red)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Modelo de cada lane")).font(.headline).foregroundStyle(.white)
                Text(String(localized: "No automático, cada peso de card usa um modelo e um esforço. No fixo, a lane usa sempre o mesmo modelo e o mesmo esforço. Modelos e esforços vêm das ferramentas e atualizam ao abrir os Ajustes. Mudanças valem no próximo card; a lane em andamento não muda."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: abrir)
        .onChange(of: listas.cache) { _, novo in reconciliar(novo) }
    }

    private var pedidos: [ListaModelos.Pedido] {
        agentes.map { agente in
            ListaModelos.Pedido(lane: agente.nome,
                                prefixo: ModeloLane.prefixo(ModeloLane.padrao(agente)),
                                privado: agente.privacidade != nil)
        }
    }

    private func abrir() {
        if agentes.isEmpty {
            agentes = CatalogoAgentes.carregar().filter { $0.cli != nil && $0.painel }
        }
        listas.abrir(pedidos)
    }

    /// Modelo que saiu da lista volta ao automático e o aviso fica no config.
    private func reconciliar(_ cache: CacheModelos) {
        var falha: String?
        for agente in agentes {
            let atual = ModeloLane.ler(ModeloLane.bruto(lane: agente.nome, em: modelo.dados))
            let novo = ModeloLane.reconciliar(atual, lane: agente.nome,
                                              padrao: ModeloLane.padrao(agente), cache: cache)
            guard novo != atual else { continue }
            do {
                try modelo.definirModelo(agente.nome, novo)
                externas[agente.nome] = novo
                aoSalvar()
            } catch {
                falha = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            }
        }
        erro = falha
    }
}

/// Uma lane: Automático (três pesos) ou Fixo. Os seletores gravam na hora; o id digitado grava
/// com Enter ou ao sair do campo. Cada peso mostra o que vai rodar, pela mesma regra do dispatcher.
struct BlocoModeloLane: View {
    let agente: CatalogoAgentes.ModeloAgente
    let lista: [String]
    var cache: CacheModelos = .vazio
    /// Por que a lista da ferramenta não veio nesta abertura. Com lista antiga, ela continua valendo.
    let motivo: String?
    let imposta: ConfigModelo?
    let modelo: ModeloAjustes
    var aoSalvar: () -> Void

    @State private var cfg: ConfigModelo
    @State private var base: ConfigModelo
    @State private var erro: String?
    @State private var retorno: EstadoAcao = .ocioso
    @State private var salvoEm: Date?
    @State private var avisoLocal: String?
    @FocusState private var foco: String?

    init(agente: CatalogoAgentes.ModeloAgente, lista: [String], cache: CacheModelos = .vazio, motivo: String? = nil,
         imposta: ConfigModelo?, modelo: ModeloAjustes, aoSalvar: @escaping () -> Void) {
        self.agente = agente
        self.lista = lista
        self.cache = cache
        self.motivo = motivo
        self.imposta = imposta
        self.modelo = modelo
        self.aoSalvar = aoSalvar
        let lido = ModeloLane.ler(ModeloLane.bruto(lane: agente.nome, em: modelo.dados))
        let preenchida = Self.preencher(lido, agente)
        _cfg = State(initialValue: preenchida)
        _base = State(initialValue: preenchida)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ClarezaCota.titulo(nome: agente.nome, rotulo: agente.rotulo))
                    .font(PV.fonte(13.5, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(ClarezaCota.detalhe(nome: agente.nome) ?? ClarezaCota.titulo(nome: agente.nome, rotulo: agente.rotulo))
                IndicadorAcao(estado: retorno)
                if let salvoEm {
                    Text(String(localized: "salvo \(salvoEm.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if cfg.modo == .auto {
                    Button(String(localized: "Restaurar padrão"), action: restaurar).buttonStyle(.link).font(.caption)
                }
                Picker(String(localized: "Modelo de \(ClarezaCota.titulo(nome: agente.nome, rotulo: agente.rotulo))"), selection: modo) {
                    Text(String(localized: "Automático")).tag(ModoModelo.auto)
                    Text(String(localized: "Fixo")).tag(ModoModelo.fixo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch cfg.modo {
            case .auto:
                linhasPeso
            case .fixo:
                linhaFixa
            }
            if cfg.modo == .fixo && cfg.fixo.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(String(localized: "Escolha ou digite um modelo. Sem modelo, a lane usa o automático."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let motivo {
                Label(motivo,
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cfg.aviso.isEmpty {
                Text(cfg.aviso).font(.caption).foregroundStyle(.orange)
            }
            if let avisoLocal {
                Text(avisoLocal).font(.caption).foregroundStyle(.orange)
            }
            if let erro {
                Text(erro).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: imposta) { _, novo in
            guard let novo else { return }
            let preenchida = Self.preencher(novo, agente)
            cfg = preenchida
            base = preenchida
        }
        .onDisappear(perform: gravarSeMudou)
        .onChange(of: foco) { antigo, _ in if antigo != nil { gravarSeMudou() } }
    }

    private var modo: Binding<ModoModelo> {
        Binding(get: { cfg.modo }, set: { novo in
            var c = cfg
            c.modo = novo
            c.aviso = ""
            if novo == .auto { c = Self.preencher(c, agente) }
            cfg = c
            gravar()
        })
    }

    @ViewBuilder
    private var linhasPeso: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(String(localized: "Peso do card")); Text(String(localized: "Modelo"))
                Text(String(localized: "Ou digite o id")); Text(String(localized: "Esforço"))
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(ModeloLane.pesos, id: \.self) { peso in
                GridRow {
                    Text(ModeloLane.rotuloPeso(peso)).frame(width: 70, alignment: .leading)
                    Picker(String(localized: "Modelo \(ModeloLane.rotuloPeso(peso))"), selection: selecaoModelo(peso)) {
                        Text(rotuloPadrao(peso)).tag("")
                        ForEach(opcoes(cfg.porPeso[peso]?.modelo ?? ""), id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 150, maxWidth: 220)
                    TextField(String(localized: "Modelo"), text: textoModelo(peso), prompt: Text(padraoModelo(peso)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 120)
                        .focused($foco, equals: "modelo-\(peso)")
                        .onSubmit(gravar)
                    seletorEsforco(selecaoEsforco(peso), aceitos: aceitos(peso: peso),
                                   padrao: ModeloLane.padrao(agente)[peso]?.esforco ?? "",
                                   rotulo: String(localized: "Esforço \(ModeloLane.rotuloPeso(peso))"))
                }
                GridRow {
                    Color.clear.frame(width: 70, height: 1)
                    Text(vaiRodar(peso)).font(.caption2).foregroundStyle(.secondary)
                        .gridCellColumns(3)
                }
            }
        }
    }

    private var linhaFixa: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker(String(localized: "Modelo fixo"), selection: selecaoFixa) {
                    Text(String(localized: "Escolher")).tag("")
                    ForEach(opcoes(cfg.fixo), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
                TextField(String(localized: "Ou digite o modelo"), text: textoFixo,
                          prompt: Text(String(localized: "Ou digite o modelo")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($foco, equals: "fixo")
                    .onSubmit(gravar)
                seletorEsforco(selecaoEsforcoFixo, aceitos: aceitos(modelo: cfg.fixo),
                               padrao: String(localized: "do peso"), rotulo: String(localized: "Esforço do modelo fixo"))
            }
            Text(ModeloLane.pesos.map { "\(ModeloLane.rotuloPeso($0)): \(vaiRodar($0, curto: true))" }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Esforço sempre em lista: só o que o modelo aceita, mais «padrão (valor)». Sem esforço, desabilitado.
    @ViewBuilder
    private func seletorEsforco(_ selecao: Binding<String>, aceitos: [String], padrao: String, rotulo: String) -> some View {
        if aceitos.isEmpty {
            Text(String(localized: "sem esforço")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
        } else {
            Picker(rotulo, selection: selecao) {
                Text(padrao.isEmpty ? String(localized: "padrão") : String(localized: "padrão (\(padrao))")).tag("")
                ForEach(aceitos + (aceitos.contains(selecao.wrappedValue) || selecao.wrappedValue.isEmpty ? [] : [selecao.wrappedValue]),
                        id: \.self) { e in
                    Text(e).tag(e)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private func aceitos(modelo: String) -> [String] {
        let id = modelo.trimmingCharacters(in: .whitespaces)
        return ModeloLane.esforcosAceitos(lane: agente.nome, modelo: id, agente: agente, cache: cache)
    }

    private func aceitos(peso: String) -> [String] {
        let escolhido = cfg.porPeso[peso]?.modelo ?? ""
        return aceitos(modelo: escolhido.isEmpty ? (ModeloLane.padrao(agente)[peso]?.modelo ?? "") : escolhido)
    }

    /// O que o dispatcher vai rodar neste peso, com a config da tela.
    private func vaiRodar(_ peso: String, curto: Bool = false) -> String {
        let r = ModeloLane.resolver(lane: agente.nome, peso: peso, config: cfg, padrao: ModeloLane.padrao(agente),
                                    cache: cache, agente: agente)
        let modelo = r.modelo.isEmpty ? String(localized: "padrão do CLI") : r.modelo
        let texto = r.esforco.isEmpty ? modelo : "\(modelo) · \(r.esforco)"
        return curto ? texto : String(localized: "vai rodar: \(texto)")
    }

    private func opcoes(_ atual: String) -> [String] {
        var vistos = Set<String>()
        var saida: [String] = []
        for id in lista where !id.isEmpty && vistos.insert(id).inserted {
            saida.append(id)
        }
        if !atual.isEmpty && vistos.insert(atual).inserted { saida.insert(atual, at: 0) }
        return saida
    }

    /// «Padrão (sonnet)», ou «Padrão do CLI» quando o catálogo não passa modelo (Codex).
    private func rotuloPadrao(_ peso: String) -> String {
        let id = ModeloLane.padrao(agente)[peso]?.modelo ?? ""
        return id.isEmpty ? String(localized: "Padrão do CLI") : String(localized: "Padrão (\(id))")
    }

    private func padraoModelo(_ peso: String) -> String {
        let id = ModeloLane.padrao(agente)[peso]?.modelo ?? ""
        return id.isEmpty ? String(localized: "padrão do CLI") : id
    }

    private func selecaoModelo(_ peso: String) -> Binding<String> {
        Binding(get: { cfg.porPeso[peso]?.modelo ?? "" }, set: { novo in
            var c = cfg
            var escolha = c.porPeso[peso] ?? EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
            escolha.modelo = novo
            c.porPeso[peso] = escolha
            c.aviso = ""
            ajustarEsforco(&c, peso: peso)
            cfg = c
            gravar()
        })
    }

    private func textoModelo(_ peso: String) -> Binding<String> {
        Binding(get: { cfg.porPeso[peso]?.modelo ?? "" }, set: { novo in
            var c = cfg
            var escolha = c.porPeso[peso] ?? EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
            escolha.modelo = novo
            c.porPeso[peso] = escolha
            c.aviso = ""
            cfg = c
        })
    }

    private func selecaoEsforco(_ peso: String) -> Binding<String> {
        Binding(get: { cfg.porPeso[peso].map { $0.esforcoExplicito ? $0.esforco : "" } ?? "" }, set: { novo in
            var c = cfg
            var escolha = c.porPeso[peso] ?? EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
            escolha.esforco = novo
            escolha.esforcoExplicito = !novo.isEmpty
            c.porPeso[peso] = escolha
            cfg = c
            avisoLocal = nil
            gravar()
        })
    }

    private var selecaoEsforcoFixo: Binding<String> {
        Binding(get: { cfg.esforcoFixo }, set: { novo in
            var c = cfg
            c.esforcoFixo = novo
            cfg = c
            avisoLocal = nil
            gravar()
        })
    }

    /// Troca de modelo: esforço que o novo modelo não aceita volta ao padrão (regra no GastoCore).
    private func ajustarEsforco(_ c: inout ConfigModelo, peso: String?) {
        let (novo, aviso) = ModeloLane.ajustarEsforco(c, agente: agente, cache: cache)
        c = novo
        if let aviso { avisoLocal = aviso }
    }

    private var selecaoFixa: Binding<String> {
        Binding(get: { cfg.fixo }, set: { novo in
            var c = cfg
            c.fixo = novo
            c.aviso = ""
            ajustarEsforco(&c, peso: nil)
            cfg = c
            gravar()
        })
    }

    private var textoFixo: Binding<String> {
        Binding(get: { cfg.fixo }, set: { novo in
            var c = cfg
            c.fixo = novo
            c.aviso = ""
            cfg = c
        })
    }

    /// Volta tudo ao padrão do catálogo: nenhum modelo nem esforço escolhido.
    private func restaurar() {
        cfg = Self.preencher(.automatico, agente)
        avisoLocal = nil
        gravar()
    }

    private func gravarSeMudou() {
        guard cfg != base else { return }
        gravar()
    }

    private func gravar() {
        // Também o id digitado: esforço que o modelo novo não aceita não fica gravado (revisão do PR #17).
        var c = cfg
        ajustarEsforco(&c, peso: nil)
        cfg = c
        do {
            try modelo.definirModelo(agente.nome, cfg)
            base = cfg
            erro = nil
            salvoEm = Date()
            comAnimacao(DS.suave) { retorno = .ok("", em: Date()) }
            CentralAvisos.compartilhada.ok(String(localized: "Modelo do \(ClarezaCota.titulo(nome: agente.nome, rotulo: agente.rotulo)) salvo"))
            DispatchQueue.main.asyncAfter(deadline: .now() + MaquinaAcao.tempoOk) { comAnimacao(DS.suave) { retorno = .ocioso } }
            aoSalvar()
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            retorno = .erro(erro ?? "", em: Date())
            CentralAvisos.compartilhada.erro(String(localized: "Não deu para gravar o modelo do \(ClarezaCota.titulo(nome: agente.nome, rotulo: agente.rotulo))"), MaquinaAcao.motivo(error))
        }
    }

    /// Pesos sem escolha no config aparecem como «Padrão (valor)»: sem modelo nem esforço gravado.
    /// A tela mostra o que está no arquivo; o valor real do padrão aparece no rótulo e no «vai rodar».
    static func preencher(_ cfg: ConfigModelo, _ agente: CatalogoAgentes.ModeloAgente) -> ConfigModelo {
        var saida = cfg
        for peso in ModeloLane.pesos where saida.porPeso[peso] == nil {
            saida.porPeso[peso] = EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
        }
        return saida
    }
}
