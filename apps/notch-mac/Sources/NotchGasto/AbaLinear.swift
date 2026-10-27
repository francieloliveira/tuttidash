import SwiftUI
import GastoCore

/// Aba Integrações (FRA-297/299): token no Keychain e escolhas por nome, carregadas da API (só leitura).
@MainActor
final class EstadoLinear: ObservableObject {
    let modelo: ModeloAjustes
    let servico: ServicoLinear
    let tokens: TokenLinear
    @Published var token = ""
    @Published var temToken = false
    @Published var mostrarToken = false
    @Published var carregando = false
    @Published var erro: String?
    @Published var workspace: String?
    @Published var times: [ItemLinear] = []
    @Published var projetos: [ProjetoLinear] = []
    @Published var opcoes = OpcoesTime()
    @Published var versao = 0

    init(modelo: ModeloAjustes, servico: ServicoLinear = ServicoLinear(), tokens: TokenLinear = TokenLinear()) {
        self.modelo = modelo; self.servico = servico; self.tokens = tokens
        temToken = tokens.ler() != nil
        workspace = modelo.valorTexto("linear.workspace_url")
    }

    /// Conectado = a API respondeu nesta sessão (os seletores só aparecem assim).
    var conectado: Bool { !times.isEmpty }

    func salvarToken() async {
        do { try tokens.salvar(token); token = ""; temToken = true; erro = nil; await conectar() }
        catch { erro = String(localized: "Não foi possível salvar no Keychain: \(error.localizedDescription)") }
    }

    func esquecerToken() { tokens.apagar(); temToken = false; times = []; projetos = []; opcoes = OpcoesTime() }

    /// Time das colunas: o do projeto padrão do cadastro (FRA-567). nil = nenhum projeto cadastrado.
    var timeDasColunas: String? {
        EscolhasLinear.timeDasColunas(projetos: projetos, cadastro: ProjetosConfig.ler(modelo.dados))
    }

    func conectar() async {
        guard let t = tokens.ler() else { erro = ErroLinear.semToken.errorDescription; return }
        carregando = true; erro = nil
        defer { carregando = false }
        do {
            let (w, ts) = try await servico.conectar(token: t)
            workspace = w; times = ts
            try modelo.definirValor("linear.workspace_url", w)
            projetos = try await servico.projetos(token: t)
            if let time = timeDasColunas, !time.isEmpty { await carregarTime(time) }
            for (k, v) in EscolhasLinear.nomesResolvidos(dados: modelo.dados, times: times, opcoes: opcoes) {
                try modelo.definirValor(k, v)
            }
            versao += 1
        } catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func carregarTime(_ id: String) async {
        guard let t = tokens.ler() else { return }
        do { opcoes = try await servico.opcoes(time: id, token: t) }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func gravar(_ c: CampoLinear, _ item: ItemLinear) throws {
        for (k, v) in EscolhasLinear.valores(c, item) { try modelo.definirValor(k, v) }
        versao += 1
    }

    func escolher(_ c: CampoLinear, _ item: ItemLinear, aoSalvar: () -> Void) {
        do { try gravar(c, item); aoSalvar() }
        catch { erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)") }
    }
}

struct AbaLinear: View {
    @StateObject var estado: EstadoLinear
    var aoSalvar: () -> Void
    /// true dentro de Ajustes na janela principal (FRA-524): as seções entram no Form de fora.
    var embutido = false

    private func linha(_ c: CampoLinear) -> some View {
        let itens = EscolhasLinear.itens(c, times: estado.times, opcoes: estado.opcoes)
        let atual = Configuracao.valor(c.chave, em: estado.modelo.dados).map { "\($0)" } ?? ""
        let selecionado = itens.first { (c.porNome ? $0.nome : $0.id) == atual }
        return VStack(alignment: .leading, spacing: 2) {
            Picker(c.titulo, selection: Binding<ItemLinear?>(
                get: { selecionado },
                set: { if let i = $0 { estado.escolher(c, i, aoSalvar: aoSalvar) } })) {
                if selecionado == nil {
                    Text(EscolhasLinear.nomeExibido(c, em: estado.modelo.dados) ?? String(localized: "Escolha…"))
                        .tag(ItemLinear?.none)
                }
                ForEach(itens) { i in Text(i.nome).tag(Optional(i)) }
            }
            .disabled(itens.isEmpty)
            Text(c.ajuda).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fluxoToken: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(String(localized: "Token da API do Linear"), text: $estado.token)
            Text(String(localized: "Crie em Linear › Settings › API. Ele fica só no Keychain, nunca no arquivo, e vale também para o dispatcher e o vigia."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Salvar e conectar")) { Task { await estado.salvarToken() } }
                    .buttonStyle(.borderedProminent).disabled(estado.token.isEmpty)
            }
        }
    }

    var body: some View {
        Group {
            if embutido { secoes } else { Form { secoes }.formStyle(.grouped) }
        }
        .id(estado.versao)
        .task { if estado.temToken && !estado.conectado { await estado.conectar() } }
    }

    @ViewBuilder private var secoes: some View {
            if !estado.conectado {
                Section {
                    Text(String(localized: "Conecte o Linear para escolher os projetos e as colunas."))
                    if estado.temToken {
                        Button(String(localized: "Conectar o Linear")) { Task { await estado.conectar() } }
                            .buttonStyle(.borderedProminent)
                    } else if estado.mostrarToken {
                        fluxoToken
                    } else {
                        Button(String(localized: "Conectar o Linear")) { estado.mostrarToken = true }
                            .buttonStyle(.borderedProminent)
                    }
                    if estado.carregando { ProgressView().controlSize(.small) }
                    if let e = estado.erro { Text(e).font(.caption).foregroundStyle(.red) }
                }
            } else {
                Section {
                    HStack {
                        Text(String(localized: "Conectado a \(estado.workspace ?? "Linear")"))
                        Spacer()
                        Button(String(localized: "Recarregar")) { Task { await estado.conectar() } }
                        Button(String(localized: "Desconectar")) { estado.esquecerToken() }
                    }
                    if let e = estado.erro { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    if estado.timeDasColunas == nil {
                        Text(String(localized: "Cadastre o projeto em Lanes › Projetos: as colunas vêm do time dele."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(CampoLinear.colunas()) { linha($0) }
                } header: {
                    Text(String(localized: "Colunas do quadro"))
                } footer: {
                    Text(String(localized: "Sem escolha, valem as colunas com o nome padrão (Todo, In Progress, In Review) no time de cada projeto."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { linha(CampoLinear.etiqueta()) }
            }
    }
}
