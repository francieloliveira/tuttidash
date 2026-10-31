import AppKit
import SwiftUI
import GastoCore

/// Uma linha do cadastro (FRA-579): o que está gravado e o rascunho que a pessoa edita.
/// O `id` é local e estável, para a linha não perder o estado quando o projeto do Linear muda.
struct LinhaCadastro: Identifiable {
    let id = UUID()
    var salvo: ProjetoCadastro?
    var rascunho: ProjetoCadastro
    var aberto = false
    var nova: Bool { salvo == nil }
    var mudou: Bool { salvo != rascunho }
}

/// Cadastro de projetos que as lanes enxergam: cada projeto liga um projeto do Linear a um
/// repositório do GitHub e à pasta neste Mac. Grava pelo `ModeloAjustes`, que mescla no
/// config sem apagar as outras chaves.
@MainActor
final class EstadoProjetos: ObservableObject {
    let modelo: ModeloAjustes
    let servico: ServicoLinear
    let tokens: TokenLinear
    @Published var linhas: [LinhaCadastro]
    @Published var erro: String?
    @Published var aviso: String?
    @Published var projetosLinear: [ProjetoLinear] = []
    @Published var repos: [String] = []
    @Published var avisoLinear: String?
    @Published var avisoGitHub: String?
    @Published var carregandoListas = false
    @Published var clonando: UUID?

    init(modelo: ModeloAjustes, servico: ServicoLinear = ServicoLinear(), tokens: TokenLinear = TokenLinear()) {
        self.modelo = modelo
        self.servico = servico
        self.tokens = tokens
        linhas = ProjetosConfig.ler(modelo.dados).map { LinhaCadastro(salvo: $0, rascunho: $0) }
    }

    /// Projetos gravados, na ordem da lista.
    var projetos: [ProjetoCadastro] { linhas.compactMap(\.salvo) }
    var temNova: Bool { linhas.contains(where: \.nova) }

    func indice(_ id: UUID) -> Int? { linhas.firstIndex { $0.id == id } }

    /// Grava a lista e devolve às linhas o que ficou no arquivo (o padrão é um só).
    @discardableResult
    private func gravar(_ lista: [ProjetoCadastro], aviso texto: String? = nil, salvando: UUID? = nil) -> Bool {
        do {
            try modelo.definirProjetos(lista)
        } catch {
            erro = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            return false
        }
        let lidos = ProjetosConfig.ler(modelo.dados)
        var novas: [LinhaCadastro] = []
        for p in lidos {
            if var l = linhas.first(where: { $0.salvo?.projetoID == p.projetoID || $0.rascunho.projetoID == p.projetoID }) {
                let editando = l.mudou && l.salvo != nil && l.id != salvando
                l.salvo = p
                if !editando { l.rascunho = p }
                novas.append(l)
            } else {
                novas.append(LinhaCadastro(salvo: p, rascunho: p))
            }
        }
        novas += linhas.filter { l in l.nova && !lidos.contains { p in p.projetoID == l.rascunho.projetoID } }
        linhas = novas
        erro = nil
        aviso = texto ?? String(localized: "Salvo. As lanes usam isso a partir do próximo ciclo (até 60 s).")
        return true
    }

    /// Carrega as duas listas fora da thread da interface.
    func carregarListas() async {
        guard !carregandoListas else { return }
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
            avisoLinear = String(localized: "Conecte o Linear (Ajustes › Contas › Linear) para escolher o projeto.")
        }
        switch await Task.detached(operation: { RepositorioGitHub.listar() }).value {
        case .success(let lista):
            repos = lista
            avisoGitHub = lista.isEmpty ? String(localized: "Nenhum repositório na sua conta do GitHub.") : nil
        case .failure(let e):
            avisoGitHub = e.errorDescription
        }
    }

    // MARK: - Linhas

    func adicionar() {
        if let i = linhas.firstIndex(where: \.nova) { linhas[i].aberto = true; return }
        linhas.append(LinhaCadastro(salvo: nil, rascunho: ProjetosConfig.novo(existentes: projetos), aberto: true))
        erro = nil; aviso = nil
    }

    func alternarAberto(_ id: UUID) {
        guard let i = indice(id) else { return }
        linhas[i].aberto.toggle()
    }

    func cancelar(_ id: UUID) {
        guard let i = indice(id) else { return }
        if let s = linhas[i].salvo {
            linhas[i].rascunho = s
            linhas[i].aberto = false
        } else {
            linhas.remove(at: i)
        }
        erro = nil
    }

    /// Motivo para não salvar a linha (nil = pode salvar).
    func problema(_ l: LinhaCadastro) -> String? {
        if let m = l.rascunho.problema() { return m }
        let outro = linhas.contains { $0.id != l.id && $0.salvo?.projetoID == l.rascunho.projetoID }
        return outro ? String(localized: "Esse projeto do Linear já está no cadastro.") : nil
    }

    func salvar(_ id: UUID) {
        guard let i = indice(id) else { return }
        let l = linhas[i]
        if let m = problema(l) { erro = m; return }
        var lista = projetos
        if let s = l.salvo, let j = lista.firstIndex(where: { $0.projetoID == s.projetoID }) {
            lista[j] = l.rascunho
        } else {
            lista.append(l.rascunho)
        }
        if gravar(lista, salvando: l.id), let k = indice(l.id) {
            linhas[k].aberto = false
        }
    }

    func remover(_ id: UUID) {
        guard let i = indice(id) else { return }
        guard let s = linhas[i].salvo else { linhas.remove(at: i); return }
        linhas.remove(at: i)
        gravar(projetos, aviso: String(localized: "\(s.nome) saiu do cadastro. Nada mudou no Linear nem no GitHub."))
    }

    func alternarAtivo(_ id: UUID, _ ativo: Bool) {
        guard let i = indice(id), let s = linhas[i].salvo else { return }
        var lista = projetos
        guard let j = lista.firstIndex(where: { $0.projetoID == s.projetoID }) else { return }
        lista[j].ativo = ativo
        gravar(lista, aviso: ativo ? String(localized: "\(s.nome) ligado.") : String(localized: "\(s.nome) desligado: as lanes não pegam cards dele."))
    }

    func tornarPrincipal(_ id: UUID) {
        guard let i = indice(id), let s = linhas[i].salvo else { return }
        let lista = projetos.map { p -> ProjetoCadastro in var p = p; p.padrao = p.projetoID == s.projetoID; return p }
        gravar(lista, aviso: String(localized: "\(s.nome) é o principal: as lanes trabalham nele."))
    }

    func mover(_ id: UUID, _ delta: Int) {
        guard let i = indice(id), linhas.indices.contains(i + delta) else { return }
        linhas.swapAt(i, i + delta)
        gravar(projetos, aviso: String(localized: "Ordem salva."))
    }

    // MARK: - Campos do rascunho

    func escolherLinear(_ p: ProjetoLinear, _ id: UUID) {
        guard let i = indice(id) else { return }
        let nomeAntigo = projetosLinear.first { $0.id == linhas[i].rascunho.projetoID }?.nome
        let nome = linhas[i].rascunho.nome
        linhas[i].rascunho.projetoID = p.id
        if nome.isEmpty || nome == nomeAntigo || UUID(uuidString: nome) != nil { linhas[i].rascunho.nome = p.nome }
    }

    func escolherGitHub(_ repo: String, _ id: UUID) {
        guard let i = indice(id) else { return }
        linhas[i].rascunho.github = repo
        if let pasta = RepositorioGitHub.pastaLocal(para: repo, raizes: RepositorioGitHub.raizesPadrao(home: modelo.home)) {
            definirPasta(pasta, i)
        }
    }

    func escolherPasta(_ id: UUID) {
        guard let i = indice(id) else { return }
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.allowsMultipleSelection = false
        painel.prompt = String(localized: "Escolher")
        painel.message = String(localized: "Escolha a pasta do projeto (o clone do repositório).")
        let atual = (linhas[i].rascunho.repo as NSString).expandingTildeInPath
        painel.directoryURL = URL(fileURLWithPath: atual.isEmpty ? modelo.home.appendingPathComponent("Developer").path : atual)
        if painel.runModal() == .OK, let url = painel.url { definirPasta(url, i) }
    }

    /// Pasta escolhida: guarda com `~` e, num projeto novo sem prova escolhida, sugere a prova.
    private func definirPasta(_ pasta: URL, _ i: Int) {
        linhas[i].rascunho.repo = Self.comTil(pasta, home: modelo.home)
        let prova = linhas[i].rascunho.prova.trimmingCharacters(in: .whitespaces)
        if linhas[i].nova, prova.isEmpty || prova == SugestaoProva.padrao,
           let primeira = SugestaoProva.para(pasta: pasta).first {
            linhas[i].rascunho.prova = primeira.comando
        }
    }

    func sugestoes(_ l: LinhaCadastro) -> [SugestaoProva.Item] {
        let caminho = (l.rascunho.repo as NSString).expandingTildeInPath
        return caminho.isEmpty ? [] : SugestaoProva.para(pasta: URL(fileURLWithPath: caminho))
    }

    /// Só no clique: `gh repo clone` em `~/Developer/<repo>`.
    func clonar(_ id: UUID) async {
        guard let i = indice(id) else { return }
        let repo = linhas[i].rascunho.github
        guard let destino = RepositorioGitHub.destinoDoClone(repo, home: modelo.home) else { return }
        clonando = id
        defer { clonando = nil }
        switch await Task.detached(operation: { RepositorioGitHub.clonar(repo, em: destino) }).value {
        case .success(let pasta):
            if let k = indice(id) { definirPasta(pasta, k) }
            erro = nil
        case .failure(let e):
            erro = e.errorDescription
        }
    }

    static func comTil(_ pasta: URL, home: URL) -> String {
        let h = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        return pasta.path.hasPrefix(h + "/") ? "~" + pasta.path.dropFirst(h.count) : pasta.path
    }

    /// `origin` da pasta, já em `dono/repo`. nil = a pasta não é um clone.
    func origemDaPasta(_ p: ProjetoCadastro) -> String? {
        let caminho = (p.repo as NSString).expandingTildeInPath
        guard !caminho.isEmpty else { return nil }
        return RepositorioGitHub.origem(da: URL(fileURLWithPath: caminho)).flatMap(RepositorioGitHub.normalizar)
    }
}

struct SecaoProjetos: View {
    /// @StateObject: a página de Ajustes se redesenha a cada poucos segundos e não pode
    /// recriar o estado (perdia as listas e o que estava sendo digitado).
    @StateObject var estado: EstadoProjetos
    /// Embutido nos Ajustes: o título vem do grupo, não de outro Section.
    var embutido = false

    init(estado: @autoclosure @escaping () -> EstadoProjetos, embutido: Bool = false) {
        _estado = StateObject(wrappedValue: estado())
        self.embutido = embutido
    }

    var body: some View {
        Group {
            if embutido {
                conteudo
                rodape
            } else {
                Section {
                    conteudo
                } footer: {
                    rodape
                }
            }
        }
        .task { await estado.carregarListas() }
    }

    @ViewBuilder
    private var conteudo: some View {
        if let e = estado.erro {
            Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        } else if let a = estado.aviso {
            Label(a, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        }
        if estado.linhas.isEmpty {
            Text(String(localized: "Nenhum projeto ainda. Adicione o primeiro: escolha o projeto do Linear e o repositório do GitHub em que as lanes vão trabalhar."))
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach($estado.linhas) { $l in
            LinhaProjeto(linha: $l, estado: estado)
        }
        Button { estado.adicionar() } label: {
            Label(String(localized: "Adicionar projeto"), systemImage: "plus")
        }
        .disabled(estado.temNova)
    }

    private var rodape: some View {
        Text(String(localized: "As lanes pegam cards só de projetos ligados. Com mais de um ligado, vale o principal; os outros esperam a vez."))
            .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Uma linha da lista e, aberta, o formulário dela. Cada campo é uma linha do Form, para o
/// rótulo ficar à esquerda e o valor à direita (sem rótulo repetido dentro da caixa).
private struct LinhaProjeto: View {
    @Binding var linha: LinhaCadastro
    @ObservedObject var estado: EstadoProjetos
    @State private var confirmarRemocao = false

    private var p: ProjetoCadastro { linha.rascunho }
    private var principal: Bool {
        guard let s = linha.salvo, ProjetosConfig.mostrarPrincipal(estado.projetos) else { return false }
        return ProjetosConfig.padrao(estado.projetos)?.projetoID == s.projetoID
    }
    private var posicao: Int { estado.indice(linha.id) ?? 0 }

    var body: some View {
        cabecalho
        if linha.aberto { formulario }
    }

    // MARK: Cabeçalho

    private var cabecalho: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(linha.nova ? String(localized: "Projeto novo") : (linha.salvo?.nome ?? p.nome))
                        .font(.body.weight(.medium))
                    if principal { Selo(texto: String(localized: "Principal"), cor: .accentColor) }
                    if let s = linha.salvo, !s.ativo { Selo(texto: String(localized: "Desligado"), cor: .secondary) }
                    if linha.mudou && !linha.nova { Selo(texto: String(localized: "Não salvo"), cor: .orange) }
                }
                Text(resumo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onTapGesture { estado.alternarAberto(linha.id) }
            Spacer()
            if let s = linha.salvo {
                Toggle(String(localized: "Ligado"), isOn: Binding(get: { s.ativo }, set: { estado.alternarAtivo(linha.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help(String(localized: "Ligado: as lanes podem pegar cards deste projeto."))
            }
            Menu {
                Button(linha.aberto ? String(localized: "Fechar") : String(localized: "Editar")) { estado.alternarAberto(linha.id) }
                if let s = linha.salvo, s.ativo, ProjetosConfig.mostrarPrincipal(estado.projetos), !principal {
                    Button(String(localized: "Tornar principal")) { estado.tornarPrincipal(linha.id) }
                }
                if !linha.nova && estado.projetos.count > 1 {
                    Button(String(localized: "Mover para cima")) { estado.mover(linha.id, -1) }.disabled(posicao == 0)
                    Button(String(localized: "Mover para baixo")) { estado.mover(linha.id, 1) }
                        .disabled(posicao >= estado.projetos.count - 1)
                }
                Divider()
                Button(linha.nova ? String(localized: "Descartar") : String(localized: "Remover…"), role: .destructive) {
                    if linha.nova { estado.cancelar(linha.id) } else { confirmarRemocao = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(String(localized: "Mais ações"))
        }
        .confirmationDialog(String(localized: "Remover \(linha.salvo?.nome ?? "") do cadastro?"), isPresented: $confirmarRemocao) {
            Button(String(localized: "Remover"), role: .destructive) { estado.remover(linha.id) }
        } message: {
            Text(String(localized: "As lanes deixam de pegar cards deste projeto. Nada muda no Linear, no GitHub nem na pasta."))
        }
    }

    private var resumo: String {
        let lin = estado.projetosLinear.first { $0.id == p.projetoID }?.rotulo
            ?? (p.projetoID.isEmpty ? String(localized: "Linear: escolha o projeto") : String(localized: "Linear: projeto escolhido"))
        let gh = p.github.isEmpty ? String(localized: "GitHub: escolha o repositório") : p.github
        let pasta = p.repo.isEmpty ? String(localized: "sem pasta") : p.repo
        return [lin, gh, pasta].joined(separator: " · ")
    }

    // MARK: Formulário

    @ViewBuilder private var formulario: some View {
        campoLinear
        campoGitHub
        campoPasta
        TextField(String(localized: "Nome"), text: $linha.rascunho.nome, prompt: Text(String(localized: "Como aparece no TuttiDash")))
        campoProva
        DisclosureGroup(String(localized: "Avançado")) {
            TextField(String(localized: "Pasta dos worktrees"), text: $linha.rascunho.worktrees,
                      prompt: Text(p.repo.isEmpty ? String(localized: "vazio = <pasta>-worktrees") : p.worktreesEfetivo))
            Stepper(value: $linha.rascunho.provaTentativas, in: 1...5) {
                Text(String(localized: "Tentativas da prova: \(p.provaTentativas)"))
            }
            TextField(String(localized: "Conferência antes do push"), text: $linha.rascunho.antesDoPush,
                      prompt: Text(String(localized: "comando; vazio = nenhuma")))
            CampoLinhas(titulo: String(localized: "Caminhos protegidos"),
                        ajuda: String(localized: "Um por linha. A lane para se mexer num deles."),
                        valores: $linha.rascunho.protegidos)
            CampoLinhas(titulo: String(localized: "Copiar para o worktree"),
                        ajuda: String(localized: "Um por linha. Arquivos fora do git que a lane precisa (ex.: AGENTS.md)."),
                        valores: $linha.rascunho.copiarParaWorktree)
        }
        acoes
    }

    @ViewBuilder private var campoLinear: some View {
        if estado.projetosLinear.isEmpty {
            LabeledContent(String(localized: "Projeto no Linear")) {
                ListaIndisponivel(aviso: estado.avisoLinear, carregando: estado.carregandoListas) {
                    Task { await estado.carregarListas() }
                }
            }
        } else {
            Picker(String(localized: "Projeto no Linear"), selection: Binding<String>(
                get: { p.projetoID },
                set: { id in if let x = estado.projetosLinear.first(where: { $0.id == id }) { estado.escolherLinear(x, linha.id) } })) {
                if !estado.projetosLinear.contains(where: { $0.id == p.projetoID }) {
                    Text(p.projetoID.isEmpty ? String(localized: "Escolha…") : String(localized: "(fora da lista)")).tag(p.projetoID)
                }
                ForEach(estado.projetosLinear) { x in Text(x.rotulo).tag(x.id) }
            }
        }
    }

    @ViewBuilder private var campoGitHub: some View {
        if estado.repos.isEmpty {
            LabeledContent(String(localized: "Repositório no GitHub")) {
                ListaIndisponivel(aviso: estado.avisoGitHub, carregando: estado.carregandoListas) {
                    Task { await estado.carregarListas() }
                }
            }
        } else {
            Picker(String(localized: "Repositório no GitHub"), selection: Binding<String>(
                get: { p.github }, set: { estado.escolherGitHub($0, linha.id) })) {
                if !estado.repos.contains(p.github) {
                    Text(p.github.isEmpty ? String(localized: "Escolha…") : p.github).tag(p.github)
                }
                ForEach(estado.repos, id: \.self) { r in Text(r).tag(r) }
            }
        }
    }

    @ViewBuilder private var campoPasta: some View {
        LabeledContent(String(localized: "Pasta neste Mac")) {
            HStack(spacing: 8) {
                Text(p.repo.isEmpty ? String(localized: "nenhuma") : p.repo)
                    .foregroundStyle(p.repo.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button(String(localized: "Escolher…")) { estado.escolherPasta(linha.id) }
            }
        }
        if !p.github.isEmpty {
            let origem = estado.origemDaPasta(p)
            if origem == p.github {
                Label(String(localized: "A pasta é um clone de \(p.github)."), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                HStack {
                    Label(p.repo.isEmpty
                          ? String(localized: "Não achei um clone de \(p.github) neste Mac.")
                          : (origem == nil
                             ? String(localized: "Esta pasta não é um clone de \(p.github); as lanes não enviam nada daqui.")
                             : String(localized: "Esta pasta é de \(origem!), não de \(p.github); as lanes não enviam nada daqui.")),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if let destino = RepositorioGitHub.destinoDoClone(p.github, home: estado.modelo.home) {
                        Button(estado.clonando == linha.id
                               ? String(localized: "Clonando…")
                               : String(localized: "Clonar em \(EstadoProjetos.comTil(destino, home: estado.modelo.home))")) {
                            Task { await estado.clonar(linha.id) }
                        }
                        .disabled(estado.clonando != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var campoProva: some View {
        let sugeridas = estado.sugestoes(linha)
        LabeledContent(String(localized: "Prova")) {
            HStack(spacing: 6) {
                TextField(String(localized: "Prova"), text: $linha.rascunho.prova,
                          prompt: Text("swift test --filter {suite}"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                Menu(String(localized: "Sugestões")) {
                    if !sugeridas.isEmpty {
                        Section(String(localized: "Achadas nesta pasta")) {
                            ForEach(sugeridas, id: \.self) { s in
                                Button("\(s.titulo): \(s.comando)") { linha.rascunho.prova = s.comando }
                            }
                        }
                    }
                    Section(String(localized: "Exemplos")) {
                        ForEach(SugestaoProva.exemplos, id: \.self) { s in
                            Button("\(s.titulo): \(s.comando)") { linha.rascunho.prova = s.comando }
                        }
                    }
                }
                .fixedSize()
            }
        }
        Text(String(localized: "O comando que roda os testes quando a lane termina. {suite} é trocado pelo teste que o card pede."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private var acoes: some View {
        let motivo = estado.problema(linha)
        return HStack {
            if let motivo, linha.mudou || linha.nova {
                Label(motivo, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button(String(localized: "Cancelar")) { estado.cancelar(linha.id) }
            Button(linha.nova ? String(localized: "Adicionar") : String(localized: "Salvar")) { estado.salvar(linha.id) }
                .buttonStyle(.borderedProminent)
                .disabled(motivo != nil || !linha.mudou)
        }
    }
}

/// Lista que ainda não chegou (carregando) ou não pôde ser lida (aviso + tentar de novo).
private struct ListaIndisponivel: View {
    let aviso: String?
    let carregando: Bool
    let tentar: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            if carregando {
                ProgressView().controlSize(.small)
                Text(String(localized: "Carregando…")).foregroundStyle(.secondary)
            } else {
                Text(aviso ?? String(localized: "Lista indisponível.")).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                Button(String(localized: "Tentar de novo"), action: tentar)
            }
        }
    }
}

private struct Selo: View {
    let texto: String
    let cor: Color
    var body: some View {
        Text(texto).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(cor.opacity(0.18), in: Capsule())
            .foregroundStyle(cor)
    }
}

/// Lista de texto, um item por linha. O texto cru fica no `@State` enquanto se digita (senão a
/// linha vazia do Enter some na hora) e vira a lista a cada mudança.
private struct CampoLinhas: View {
    let titulo: String
    let ajuda: String
    @Binding var valores: [String]
    @State private var texto = ""

    private static func lista(_ t: String) -> [String] {
        t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo)
            TextEditor(text: $texto)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text(ajuda).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { texto = valores.joined(separator: "\n") }
        .onChange(of: texto) { _, novo in
            let l = Self.lista(novo)
            if l != valores { valores = l }
        }
        .onChange(of: valores) { _, novos in
            if Self.lista(texto) != novos { texto = novos.joined(separator: "\n") }
        }
    }
}
