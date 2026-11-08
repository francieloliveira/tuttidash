import Foundation

/// Rascunho do norte de um projeto (`docs/produto/caminho.md`) para o wizard.
///
/// A leitura do repositório é feita aqui, sempre igual, e vai como texto no prompt:
/// o agente do Brainstorm e o Ollama recebem a mesma entrada, sem ferramenta nenhuma.
/// O rascunho não é o norte: o dono revisa e só o merge do PR o torna válido.
public enum NorteRascunho {
    /// Caminho do norte em todo projeto (mesmo nome do TranscentIA).
    public static let caminhoPadrao = "docs/produto/caminho.md"

    /// Marca de seção que o agente não conseguiu deduzir do material.
    public static let aDefinir = "(a definir pelo dono)"

    /// Seções do norte, na ordem do arquivo.
    public static let secoes = [
        "Objetivo",
        "Restrições inegociáveis",
        "Desempate",
        "O que nunca se faz",
        "Glossário",
    ]

    // MARK: - Leitura do repositório

    /// Teto da leitura inteira, em caracteres (≈4k tokens).
    public static let tetoPadrao = 16_000

    /// Pastas que não dizem nada sobre o projeto (gerado, dependência, cache).
    static let ignoradas: Set<String> = [
        ".git", "node_modules", "build", ".build", "DerivedData", "Pods", "dist",
        "venv", ".venv", "__pycache__", ".swiftpm", ".gradle", "target", ".idea", ".vscode",
    ]

    /// Manifestos de pacote/projeto procurados na raiz, nesta ordem.
    static let manifestos = [
        "Package.swift", "package.json", "pyproject.toml", "setup.py", "requirements.txt",
        "Cargo.toml", "go.mod", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "pom.xml", "Gemfile", "composer.json",
    ]

    /// Texto que vai no prompt. Determinístico: mesma árvore, mesmo texto.
    /// Não segue link simbólico (não sai do repositório) e corta cada parte no seu teto.
    public static func lerRepositorio(_ repo: URL, teto: Int = tetoPadrao) -> String {
        var partes: [String] = []
        partes.append(bloco("Árvore (2 níveis)", arvore(repo), teto: 3_000))
        if let readme = primeiroArquivo(repo, ["README.md", "README", "README.txt", "readme.md"]) {
            partes.append(bloco(readme.lastPathComponent, ler(readme), teto: 5_000))
        }
        for nome in ["AGENTS.md", "CLAUDE.md"] {
            if let arq = primeiroArquivo(repo, [nome]) {
                partes.append(bloco(nome, ler(arq), teto: 2_000))
            }
        }
        var orcamentoManifesto = 3_000
        for relativo in caminhosDeManifesto(repo).prefix(4) {
            guard orcamentoManifesto > 200 else { break }
            let parte = bloco(relativo, ler(repo.appendingPathComponent(relativo)),
                              teto: min(1_500, orcamentoManifesto))
            orcamentoManifesto -= parte.count
            partes.append(parte)
        }
        let projetosXcode = listar(repo).filter { $0.hasSuffix(".xcodeproj") }
        if !projetosXcode.isEmpty {
            partes.append(bloco("Projetos Xcode", projetosXcode.joined(separator: "\n"), teto: 500))
        }
        let testes = pastasDeTeste(repo)
        if !testes.isEmpty {
            partes.append(bloco("Testes", testes, teto: 1_500))
        }
        return cortar(partes.joined(separator: "\n\n"), teto: teto)
    }

    static func bloco(_ titulo: String, _ corpo: String, teto: Int) -> String {
        "### \(titulo)\n" + cortar(corpo.trimmingCharacters(in: .whitespacesAndNewlines), teto: teto)
    }

    static func cortar(_ texto: String, teto: Int) -> String {
        guard texto.count > teto else { return texto }
        return String(texto.prefix(max(0, teto - 12))) + "\n[…cortado]"
    }

    static func ehLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func ehPasta(_ url: URL) -> Bool {
        guard !ehLink(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Nomes visíveis de uma pasta, em ordem. Ocultos ficam fora, menos `.github`.
    static func listar(_ pasta: URL) -> [String] {
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? []
        return nomes
            .filter { !$0.hasPrefix(".") || $0 == ".github" }
            .filter { !ignoradas.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func arvore(_ repo: URL) -> String {
        var linhas: [String] = []
        for nome in listar(repo).prefix(40) {
            let url = repo.appendingPathComponent(nome)
            guard !ehLink(url) else { continue }
            guard ehPasta(url) else { linhas.append(nome); continue }
            linhas.append(nome + "/")
            let filhos = listar(url).filter { !ehLink(url.appendingPathComponent($0)) }
            for filho in filhos.prefix(20) {
                linhas.append("  " + filho + (ehPasta(url.appendingPathComponent(filho)) ? "/" : ""))
            }
            if filhos.count > 20 { linhas.append("  … +\(filhos.count - 20)") }
        }
        return linhas.joined(separator: "\n")
    }

    static func primeiroArquivo(_ repo: URL, _ nomes: [String]) -> URL? {
        for nome in nomes {
            let url = repo.appendingPathComponent(nome)
            if !ehLink(url), !ehPasta(url), FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func ler(_ url: URL) -> String {
        guard let dados = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return String(decoding: dados.prefix(64_000), as: UTF8.self)
    }

    /// Manifestos na raiz e até 2 níveis abaixo (ex.: `apps/notch-mac/Package.swift`).
    /// Raiz primeiro; depois as pastas em ordem alfabética.
    static func caminhosDeManifesto(_ repo: URL) -> [String] {
        var achados: [String] = []
        func olhar(_ pasta: URL, _ relativo: String, _ nivel: Int) {
            for nome in manifestos where primeiroArquivo(pasta, [nome]) != nil {
                achados.append(relativo.isEmpty ? nome : relativo + "/" + nome)
            }
            guard nivel < 2 else { return }
            for nome in listar(pasta) where !nome.hasPrefix(".") && !ehPastaDeTeste(nome) {
                let url = pasta.appendingPathComponent(nome)
                guard ehPasta(url) else { continue }
                olhar(url, relativo.isEmpty ? nome : relativo + "/" + nome, nivel + 1)
            }
        }
        olhar(repo, "", 0)
        return achados
    }

    static func ehPastaDeTeste(_ nome: String) -> Bool {
        let n = nome.lowercased()
        return ["test", "tests", "__tests__", "spec", "specs"].contains(n) || nome.hasSuffix("Tests")
    }

    /// Pastas de teste até 3 níveis e os arquivos de cada uma (até 15).
    static func pastasDeTeste(_ repo: URL) -> String {
        var saida: [String] = []
        /// Pasta de teste: lista os arquivos dela e desce nas subpastas (ex.: `Tests/AppTests/`).
        func arquivosDeTeste(_ pasta: URL, _ caminho: String, _ nivel: Int) {
            let nomes = listar(pasta)
            let arquivos = nomes.filter { !ehPasta(pasta.appendingPathComponent($0)) && !ehLink(pasta.appendingPathComponent($0)) }
            if !arquivos.isEmpty {
                let mostra = arquivos.prefix(15).joined(separator: ", ")
                let resto = arquivos.count > 15 ? ", … +\(arquivos.count - 15)" : ""
                saida.append("\(caminho)/: \(mostra)\(resto)")
            }
            guard nivel < 4 else { return }
            for nome in nomes where ehPasta(pasta.appendingPathComponent(nome)) {
                arquivosDeTeste(pasta.appendingPathComponent(nome), caminho + "/" + nome, nivel + 1)
            }
        }
        func varrer(_ pasta: URL, _ relativo: String, _ nivel: Int) {
            guard nivel <= 3 else { return }
            for nome in listar(pasta) {
                let url = pasta.appendingPathComponent(nome)
                guard ehPasta(url) else { continue }
                let caminho = relativo.isEmpty ? nome : relativo + "/" + nome
                if ehPastaDeTeste(nome) {
                    arquivosDeTeste(url, caminho, nivel)
                } else {
                    varrer(url, caminho, nivel + 1)
                }
            }
        }
        varrer(repo, "", 1)
        return saida.joined(separator: "\n")
    }

    // MARK: - Prompt

    /// Instrução de sistema do papel `.norte`.
    public static let sistema = """
    Você rascunha o norte de um projeto de software. Não edite arquivos e não rode comandos.
    Use só o material desta mensagem. Não percorra o repositório.
    O norte diz o que o projeto é e o que não pode acontecer. Não é lista de tarefas nem de arquivos.
    Não invente. Objetivo, restrição ou desempate que o material não mostra fica como \
    "\(aDefinir)" e vira uma pergunta ao dono.
    Português. Devolva só os blocos NORTE: e PERGUNTAS:, sem texto antes ou depois.
    """

    public static func prompt(nome: String, leitura: String, respostas: String) -> String {
        let r = respostas.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Projeto: \(nome.trimmingCharacters(in: .whitespacesAndNewlines))

        Material do repositório:
        \(leitura)

        Respostas do dono:
        \(r.isEmpty ? "(nenhuma ainda)" : r)

        As respostas do dono valem mais que o material. Devolva exatamente neste formato:

        NORTE:
        ## 1. Objetivo
        1 a 3 frases: para quem é e que resultado entrega.
        ## 2. Restrições inegociáveis
        - R1: regra que nenhuma tarefa pode violar
        ## 3. Desempate
        1. o que vence quando duas metas brigam
        ## 4. O que nunca se faz
        - ação proibida
        ## 5. Glossário
        - termo: significado
        PERGUNTAS:
        - pergunta curta ao dono sobre cada "\(aDefinir)" (no máximo 5)
        """
    }

    // MARK: - Resposta

    public struct Rascunho: Equatable, Sendable {
        /// Corpo de cada seção, na ordem de `NorteRascunho.secoes`.
        public var corpos: [String]
        public var perguntas: [String]

        /// Seções que o agente deixou para o dono.
        public var pendentes: [String] {
            zip(NorteRascunho.secoes, corpos).filter { $0.1.contains(NorteRascunho.aDefinir) }.map(\.0)
        }

        /// Conteúdo do `caminho.md`.
        public func markdown(nome: String) -> String {
            var linhas = [
                "# Norte — \(nome.trimmingCharacters(in: .whitespacesAndNewlines))",
                "",
                "> Norte do projeto: o que ele é e o que não pode acontecer. Só o dono altera este arquivo.",
                "> Agentes: leiam antes de planejar. Para mudar algo aqui, proponham ao dono (needs_dono); não editem.",
            ]
            for (i, titulo) in NorteRascunho.secoes.enumerated() {
                linhas += ["", "## §\(i + 1) \(titulo)", "", corpos[i]]
            }
            return linhas.joined(separator: "\n") + "\n"
        }
    }

    /// Índice da seção pelo título do cabeçalho: número 1–5 no começo, ou palavra-chave.
    static func secao(doCabecalho linha: String) -> Int? {
        var t = linha.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("§") { t.removeFirst() }
        if let d = t.first, let n = d.wholeNumberValue, (1...5).contains(n) { return n - 1 }
        let baixo = semAcento(t)
        let chaves = ["objetivo", "restric", "desempate", "nunca", "glossario"]
        return chaves.firstIndex { baixo.contains($0) }
    }

    static func semAcento(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    /// Lê a resposta do agente. `nil` quando nenhuma seção foi reconhecida.
    /// Sem o marcador `NORTE:`, ainda aceita os cabeçalhos soltos (modelo menor costuma esquecer).
    public static func ler(_ bruto: String) -> Rascunho? {
        var texto = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        texto = texto.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        var corpos = Array(repeating: [String](), count: secoes.count)
        var perguntas: [String] = []
        var vistas = Set<String>()
        var atual: Int?
        var emPerguntas = false
        var achou = false
        for linha in texto.components(separatedBy: "\n") {
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            // `**PERGUNTAS:**`, `## Perguntas` e `PERGUNTAS` valem como o marcador.
            let marca = semAcento(limpa)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*_ :"))
                .uppercased()
            if marca == "NORTE" { emPerguntas = false; atual = nil; continue }
            if marca == "PERGUNTAS" || marca.hasPrefix("PERGUNTAS AO DONO") { emPerguntas = true; atual = nil; continue }
            if emPerguntas {
                guard limpa.hasPrefix("- ") || limpa.hasPrefix("• ") else { continue }
                let p = String(limpa.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty, perguntas.count < 5, vistas.insert(p).inserted { perguntas.append(p) }
                continue
            }
            if limpa.hasPrefix("#") {
                atual = secao(doCabecalho: limpa)
                if atual != nil { achou = true }
                continue
            }
            if let i = atual { corpos[i].append(linha) }
        }
        guard achou else { return nil }
        let finais = corpos.map { linhas -> String in
            let t = linhas.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? aDefinir : t
        }
        return Rascunho(corpos: finais, perguntas: perguntas)
    }
}
