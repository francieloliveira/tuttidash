import Foundation

/// Norte de um projeto do cadastro, para o wizard em Ajustes › Projetos.
///
/// - **importar**: a `origin/main` do projeto já tem `docs/produto/caminho.md`. Nada é escrito
///   no repositório; o cadastro só passa a apontar para ele (e o norte entra no freio).
/// - **criar**: não tem. O wizard rascunha, o dono revisa e o `tools/instalar-norte` abre o PR.
public enum NorteProjeto {
    public enum Estado: Equatable, Sendable {
        /// O cadastro aponta para o norte e ele está na `origin/main`.
        case ativo
        /// Está na `origin/main`, mas o cadastro ainda não aponta para ele.
        case importavel
        /// O cadastro aponta, mas a `origin/main` ainda não tem (PR do norte aberto ou não mergeado).
        case aguardandoMerge
        case falta
        case semPasta
        case desconhecido(String)

        public var rotulo: String {
            switch self {
            case .ativo: return String(localized: "ativo: nenhuma lane edita o norte")
            case .importavel: return String(localized: "o repositório já tem norte; falta apontar o cadastro para ele")
            case .aguardandoMerge: return String(localized: "aguardando o merge do PR do norte (fechou o PR? use Refazer)")
            case .falta: return String(localized: "sem norte: os cards não têm a que se ancorar")
            case .semPasta: return String(localized: "escolha a pasta do projeto")
            case .desconhecido(let m): return String(localized: "não deu para conferir (\(m))")
            }
        }

        public var ok: Bool { self == .ativo }
    }

    /// Confere o arquivo na `origin/main` da pasta (sem rede: vale o último fetch).
    /// `buscar`: faz `git fetch origin main` antes de olhar. Sem isso, um PR do norte mergeado
    /// no GitHub continua «aguardando o merge» até alguém buscar (08/11, PR #97).
    public static func estado(_ projeto: ProjetoCadastro,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              buscar: Bool = false,
                              git: (String, [String]) -> Subprocesso.Resultado = { Subprocesso.rodar($0, $1) })
        -> Estado {
        let limpo = projeto.repo.trimmingCharacters(in: .whitespaces)
        guard !limpo.isEmpty else { return .semPasta }
        let pasta = limpo.hasPrefix("~/") ? home.appendingPathComponent(String(limpo.dropFirst(2))).path : limpo
        guard FileManager.default.fileExists(atPath: pasta + "/.git") else {
            return .desconhecido(String(localized: "a pasta não é um repositório git"))
        }
        if buscar {
            // Falha de rede não muda nada: vale o último fetch.
            _ = git("/usr/bin/git", ["-C", pasta, "-c", "credential.interactive=never", "fetch", "-q", "origin", "main"])
        }
        let caminho = projeto.norte.isEmpty ? NorteRascunho.caminhoPadrao : projeto.norte
        let naMain = git("/usr/bin/git", ["-C", pasta, "cat-file", "-e", "origin/main:\(caminho)"]).codigo == 0
        switch (projeto.norte.isEmpty, naMain) {
        case (false, true): return .ativo
        case (true, true): return .importavel
        case (false, false): return .aguardandoMerge
        case (true, false): return .falta
        }
    }

    /// Aviso para o Brainstorm quando os cards vão sair sem o norte. nil = norte ativo.
    /// Não trava nada: o dono continua trabalhando e sabe por quê o card não cita o norte.
    public static func avisoBrainstorm(_ e: Estado) -> String? {
        switch e {
        case .ativo: return nil
        case .aguardandoMerge:
            return String(localized: "O norte ainda não está na main (PR aguardando merge). Os cards saem sem ele até o merge.")
        case .importavel:
            return String(localized: "O repositório tem norte, mas o cadastro não aponta para ele: Ajustes › Projetos › Usar este norte.")
        case .falta:
            return String(localized: "Projeto sem norte: os cards saem sem ele. Crie em Ajustes › Projetos.")
        case .semPasta, .desconhecido:
            return nil
        }
    }

    /// Respostas do dono no formato que o prompt do rascunho recebe. Pergunta sem resposta fica de fora.
    public static func respostas(perguntas: [String], respostas: [String]) -> String {
        zip(perguntas, respostas).compactMap { p, r in
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "- \(p)\n  \(t)"
        }.joined(separator: "\n")
    }

    /// Texto do norte pronto para o PR. Objetivo, restrições, desempate e o que nunca se faz
    /// não podem ficar "a definir"; o glossário (§5) pode.
    public static func problema(_ markdown: String) -> String? {
        let t = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return String(localized: "O norte está vazio.") }
        let essencial = t.range(of: "## §5").map { String(t[..<$0.lowerBound]) } ?? t
        if essencial.contains(NorteRascunho.aDefinir) {
            return String(localized: "Ainda há seções \(NorteRascunho.aDefinir). Responda às perguntas e refaça, ou escreva à mão.")
        }
        return nil
    }

    /// Seções §1–§4 que ainda têm a marca de pendência, como «§3 Desempate».
    public static func secoesPendentes(_ markdown: String) -> [String] {
        var pendentes: [String] = []
        var atual: String?
        for linha in markdown.components(separatedBy: "\n") {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## §") {
                let titulo = String(l.dropFirst(3))
                atual = titulo.hasPrefix("§5") ? nil : titulo
                continue
            }
            if let a = atual, l.contains(NorteRascunho.aDefinir), !pendentes.contains(a) { pendentes.append(a) }
        }
        return pendentes
    }

    /// Comando que grava o norte no projeto e abre o PR. O instalador fica no bundle assinado.
    public static func comandoInstalar(projetoID: String, arquivoNorte: URL, bundle: Bundle = .main) -> [String]? {
        guard let script = ScriptsDoBundle.url("tools/instalar-norte", bundle: bundle),
              !projetoID.isEmpty, !projetoID.hasPrefix("-") else { return nil }
        return ["/usr/bin/python3", script.path, projetoID, "--norte", arquivoNorte.path, "--pr"]
    }

    /// Esqueleto para escrever sem agente: as seções, todas a definir.
    public static var esqueleto: NorteRascunho.Rascunho {
        NorteRascunho.Rascunho(corpos: Array(repeating: NorteRascunho.aDefinir, count: NorteRascunho.secoes.count),
                               perguntas: [])
    }
}
