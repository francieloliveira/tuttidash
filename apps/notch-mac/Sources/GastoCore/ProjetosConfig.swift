import Foundation

/// Cadastro de projetos que o dispatcher e o vigia enxergam — espelho Swift de
/// `gasto_lanes/projetos.py`, que é quem os dois leem de verdade.
///
/// Fonte: chave `projetos` da config (a mesma que o app escreve). Um projeto é
/// onde a lane trabalha: repo, worktrees, projeto do Linear e o comando de prova.
/// Sem a chave, não há projeto: o app mostra o cadastro vazio (FRA-565).
///
/// Adicionar um projeto aqui é o que o dispatcher enxerga: não há lista escrita
/// em código para atualizar junto.
public struct ProjetoCadastro: Identifiable, Equatable, Sendable {
    public var id: String            { projetoID }
    /// UUID do projeto no Linear. É a chave; duas entradas com o mesmo id não fazem sentido.
    public var projetoID: String
    public var nome: String
    /// false deixa o projeto listado (o app mostra) sem o dispatcher assumir card nele.
    public var ativo: Bool
    /// O projeto que o dispatcher trabalha neste ciclo. Sem ninguém marcado, vale o
    /// primeiro ativo da lista — a ordem da lista é a ordem de preferência.
    public var padrao: Bool
    public var repo: String
    /// Vazio = `<repo>-worktrees`.
    public var worktrees: String
    /// Comando da prova com `{suite}` no lugar da suíte que o agente pediu.
    public var prova: String
    /// 1 roda a prova uma vez; 2 repete a 2ª sem `SKIP_PREFLIGHT` (o que o
    /// script de prova com preflight caro precisa).
    public var provaTentativas: Int
    /// Globs, relativos ao repo, que nenhuma lane pode tocar.
    public var protegidos: [String]
    /// Arquivos fora do git no repo (ex.: `AGENTS.md` gerado na máquina) que o dispatcher
    /// copia para cada worktree de lane. Relativos ao repo; nunca sobrescrevem.
    public var copiarParaWorktree: [String]
    /// Repositório no GitHub (`dono/repo`, FRA-567). O dispatcher só envia a branch se o
    /// `origin` da pasta for este repositório.
    public var github: String
    /// Comando que roda no worktree antes de cada push da lane (ex.: a conferência de
    /// publicação de um repositório público). Vazio = sem conferência.
    public var antesDoPush: String

    /// Freio padrão quando o projeto não declara o seu: a config dos agentes do projeto
    /// (igual ao `PROTEGIDOS_PADRAO` do `projetos.py`).
    public static let protegidosPadrao = [".claude/*", ".mcp.json"]

    public init(projetoID: String, nome: String = "", ativo: Bool = true, padrao: Bool = false,
                repo: String = "", worktrees: String = "", prova: String = "python3 {suite}",
                provaTentativas: Int = 1, protegidos: [String] = [], copiarParaWorktree: [String] = [],
                antesDoPush: String = "", github: String = "") {
        self.projetoID = projetoID
        self.nome = nome.isEmpty ? projetoID : nome
        self.ativo = ativo
        self.padrao = padrao
        self.repo = repo
        self.worktrees = worktrees
        self.prova = prova
        self.provaTentativas = max(1, provaTentativas)
        self.protegidos = protegidos
        self.copiarParaWorktree = copiarParaWorktree
        self.antesDoPush = antesDoPush.trimmingCharacters(in: .whitespaces)
        self.github = RepositorioGitHub.normalizar(github) ?? github.trimmingCharacters(in: .whitespaces)
    }

    /// Pasta de worktrees efetiva: a declarada ou `<repo>-worktrees`.
    public var worktreesEfetivo: String {
        if !worktrees.trimmingCharacters(in: .whitespaces).isEmpty { return worktrees }
        return repo.hasSuffix("-worktrees") ? repo : repo + "-worktrees"
    }

    /// Freio efetivo: o declarado ou a lista padrão.
    public var protegidosEfetivos: [String] {
        protegidos.isEmpty ? Self.protegidosPadrao : protegidos
    }

    /// Verificação de preenchimento, na ordem em que trava o cadastro.
    /// nil = válido; senão a mensagem (localizada).
    public func problema() -> String? {
        let pid = projetoID.trimmingCharacters(in: .whitespaces)
        let repoLimpo = repo.trimmingCharacters(in: .whitespaces)
        if pid.isEmpty { return String(localized: "Escolha o projeto do Linear.") }
        if UUID(uuidString: pid) == nil {
            return String(localized: "O projeto do Linear não é válido; escolha de novo na lista.")
        }
        if repoLimpo.isEmpty { return String(localized: "Escolha a pasta do projeto neste Mac.") }
        if !github.isEmpty, RepositorioGitHub.normalizar(github) == nil {
            return String(localized: "Repositório do GitHub inválido (use dono/repo).")
        }
        if !repoLimpo.hasPrefix("/") && !repoLimpo.hasPrefix("~") {
            return String(localized: "A pasta tem que começar com / ou ~.")
        }
        if !prova.trimmingCharacters(in: .whitespaces).isEmpty,
           !prova.contains("{suite}") {
            return String(localized: "A prova precisa ter {suite} no lugar do teste.")
        }
        if provaTentativas < 1 { return String(localized: "Mínimo de 1 tentativa.") }
        return nil
    }
}

/// Leitura e escrita da chave `projetos` no config.json.
public enum ProjetosConfig {
    public static let chave = "projetos"

    /// Projetos declarados na config. Sem a chave (ou só com itens inválidos), lista
    /// vazia: o app mostra o cadastro em branco e o dispatcher fica parado (FRA-565).
    public static func ler(_ dados: [String: Any]) -> [ProjetoCadastro] {
        guard let bruto = dados[chave] as? [[String: Any]] else { return [] }
        var vistos = Set<String>()
        let saida = bruto.compactMap { item -> ProjetoCadastro? in
            let pid = "\(item["id"] ?? "")".trimmingCharacters(in: .whitespaces)
            guard !pid.isEmpty, vistos.insert(pid).inserted else { return nil }
            let ativos = item["ativo"]
            let ativosBool: Bool = if let n = ativos as? NSNumber, JV.ehBool(n) { n.boolValue }
                                   else { "\(ativos ?? "true")".lowercased() != "false" }
            let nome = "\(item["nome"] ?? pid)"
            let worktrees = "\(item["worktrees"] ?? "")"
            let prova = "\(item["prova"] ?? "python3 {suite}")"
            let tentativas = (item["prova_tentativas"] as? NSNumber)?.intValue ?? 1
            let prot = (item["protegidos"] as? [String]) ?? []
            let copiar = ((item["copiar_para_worktree"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ProjetoCadastro(projetoID: pid, nome: nome.isEmpty ? pid : nome,
                                   ativo: ativosBool, padrao: (item["padrao"] as? NSNumber)?.boolValue ?? false,
                                   repo: "\(item["repo"] ?? "")",
                                   worktrees: worktrees.isEmpty ? "" : worktrees,
                                   prova: prova.isEmpty ? "python3 {suite}" : prova,
                                   provaTentativas: tentativas, protegidos: prot,
                                   copiarParaWorktree: copiar,
                                   antesDoPush: "\(item["antes_do_push"] ?? "")",
                                   github: "\(item["github"] ?? "")")
        }.filter { $0.problema() == nil }
        return saida
    }

    /// Converte para o formato que o Python lê.
    public static func dict(_ projetos: [ProjetoCadastro]) -> [[String: Any]] {
        projetos.map { p in
            var item: [String: Any] = [
                "id": p.projetoID, "nome": p.nome, "ativo": p.ativo, "padrao": p.padrao,
                "repo": p.repo, "prova": p.prova, "prova_tentativas": p.provaTentativas,
            ]
            if !p.worktrees.isEmpty { item["worktrees"] = p.worktrees }
            if !p.protegidos.isEmpty { item["protegidos"] = p.protegidos }
            if !p.copiarParaWorktree.isEmpty { item["copiar_para_worktree"] = p.copiarParaWorktree }
            if !p.antesDoPush.isEmpty { item["antes_do_push"] = p.antesDoPush }
            if !p.github.isEmpty { item["github"] = p.github }
            return item
        }
    }

    /// Grava o cadastro em `dados` (in place), com no máximo um `padrao`: marcar
    /// um desmarca o anterior, senão o Python cairia no primeiro da lista e o app
    /// mostraria outro como padrão.
    public static func gravar(_ projetos: [ProjetoCadastro], em dados: inout [String: Any]) {
        var saida = projetos
        if let i = saida.firstIndex(where: { $0.padrao }) {
            for j in saida.indices where j != i { saida[j].padrao = false }
        }
        dados[chave] = dict(saida)
    }

    /// Projeto novo do cadastro (FRA-579): nasce ligado só quando nenhum outro está ligado,
    /// para não trocar o que as lanes estão fazendo sem a pessoa perceber.
    public static func novo(existentes: [ProjetoCadastro]) -> ProjetoCadastro {
        ProjetoCadastro(projetoID: "", nome: "", ativo: !existentes.contains(where: \.ativo), repo: "")
    }

    /// "Principal" só faz sentido com mais de um projeto ligado.
    public static func mostrarPrincipal(_ projetos: [ProjetoCadastro]) -> Bool {
        projetos.filter(\.ativo).count > 1
    }

    /// Projeto que o dispatcher trabalha: o marcado, ou o primeiro ativo.
    public static func padrao(_ projetos: [ProjetoCadastro]) -> ProjetoCadastro? {
        let ativos = projetos.filter(\.ativo)
        if ativos.isEmpty { return nil }
        return ativos.first(where: \.padrao) ?? ativos[0]
    }
}