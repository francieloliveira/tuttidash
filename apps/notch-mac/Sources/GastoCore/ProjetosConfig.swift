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
/// FRA-698: como o projeto se instala. Três classes, não um tipo por projeto.
///
/// `servico`: há um processo de pé (subir/parar, porta, saúde, URL).
/// `artefato`: há um pacote produzido e instalado num destino (empacotar, validar,
/// instalar). `nenhuma`: não se instala; a entrega é o commit/tag.
///
/// Os comandos são uma linha de texto (programa + argumentos) e rodam **sem shell**:
/// o Python parte com `shlex.split`. Marcadores: `{porta}`, `{artefato}`, `{destino}`,
/// `{pid}`, `{log}`, `{ref}`, `{worktree}`, `{head}` e `{repo}`. A tela só lê o estado e chama
/// `tools/instalar.py`; quem age é o Python. A chave do config continua `entrega`.
public struct InstalacaoCadastro: Equatable, Sendable {
    public enum Classe: String, CaseIterable, Equatable, Sendable {
        case nenhuma, servico, artefato

        public var rotulo: String {
            switch self {
            case .nenhuma: return String(localized: "Nenhuma")
            case .servico: return String(localized: "Serviço")
            case .artefato: return String(localized: "Artefato instalável")
            }
        }

        public var ajuda: String {
            switch self {
            case .nenhuma:
                return String(localized: "Não se instala: a entrega é o commit/tag no git.")
            case .servico:
                return String(localized: "Há um processo que fica de pé: sobe, responde no health check e para.")
            case .artefato:
                return String(localized: "Há um pacote produzido e instalado num destino: empacota, valida e instala.")
            }
        }
    }

    public var classe: Classe
    public var empacotar: String
    public var validar: String
    public var instalar: String
    public var subir: String
    public var parar: String
    public var versao: String
    /// Texto para a porta (vazio = sem porta). A validação numérica fica em `problema()`.
    public var porta: String
    public var saude: String
    public var url: String
    public var artefato: String
    public var destino: String
    /// O vigia não pode pedir senha: artefato com administrador só instala pela tela.
    public var requerAdmin: Bool
    /// Classe lida do arquivo que o app não conhece: preservada ao salvar, recusada pelo Python.
    public var classeDesconhecida: String

    public init(classe: Classe = .nenhuma, empacotar: String = "", validar: String = "",
                instalar: String = "", subir: String = "", parar: String = "", versao: String = "",
                porta: String = "", saude: String = "", url: String = "", artefato: String = "",
                destino: String = "", requerAdmin: Bool = false, classeDesconhecida: String = "") {
        self.classe = classe
        self.empacotar = empacotar
        self.validar = validar
        self.instalar = instalar
        self.subir = subir
        self.parar = parar
        self.versao = versao
        self.porta = porta
        self.saude = saude
        self.url = url
        self.artefato = artefato
        self.destino = destino
        self.requerAdmin = requerAdmin
        self.classeDesconhecida = classeDesconhecida
    }

    /// Vazia de verdade: nenhuma classe escolhida e nenhum campo preenchido.
    public var vazia: Bool {
        classe == .nenhuma && classeDesconhecida.isEmpty && empacotar.isEmpty && validar.isEmpty
            && instalar.isEmpty && subir.isEmpty && parar.isEmpty && versao.isEmpty
            && porta.isEmpty && saude.isEmpty && url.isEmpty && artefato.isEmpty
            && destino.isEmpty && !requerAdmin
    }

    /// `{porta}` num endereço exige porta numérica.
    private var usaPorta: Bool { saude.contains("{porta}") || url.contains("{porta}") }

    public func problema() -> String? {
        if !classeDesconhecida.isEmpty {
            return String(localized: "A entrega tem uma classe que o app não conhece (\(classeDesconhecida)). Corrija no config.json ou escolha uma classe aqui.")
        }
        switch classe {
        case .nenhuma:
            return nil
        case .servico:
            if subir.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Serviço: diga o comando de subir.")
            }
            if usaPorta, Int(porta.trimmingCharacters(in: .whitespaces)) == nil {
                return String(localized: "Serviço: o endereço usa {porta}; informe a porta.")
            }
        case .artefato:
            if instalar.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Artefato: diga o comando de instalar.")
            }
            if destino.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Artefato: diga o destino da instalação.")
            }
        }
        for (rotulo, comando) in [("empacotar", empacotar), ("validar", validar),
                                  ("instalar", instalar), ("subir", subir),
                                  ("parar", parar), ("versão", versao)] where !comando.isEmpty {
            if !Self.aspasBalanceadas(comando) {
                return String(localized: "Entrega: aspas sem fechar no comando de \(rotulo).")
            }
        }
        return nil
    }

    /// Confere só o pareamento de aspas simples e duplas (o `shlex` do Python é a autoridade).
    static func aspasBalanceadas(_ texto: String) -> Bool {
        var simples = false, duplas = false, escapado = false
        for c in texto {
            if escapado { escapado = false; continue }
            if c == "\\" && !simples { escapado = true; continue }
            if c == "'" && !duplas { simples.toggle() }
            else if c == "\"" && !simples { duplas.toggle() }
        }
        return !simples && !duplas && !escapado
    }

    /// O dicionário que o Python lê. `nil` quando a entrega é vazia (chave ausente = nenhuma).
    public func dict() -> [String: Any]? {
        if vazia { return nil }
        var d: [String: Any] = [
            "classe": classeDesconhecida.isEmpty ? classe.rawValue : classeDesconhecida,
        ]
        for (chave, valor) in [("empacotar", empacotar), ("validar", validar),
                               ("instalar", instalar), ("subir", subir), ("parar", parar),
                               ("versao", versao), ("saude", saude), ("url", url),
                               ("artefato", artefato), ("destino", destino)] {
            let s = valor.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { d[chave] = s }
        }
        if let n = Int(porta.trimmingCharacters(in: .whitespaces)), n > 0 { d["porta"] = n }
        if requerAdmin { d["requer_admin"] = true }
        return d
    }

    /// Lê a chave `entrega` do cadastro. Ausente ou fora de forma = nenhuma.
    public static func ler(_ bruto: [String: Any]?) -> InstalacaoCadastro {
        guard let bruto, !bruto.isEmpty else { return InstalacaoCadastro() }
        let declarada = "\(bruto["classe"] ?? "nenhuma")".trimmingCharacters(in: .whitespaces).lowercased()
        let conhecida = Classe(rawValue: declarada)
        func texto(_ chave: String) -> String {
            if let s = bruto[chave] as? String { return s }
            if let lista = bruto[chave] as? [String] {
                return lista.map(Self.citar).joined(separator: " ")
            }
            return ""
        }
        return InstalacaoCadastro(
            classe: conhecida ?? .nenhuma,
            empacotar: texto("empacotar"), validar: texto("validar"),
            instalar: texto("instalar"), subir: texto("subir"), parar: texto("parar"),
            versao: texto("versao"),
            porta: bruto["porta"].map { "\($0)" } ?? "",
            saude: texto("saude"), url: texto("url"),
            artefato: texto("artefato"), destino: texto("destino"),
            requerAdmin: (bruto["requer_admin"] as? NSNumber)?.boolValue ?? false,
            classeDesconhecida: conhecida == nil ? declarada : "")
    }

    /// Um argumento de argv vira texto citável, para lista escrita à mão não perder o espaço.
    static func citar(_ s: String) -> String {
        guard s.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Marco de planejamento do projeto. Não muda a execução; só o retrato de gestão.
public struct MarcoCadastro: Equatable, Sendable {
    public var nome: String
    public var data: String
    public var feito: Bool

    public init(nome: String, data: String = "", feito: Bool = false) {
        self.nome = nome
        self.data = data
        self.feito = feito
    }
}

public struct PlanejamentoCadastro: Equatable, Sendable {
    public var objetivo: String
    public var situacao: String
    public var inicio: String
    public var alvo: String
    public var marcos: [MarcoCadastro]

    public init(objetivo: String = "", situacao: String = "", inicio: String = "",
                alvo: String = "", marcos: [MarcoCadastro] = []) {
        self.objetivo = objetivo
        self.situacao = situacao
        self.inicio = inicio
        self.alvo = alvo
        self.marcos = marcos
    }

    public var vazio: Bool {
        objetivo.isEmpty && situacao.isEmpty && inicio.isEmpty && alvo.isEmpty && marcos.isEmpty
    }

    public static func ler(_ bruto: [String: Any]?) -> PlanejamentoCadastro {
        guard let bruto else { return PlanejamentoCadastro() }
        let marcos = (bruto["marcos"] as? [[String: Any]] ?? []).compactMap { m -> MarcoCadastro? in
            guard let nome = JV.texto(m["nome"]), !nome.isEmpty else { return nil }
            return MarcoCadastro(nome: nome, data: JV.texto(m["data"]) ?? "",
                                 feito: JV.verdadeiro(m["feito"]))
        }
        return PlanejamentoCadastro(objetivo: JV.texto(bruto["objetivo"]) ?? "",
                                    situacao: JV.texto(bruto["situacao"]) ?? "",
                                    inicio: JV.texto(bruto["inicio"]) ?? "",
                                    alvo: JV.texto(bruto["alvo"]) ?? "",
                                    marcos: Array(marcos.prefix(30)))
    }

    public func dict() -> [String: Any]? {
        if vazio { return nil }
        var d: [String: Any] = [:]
        if !objetivo.isEmpty { d["objetivo"] = objetivo }
        if !situacao.isEmpty { d["situacao"] = situacao }
        if !inicio.isEmpty { d["inicio"] = inicio }
        if !alvo.isEmpty { d["alvo"] = alvo }
        if !marcos.isEmpty {
            d["marcos"] = marcos.map { ["nome": $0.nome, "data": $0.data, "feito": $0.feito] }
        }
        return d
    }
}

public struct RepositorioCadastro: Equatable, Sendable {
    public var slug: String
    public var github: String
    public var repo: String
    public var worktrees: String
    public var prova: String
    public var protegidos: [String]
    public var pastasDoApp: [String]

    public init(slug: String, repo: String, github: String = "", worktrees: String = "",
                prova: String = "", protegidos: [String] = [], pastasDoApp: [String] = []) {
        self.slug = slug
        self.repo = repo
        self.github = github
        self.worktrees = worktrees
        self.prova = prova
        self.protegidos = protegidos
        self.pastasDoApp = pastasDoApp
    }
}

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
    /// Ordem inicial da agenda multi-projeto; maior primeiro. 0 = padrão.
    public var prioridade: Int
    /// Limites deste projeto; vazio/0 herda o global (`lanes.*`).
    public var budgetUSD: [String: Double]
    public var laneTimeoutMin: Int
    public var proofTimeoutMin: Int
    public var maxLanes: Int
    public var maxTarefasPorLane: Int
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
    /// Suítes da prova. Se o projeto declara, a lane só roda um nome desta lista
    /// (`proof_suites` no dispatcher). Vazio: a lane pede o nome, no formato certo.
    /// O app não edita, mas guarda: antes, salvar o cadastro apagava a lista (revisão do PR #19).
    public var suites: [String]
    /// Modo bancada (FRA-618): a lane `claude` ganha o comando `bancada` (USB) nos cards com a
    /// etiqueta `lane:bancada`. Grava `"bancada": {"ativo": true}`.
    public var bancada: Bool
    /// Pastas que só o Mac prova (FRA-620). A `prova-remota` no Linux fica vermelha nelas.
    /// O app não edita, mas guarda: sem isto, salvar o cadastro apagava a lista.
    public var pastasDoApp: [String]
    /// Arquivo de norte do projeto, relativo ao repo (o wizard grava `docs/produto/caminho.md`).
    /// Entra sempre no freio, por cima do declarado ou do padrão: nenhuma lane edita o norte.
    /// Vazio = projeto sem norte. Caminho que não serve (absoluto, `~`, `..`) é descartado.
    public var norte: String
    /// FRA-698: como o projeto se instala (serviço, artefato ou nenhuma).
    public var instalacao: InstalacaoCadastro
    /// Metadados de planejamento (FRA-715); não alteram a execução.
    public var planejamento: PlanejamentoCadastro
    /// Repositórios do projeto (FRA-711); vazio = repo único.
    public var repos: [RepositorioCadastro]

    /// Freio padrão quando o projeto não declara o seu: a config dos agentes do projeto
    /// (igual ao `PROTEGIDOS_PADRAO` do `projetos.py`).
    public static let protegidosPadrao = [".claude/*", ".mcp.json"]

    public init(projetoID: String, nome: String = "", ativo: Bool = true, padrao: Bool = false,
                repo: String = "", worktrees: String = "", prova: String = "python3 {suite}",
                provaTentativas: Int = 1, protegidos: [String] = [], copiarParaWorktree: [String] = [],
                antesDoPush: String = "", github: String = "", suites: [String] = [],
                bancada: Bool = false, pastasDoApp: [String] = [], norte: String = "",
                instalacao: InstalacaoCadastro = InstalacaoCadastro(), prioridade: Int = 0,
                budgetUSD: [String: Double] = [:], laneTimeoutMin: Int = 0,
                proofTimeoutMin: Int = 0, maxLanes: Int = 0, maxTarefasPorLane: Int = 0,
                planejamento: PlanejamentoCadastro = PlanejamentoCadastro(),
                repos: [RepositorioCadastro] = []) {
        self.projetoID = projetoID
        self.nome = nome.isEmpty ? projetoID : nome
        self.ativo = ativo
        self.padrao = padrao
        self.prioridade = max(0, prioridade)
        self.budgetUSD = budgetUSD.filter { $0.value > 0 }
        self.laneTimeoutMin = max(0, laneTimeoutMin)
        self.proofTimeoutMin = max(0, proofTimeoutMin)
        self.maxLanes = max(0, maxLanes)
        self.maxTarefasPorLane = max(0, maxTarefasPorLane)
        self.repo = repo
        self.worktrees = worktrees
        self.prova = prova
        self.provaTentativas = max(1, provaTentativas)
        self.protegidos = protegidos
        self.copiarParaWorktree = copiarParaWorktree
        self.antesDoPush = antesDoPush.trimmingCharacters(in: .whitespaces)
        self.github = RepositorioGitHub.normalizar(github) ?? github.trimmingCharacters(in: .whitespaces)
        self.suites = suites
        self.bancada = bancada
        self.pastasDoApp = pastasDoApp
        self.norte = Self.norteValido(norte)
        self.instalacao = instalacao
        self.planejamento = planejamento
        self.repos = repos
    }

    /// Mesma regra do `norte_valido` do `projetos.py`: relativo ao repo, sem `~`, `..`,
    /// `.`, segmento vazio, barra invertida ou quebra de linha. Fora disso, vazio.
    public static func norteValido(_ valor: String) -> String {
        let s = valor.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains("\n"), !s.contains("\r"), !s.contains("\\"),
              !s.hasPrefix("/"), !s.hasPrefix("~"), !s.hasSuffix("/") else { return "" }
        let partes = s.split(separator: "/", omittingEmptySubsequences: false)
        guard !partes.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return "" }
        return s
    }

    /// Pasta de worktrees efetiva: a declarada ou `<repo>-worktrees`.
    public var worktreesEfetivo: String {
        if !worktrees.trimmingCharacters(in: .whitespaces).isEmpty { return worktrees }
        return repo.hasSuffix("-worktrees") ? repo : repo + "-worktrees"
    }

    /// Freio efetivo: o declarado ou a lista padrão, mais o norte (que o declarado nunca tira).
    public var protegidosEfetivos: [String] {
        var base = protegidos.isEmpty ? Self.protegidosPadrao : protegidos
        if !norte.isEmpty, !base.contains(norte) { base.append(norte) }
        return base
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
        if let m = instalacao.problema() { return m }
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
            let repos = (item["repos"] as? [[String: Any]] ?? []).compactMap { r -> RepositorioCadastro? in
                guard let repo = JV.texto(r["repo"]), !repo.isEmpty else { return nil }
                return RepositorioCadastro(slug: JV.texto(r["slug"]) ?? "",
                                           repo: repo,
                                           github: JV.texto(r["github"]) ?? "",
                                           worktrees: JV.texto(r["worktrees"]) ?? "",
                                           prova: JV.texto(r["prova"]) ?? "",
                                           protegidos: (r["protegidos"] as? [String]) ?? [],
                                           pastasDoApp: (r["pastas_do_app"] as? [String]) ?? [])
            }
            let op = item["operacao"] as? [String: Any] ?? [:]
            var budget: [String: Double] = [:]
            if let bruto = op["budget_usd"] as? [String: Any] {
                for (k, v) in bruto {
                    if let n = JV.numero(v), n > 0 { budget[k] = n }
                }
            }
            func inteiro(_ chave: String) -> Int {
                max(0, JV.inteiro(op[chave]) ?? 0)
            }
            return ProjetoCadastro(projetoID: pid, nome: nome.isEmpty ? pid : nome,
                                   ativo: ativosBool, padrao: (item["padrao"] as? NSNumber)?.boolValue ?? false,
                                   repo: "\(item["repo"] ?? "")",
                                   worktrees: worktrees.isEmpty ? "" : worktrees,
                                   prova: prova.isEmpty ? "python3 {suite}" : prova,
                                   provaTentativas: tentativas, protegidos: prot,
                                   copiarParaWorktree: copiar,
                                   antesDoPush: "\(item["antes_do_push"] ?? "")",
                                   github: "\(item["github"] ?? "")",
                                   suites: ((item["suites"] as? [String]) ?? []).filter { !$0.isEmpty },
                                   bancada: (item["bancada"] as? [String: Any]).flatMap { $0["ativo"] as? NSNumber }
                                       .map { JV.ehBool($0) && $0.boolValue } ?? false,
                                   pastasDoApp: ((item["prova_remota"] as? [String: Any])?["pastas_do_app"] as? [String]) ?? [],
                                   norte: (item["norte"] as? String) ?? "",
                                   instalacao: InstalacaoCadastro.ler(item["entrega"] as? [String: Any]),
                                   prioridade: (item["prioridade"] as? NSNumber)?.intValue ?? 0,
                                   budgetUSD: budget,
                                   laneTimeoutMin: inteiro("lane_timeout_min"),
                                   proofTimeoutMin: inteiro("proof_timeout_min"),
                                   maxLanes: inteiro("max_lanes"),
                                   maxTarefasPorLane: inteiro("max_tarefas_por_lane"),
                                   planejamento: PlanejamentoCadastro.ler(item["planejamento"] as? [String: Any]),
                                   repos: repos)
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
            if !p.suites.isEmpty { item["suites"] = p.suites }
            if p.bancada { item["bancada"] = ["ativo": true] }
            if !p.pastasDoApp.isEmpty { item["prova_remota"] = ["pastas_do_app": p.pastasDoApp] }
            if !p.norte.isEmpty { item["norte"] = p.norte }
            if let e = p.instalacao.dict() { item["entrega"] = e }
            if p.prioridade > 0 { item["prioridade"] = p.prioridade }
            var op: [String: Any] = [:]
            if !p.budgetUSD.isEmpty { op["budget_usd"] = p.budgetUSD }
            if p.laneTimeoutMin > 0 { op["lane_timeout_min"] = p.laneTimeoutMin }
            if p.proofTimeoutMin > 0 { op["proof_timeout_min"] = p.proofTimeoutMin }
            if p.maxLanes > 0 { op["max_lanes"] = p.maxLanes }
            if p.maxTarefasPorLane > 0 { op["max_tarefas_por_lane"] = p.maxTarefasPorLane }
            if !op.isEmpty { item["operacao"] = op }
            if let pl = p.planejamento.dict() { item["planejamento"] = pl }
            if !p.repos.isEmpty {
                item["repos"] = p.repos.map { r in
                    var d: [String: Any] = ["slug": r.slug, "repo": r.repo]
                    if !r.github.isEmpty { d["github"] = r.github }
                    if !r.worktrees.isEmpty { d["worktrees"] = r.worktrees }
                    if !r.prova.isEmpty { d["prova"] = r.prova }
                    if !r.protegidos.isEmpty { d["protegidos"] = r.protegidos }
                    if !r.pastasDoApp.isEmpty { d["pastas_do_app"] = r.pastasDoApp }
                    return d
                }
            }
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