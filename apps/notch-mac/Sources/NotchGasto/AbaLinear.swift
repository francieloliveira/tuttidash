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
    /// false até a primeira leitura do Keychain (feita fora da criação da tela, FRA-579).
    @Published var tokenConferido = false
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
        workspace = modelo.valorTexto("linear.workspace_url")
    }

    /// Lê o Keychain fora da thread da interface. A importação única do item antigo
    /// e a subida do proxy também ficam fora do redesenho.
    func conferirToken() async {
        let tokens = self.tokens
        temToken = await Task.detached { tokens.ler() != nil }.value
        tokenConferido = true
    }

    /// Conectado = a API respondeu nesta sessão (os seletores só aparecem assim).
    var conectado: Bool { !times.isEmpty }

    func salvarToken() async {
        let texto = token
        let tokens = self.tokens
        do {
            try await Task.detached {
                try tokens.salvar(texto)
                ServicoProxyLinear.compartilhado.ligar(tokens: tokens)
            }.value
            token = ""
            temToken = true
            erro = nil
            await conectar()
        } catch {
            erro = String(localized: "Não foi possível salvar no Keychain: \(error.localizedDescription)")
        }
    }

    func esquecerToken() {
        temToken = false
        times = []
        projetos = []
        opcoes = OpcoesTime()
        let tokens = self.tokens
        Task.detached {
            ServicoProxyLinear.compartilhado.parar()
            tokens.apagar()
        }
    }

    /// Time das colunas: o do projeto padrão do cadastro (FRA-567). nil = nenhum projeto cadastrado.
    var timeDasColunas: String? {
        EscolhasLinear.timeDasColunas(projetos: projetos, cadastro: ProjetosConfig.ler(modelo.dados))
    }

    func conectar() async {
        let tokens = self.tokens
        guard let t = await Task.detached(operation: { tokens.ler() }).value else { erro = ErroLinear.semToken.errorDescription; return }
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
        let tokens = self.tokens
        guard let t = await Task.detached(operation: { tokens.ler() }).value else { return }
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

    /// O estado é criado uma vez só: a página se redesenha a cada poucos segundos (FRA-579).
    init(estado: @autoclosure @escaping () -> EstadoLinear, aoSalvar: @escaping () -> Void, embutido: Bool = false) {
        _estado = StateObject(wrappedValue: estado())
        self.aoSalvar = aoSalvar
        self.embutido = embutido
    }

    private func linha(_ c: CampoLinear) -> some View {
        let itens = EscolhasLinear.itens(c, times: estado.times, opcoes: estado.opcoes)
        let atual = Configuracao.valor(c.chave, em: estado.modelo.dados).map { "\($0)" } ?? ""
        let selecionado = itens.first { (c.porNome ? $0.nome : $0.id) == atual }
        return HStack(alignment: .top, spacing: DS.e4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.titulo).font(PV.fonte(13)).foregroundStyle(PV.texto)
                Text(c.ajuda).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.e4)
            Picker(c.titulo, selection: Binding<ItemLinear?>(
                get: { selecionado },
                set: { if let i = $0 { estado.escolher(c, i, aoSalvar: aoSalvar) } })) {
                if selecionado == nil {
                    Text(EscolhasLinear.nomeExibido(c, em: estado.modelo.dados) ?? String(localized: "Escolha…"))
                        .tag(ItemLinear?.none)
                }
                ForEach(itens) { i in Text(i.nome).tag(Optional(i)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 272, alignment: .trailing)
            .disabled(itens.isEmpty)
        }
        .padding(.vertical, 1)
    }

    private var fluxoToken: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(String(localized: "Token da API do Linear"), text: $estado.token)
            Text(String(localized: "Crie uma chave só para o TuttiDash em Linear › Settings › API. Ela fica no Keychain do app, com proteção de dados, nunca no arquivo. O dispatcher e o vigia pedem o proxy e não recebem a chave. Para trocar, cole a nova e revogue a antiga no Linear."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Salvar e conectar")) { Task { await estado.salvarToken() } }
                    .buttonStyle(.borderedProminent).disabled(estado.token.isEmpty)
            }
        }
    }

    var body: some View {
        Group {
            if embutido { conteudo } else { Form { secoes }.formStyle(.grouped) }
        }
        .id(estado.versao)
        .task {
            if !estado.tokenConferido { await estado.conferirToken() }
            if estado.temToken && !estado.conectado { await estado.conectar() }
        }
    }

    /// Embutido nos Ajustes: um cartão só, sem Section dentro de Section.
    @ViewBuilder private var conteudo: some View {
        if !estado.conectado {
            Text(String(localized: "Conecte o Linear para escolher os projetos e as colunas."))
                .font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
            if !estado.tokenConferido {
                ProgressView().controlSize(.small)
            } else if estado.temToken {
                Button(String(localized: "Conectar o Linear")) { Task { await estado.conectar() } }
                    .buttonStyle(.borderedProminent)
            } else if estado.mostrarToken {
                fluxoToken
            } else {
                Button(String(localized: "Conectar o Linear")) { estado.mostrarToken = true }
                    .buttonStyle(.borderedProminent)
            }
            if estado.carregando { ProgressView().controlSize(.small) }
            if let e = estado.erro { Text(e).font(PV.fonte(11.5)).foregroundStyle(PV.vermelho) }
        } else {
            HStack(spacing: DS.e3) {
                Label(String(localized: "Conectado a \(estado.workspace ?? "Linear")"),
                      systemImage: "checkmark.circle.fill")
                    .font(PV.fonte(12.5)).foregroundStyle(PV.verde)
                Spacer(minLength: DS.e3)
                Button(String(localized: "Recarregar")) { Task { await estado.conectar() } }
                Button(String(localized: "Desconectar")) { estado.esquecerToken() }
            }
            if let e = estado.erro { Text(e).font(PV.fonte(11.5)).foregroundStyle(PV.vermelho) }

            SubtituloAjuste(texto: String(localized: "Colunas do quadro"),
                            ajuda: String(localized: "Sem escolha, valem as colunas com o nome padrão (Todo, In Progress, In Review) no time de cada projeto."))
            if estado.timeDasColunas == nil {
                Text(String(localized: "Cadastre o projeto em Lanes › Projetos: as colunas vêm do time dele."))
                    .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
            }
            ForEach(CampoLinear.colunas()) { linha($0) }
            linha(CampoLinear.etiqueta())
        }
    }

    @ViewBuilder private var secoes: some View {
            if !estado.conectado {
                Section {
                    Text(String(localized: "Conecte o Linear para escolher os projetos e as colunas."))
                    if !estado.tokenConferido {
                        ProgressView().controlSize(.small)
                    } else if estado.temToken {
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
