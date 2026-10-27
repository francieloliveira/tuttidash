import SwiftUI
import GastoCore

/// Cadastro de projetos que o dispatcher e o vigia enxergam.
///
/// É a tela que decide de onde as lanes trabalham: cada linha diz o projeto do
/// Linear, o repo, a pasta de worktrees, o comando de prova e o freio de caminho
/// protegido. Gravar aqui é o que faz o `dispatcher.py` passar a enxergar o
/// projeto — não há lista em código para atualizar junto.
///
/// Ler e escrever passa pelo `ModeloAjustes`, que mescla no config em uso sem
/// apagar as outras chaves.
@MainActor
final class EstadoProjetos: ObservableObject {
    let modelo: ModeloAjustes
    let servico: ServicoLinear
    let tokens: TokenLinear
    @Published var projetos: [ProjetoCadastro]
    @Published var erro: String?
    @Published var aviso: String?
    /// Listas para escolher (FRA-567): projetos do Linear e repositórios do GitHub.
    @Published var projetosLinear: [ProjetoLinear] = []
    @Published var repos: [String] = []
    @Published var avisoLinear: String?
    @Published var avisoGitHub: String?
    @Published var carregandoListas = false
    @Published var clonando: String?
    /// Linhas abertas, pelo id do projeto (sobrevive à troca do id ao escolher na lista).
    @Published var abertos: Set<String> = []

    init(modelo: ModeloAjustes, servico: ServicoLinear = ServicoLinear(), tokens: TokenLinear = TokenLinear()) {
        self.modelo = modelo
        self.servico = servico
        self.tokens = tokens
        projetos = ProjetosConfig.ler(modelo.dados)
    }

    private func gravar() {
        do {
            try modelo.definirProjetos(projetos)
            projetos = ProjetosConfig.ler(modelo.dados)
            erro = nil
            aviso = String(localized: "Salvo. O dispatcher passa a usar isso no próximo ciclo (até 60 s).")
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
        }
    }

    /// Carrega as duas listas fora da thread da interface.
    func carregarListas() async {
        carregandoListas = true
        defer { carregandoListas = false }
        let tokens = self.tokens, servico = self.servico
        if let t = await Task.detached(operation: { tokens.ler() }).value {
            do {
                projetosLinear = try await servico.projetos(token: t)
                avisoLinear = projetosLinear.isEmpty ? String(localized: "Nenhum projeto no seu Linear.") : nil
            } catch {
                avisoLinear = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            avisoLinear = String(localized: "Conecte o Linear em Integrações para escolher o projeto na lista.")
        }
        switch await Task.detached(operation: { RepositorioGitHub.listar() }).value {
        case .success(let lista):
            repos = lista
            avisoGitHub = lista.isEmpty ? String(localized: "Nenhum repositório na sua conta do GitHub.") : nil
        case .failure(let e):
            avisoGitHub = e.errorDescription
        }
    }

    func adicionar() {
        projetos.append(ProjetoCadastro(projetoID: "", nome: "", repo: ""))
        abertos.insert("")
        erro = nil
    }

    /// Projeto do Linear escolhido na lista: id, e o nome quando ainda não havia outro.
    func escolherLinear(_ p: ProjetoLinear, para atual: ProjetoCadastro) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == atual.projetoID }) else { return }
        if projetos.contains(where: { $0.projetoID == p.id && $0.projetoID != atual.projetoID }) {
            erro = String(localized: "Esse projeto do Linear já está no cadastro.")
            return
        }
        let eraAberto = abertos.remove(atual.projetoID) != nil
        let nomeAntigo = projetosLinear.first { $0.id == atual.projetoID }?.nome
        projetos[i].projetoID = p.id
        if projetos[i].nome.isEmpty || projetos[i].nome == atual.projetoID || projetos[i].nome == nomeAntigo {
            projetos[i].nome = p.nome
        }
        if eraAberto { abertos.insert(p.id) }
        erro = nil
    }

    /// Repositório escolhido na lista: guarda e procura a pasta que já tem esse `origin`.
    func escolherGitHub(_ repo: String, para atual: ProjetoCadastro) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == atual.projetoID }) else { return }
        projetos[i].github = repo
        if let pasta = RepositorioGitHub.pastaLocal(para: repo, raizes: RepositorioGitHub.raizesPadrao(home: modelo.home)) {
            projetos[i].repo = Self.comTil(pasta, home: modelo.home)
        }
    }

    /// Só no clique: `gh repo clone` em `~/Developer/<repo>`, e a pasta entra no cadastro.
    func clonar(_ atual: ProjetoCadastro) async {
        guard let destino = RepositorioGitHub.destinoDoClone(atual.github, home: modelo.home) else { return }
        clonando = atual.github
        defer { clonando = nil }
        let repo = atual.github
        switch await Task.detached(operation: { RepositorioGitHub.clonar(repo, em: destino) }).value {
        case .success(let pasta):
            if let i = projetos.firstIndex(where: { $0.projetoID == atual.projetoID }) {
                projetos[i].repo = Self.comTil(pasta, home: modelo.home)
            }
            erro = nil
        case .failure(let e):
            erro = e.errorDescription
        }
    }

    static func comTil(_ pasta: URL, home: URL) -> String {
        let h = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        return pasta.path.hasPrefix(h + "/") ? "~" + pasta.path.dropFirst(h.count) : pasta.path
    }

    /// `origin` da pasta do cadastro, já em `dono/repo`. nil = a pasta não é um clone.
    func origemDaPasta(_ p: ProjetoCadastro) -> String? {
        let caminho = (p.repo as NSString).expandingTildeInPath
        guard !caminho.isEmpty else { return nil }
        return RepositorioGitHub.origem(da: URL(fileURLWithPath: caminho)).flatMap(RepositorioGitHub.normalizar)
    }

    func remover(_ p: ProjetoCadastro) {
        projetos.removeAll { $0.projetoID == p.projetoID }
        gravar()
    }

    func mover(_ p: ProjetoCadastro, _ delta: Int) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == p.projetoID }) else { return }
        let j = i + delta
        guard projetos.indices.contains(j) else { return }
        projetos.swapAt(i, j)
        gravar()
    }

    func salvar(_ p: ProjetoCadastro) {
        guard let i = projetos.firstIndex(where: { $0.projetoID == p.projetoID }) else { return }
        projetos[i] = p
        if let msg = p.problema() {
            erro = msg
            projetos[i].padrao = false
            return
        }
        gravar()
    }

    func alternarAtivo(_ p: ProjetoCadastro, _ ativo: Bool) {
        var copia = p
        copia.ativo = ativo
        salvar(copia)
    }

    func marcarPadrao(_ p: ProjetoCadastro) {
        for i in projetos.indices { projetos[i].padrao = projetos[i].projetoID == p.projetoID }
        gravar()
    }
}

struct SecaoProjetos: View {
    @ObservedObject var estado: EstadoProjetos

    var body: some View {
        Section {
            if let e = estado.erro {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if let a = estado.aviso {
                Text(a).font(.caption).foregroundStyle(.secondary)
            }
            if estado.carregandoListas { ProgressView().controlSize(.small) }
            ForEach($estado.projetos) { $p in
                LinhaProjeto(projeto: $p, estado: estado)
            }
            Button {
                estado.adicionar()
            } label: {
                Label(String(localized: "Adicionar projeto"), systemImage: "plus")
            }
        } header: {
            Text(String(localized: "Projetos que o dispatcher enxerga"))
        } footer: {
            Text(String(localized: "O projeto marcado como padrão é o que as lanes trabalham neste ciclo. Sem ninguém marcado, vale o primeiro ativo da lista — a ordem da lista é a ordem de preferência. Desligar mantém o projeto listado aqui, sem o dispatcher assumir card nele."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if estado.projetosLinear.isEmpty && estado.repos.isEmpty { await estado.carregarListas() } }
    }
}

private struct LinhaProjeto: View {
    @Binding var projeto: ProjetoCadastro
    @ObservedObject var estado: EstadoProjetos
    private var aberto: Bool { estado.abertos.contains(projeto.projetoID) }

    private var podeSubir: Bool {
        (estado.projetos.firstIndex { $0.projetoID == projeto.projetoID } ?? 0) > 0
    }
    private var podeDescer: Bool {
        let i = estado.projetos.firstIndex { $0.projetoID == projeto.projetoID } ?? 0
        return i >= 0 && i < estado.projetos.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { projeto.ativo },
                                     set: { estado.alternarAtivo(projeto, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(projeto.nome.isEmpty ? String(localized: "(sem nome)") : projeto.nome)
                            .font(.body)
                        Text(resumo)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { estado.marcarPadrao(projeto) } label: {
                    Image(systemName: projeto.padrao ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Tornar o projeto que as lanes trabalham"))
                .disabled(!projeto.padrao)
                Button {
                    if aberto { estado.abertos.remove(projeto.projetoID) } else { estado.abertos.insert(projeto.projetoID) }
                } label: {
                    Image(systemName: aberto ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Button { estado.remover(projeto) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(estado.projetos.count <= 1)
            }
            if aberto {
                Group {
                    escolhaLinear
                    escolhaGitHub
                    Campo("Nome", texto: $projeto.nome)
                    Campo("Pasta neste Mac", texto: $projeto.repo)
                    conferenciaDaPasta
                    Campo("Worktrees (vazio = repo-worktrees)", texto: $projeto.worktrees)
                    Campo("Prova (usa {suite})", texto: $projeto.prova)
                    Campo("Tentativas da prova", texto: Binding(
                        get: { "\(projeto.provaTentativas)" },
                        set: { projeto.provaTentativas = Int($0) ?? 1 }))
                    Campo("Caminhos protegidos (um por linha)", multilinha: true,
                          texto: Binding(
                            get: { projeto.protegidos.joined(separator: "\n") },
                            set: { projeto.protegidos = $0.split(separator: "\n")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty } }))
                    Campo("Copiar para o worktree, fora do git (um por linha)", multilinha: true,
                          texto: Binding(
                            get: { projeto.copiarParaWorktree.joined(separator: "\n") },
                            set: { projeto.copiarParaWorktree = $0.split(separator: "\n")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty } }))
                    Campo("Conferência antes do push (comando; vazio = nenhuma)", texto: $projeto.antesDoPush)
                    HStack {
                        Button(String(localized: "Salvar este projeto")) { estado.salvar(projeto) }
                        Button(String(localized: "Subir")) { estado.mover(projeto, -1) }
                            .disabled(!podeSubir)
                        Button(String(localized: "Descer")) { estado.mover(projeto, 1) }
                            .disabled(!podeDescer)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private var resumo: String {
        let linear = estado.projetosLinear.first { $0.id == projeto.projetoID }?.rotulo
        let partes = [linear ?? (projeto.projetoID.isEmpty ? String(localized: "projeto do Linear pendente") : nil),
                      projeto.github.isEmpty ? String(localized: "GitHub pendente") : projeto.github,
                      projeto.repo.isEmpty ? nil : projeto.repo].compactMap { $0 }
        return partes.joined(separator: " · ")
    }

    @ViewBuilder private var escolhaLinear: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "Projeto no Linear")).font(.caption).foregroundStyle(.secondary)
            if estado.projetosLinear.isEmpty {
                Text(estado.avisoLinear ?? String(localized: "Carregando os projetos do Linear…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Projeto no Linear"), selection: Binding<String>(
                    get: { projeto.projetoID },
                    set: { id in if let p = estado.projetosLinear.first(where: { $0.id == id }) { estado.escolherLinear(p, para: projeto) } })) {
                    if !estado.projetosLinear.contains(where: { $0.id == projeto.projetoID }) {
                        Text(projeto.projetoID.isEmpty ? String(localized: "Escolha…") : String(localized: "(fora da lista)"))
                            .tag(projeto.projetoID)
                    }
                    ForEach(estado.projetosLinear) { p in Text(p.rotulo).tag(p.id) }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var escolhaGitHub: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "Repositório no GitHub")).font(.caption).foregroundStyle(.secondary)
            if estado.repos.isEmpty {
                Text(estado.avisoGitHub ?? String(localized: "Carregando os repositórios do GitHub…"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Picker(String(localized: "Repositório no GitHub"), selection: Binding<String>(
                    get: { projeto.github },
                    set: { estado.escolherGitHub($0, para: projeto) })) {
                    if !estado.repos.contains(projeto.github) {
                        Text(projeto.github.isEmpty ? String(localized: "Escolha…") : projeto.github).tag(projeto.github)
                    }
                    ForEach(estado.repos, id: \.self) { r in Text(r).tag(r) }
                }
                .labelsHidden()
            }
        }
    }

    /// Diz se a pasta é um clone do repositório escolhido; oferece o clone quando falta.
    @ViewBuilder private var conferenciaDaPasta: some View {
        let origem = estado.origemDaPasta(projeto)
        if !projeto.github.isEmpty {
            if origem == projeto.github {
                Label(String(localized: "A pasta é um clone de \(projeto.github)."), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(origem == nil
                          ? String(localized: "Esta pasta não é um clone de \(projeto.github). As lanes não enviam nada enquanto não for.")
                          : String(localized: "O origin desta pasta é \(origem!), não \(projeto.github). As lanes não enviam nada enquanto não for."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    if let destino = RepositorioGitHub.destinoDoClone(projeto.github, home: estado.modelo.home) {
                        Button(estado.clonando == projeto.github
                               ? String(localized: "Clonando…")
                               : String(localized: "Clonar em \(EstadoProjetos.comTil(destino, home: estado.modelo.home))")) {
                            Task { await estado.clonar(projeto) }
                        }
                        .disabled(estado.clonando != nil)
                    }
                }
            }
        }
    }
}

private struct Campo: View {
    let rotulo: String
    var multilinha = false
    @Binding var texto: String

    init(_ rotulo: String, multilinha: Bool = false, texto: Binding<String>) {
        self.rotulo = rotulo
        self.multilinha = multilinha
        self._texto = texto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rotulo).font(.caption).foregroundStyle(.secondary)
            if multilinha {
                TextEditor(text: $texto)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 70)
            } else {
                TextField(rotulo, text: $texto)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }
}