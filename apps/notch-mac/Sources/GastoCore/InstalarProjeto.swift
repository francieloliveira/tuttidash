import Foundation

/// FRA-698/FRA-699: leitura da instalação por projeto e chamada do CLI que age.
///
/// A tela **não executa nada por conta própria**: lê `~/.transcentia/instalacoes/<id>.json`
/// e, no clique, chama `tools/instalar.py <ação> --projeto <id> [--ref <versão>] --json`.
/// Nenhum nome de projeto, linguagem ou ferramenta mora aqui: a classe vem do cadastro.
public enum InstalarProjeto {
    /// Retrato do que o Python gravou, conferido com o que existe no disco.
    public struct Estado: Equatable, Sendable {
        public var classe: String
        public var situacao: String
        public var versao: String
        public var pid: Int?
        public var porta: Int?
        public var url: String
        public var artefato: String
        public var destino: String
        public var inicio: String
        public var em: String
        public var erro: String
        public var log: String
        public var bloqueio: String
        /// Versão de onde veio a instalação (`--ref`) e o commit que estava nela.
        public var ref: String
        public var head: String
        public var acoes: [String]
        /// `true` quando não há arquivo de estado: a tela diz «sem leitura», não inventa.
        public var semLeitura: Bool

        public init(classe: String = "nenhuma", situacao: String = "sem leitura", versao: String = "",
                    pid: Int? = nil, porta: Int? = nil, url: String = "", artefato: String = "",
                    destino: String = "", inicio: String = "", em: String = "", erro: String = "",
                    log: String = "", bloqueio: String = "", ref: String = "", head: String = "",
                    acoes: [String] = [], semLeitura: Bool = true) {
            self.classe = classe
            self.situacao = situacao
            self.versao = versao
            self.pid = pid
            self.porta = porta
            self.url = url
            self.artefato = artefato
            self.destino = destino
            self.inicio = inicio
            self.em = em
            self.erro = erro
            self.log = log
            self.bloqueio = bloqueio
            self.ref = ref
            self.head = head
            self.acoes = acoes
            self.semLeitura = semLeitura
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var projeto: ProjetoCadastro
        public var estado: Estado
        public var id: String { projeto.projetoID }

        public init(projeto: ProjetoCadastro, estado: Estado) {
            self.projeto = projeto
            self.estado = estado
        }
    }

    /// Versões oferecidas para instalar. `main` está sempre na lista: é o caminho
    /// normal, mesmo quando o `git fetch` falha ou o repositório não tem `origin`.
    public struct Versoes: Equatable, Sendable {
        public var branches: [String]
        public var tags: [String]
        public var erro: String

        public init(branches: [String] = ["main"], tags: [String] = [], erro: String = "") {
            var b = branches
            if !b.contains("main") { b.insert("main", at: 0) }
            self.branches = b
            self.tags = tags
            self.erro = erro
        }
    }

    public static func pastaEstado(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".transcentia").appendingPathComponent("instalacoes")
    }

    public static func arquivoEstado(_ projetoID: String, home: URL) -> URL {
        pastaEstado(home: home).appendingPathComponent(projetoID + ".json")
    }

    /// Todos os projetos do cadastro, com o estado de instalação de cada um.
    public static func itens(_ projetos: [ProjetoCadastro],
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Item] {
        projetos.map { Item(projeto: $0, estado: estado($0, home: home)) }
    }

    public static func estado(_ p: ProjetoCadastro,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Estado {
        var e = Estado(classe: p.instalacao.classe.rawValue)
        if p.instalacao.classe == .nenhuma {
            e.situacao = "nenhuma"
            e.versao = versaoGit(repo: p.repo, home: home)
            e.acoes = []
            e.semLeitura = false
            return e
        }
        let bruto = lerJSON(arquivoEstado(p.projetoID, home: home))
        if let bruto {
            e.semLeitura = false
            e.situacao = texto(bruto["situacao"], padrao: e.situacao)
            e.versao = texto(bruto["versao"])
            e.pid = numero(bruto["pid"])
            e.porta = numero(bruto["porta"]) ?? (Int(p.instalacao.porta) ?? nil)
            e.url = texto(bruto["url"])
            e.artefato = texto(bruto["artefato"])
            e.destino = texto(bruto["destino"])
            e.inicio = texto(bruto["inicio"])
            e.em = texto(bruto["em"])
            e.erro = texto(bruto["erro"])
            e.log = texto(bruto["log"])
            e.ref = texto(bruto["ref"])
            e.head = texto(bruto["head"])
        } else {
            // Sem arquivo: a situação mais honesta por classe, sem inventar instalação.
            switch p.instalacao.classe {
            case .servico: e.situacao = "parado"
            case .artefato: e.situacao = "não instalado"
            case .nenhuma: e.situacao = "nenhuma"
            }
        }
        e.classe = p.instalacao.classe.rawValue
        if e.porta == nil, let n = Int(p.instalacao.porta), n > 0 { e.porta = n }
        if e.url.isEmpty { e.url = p.instalacao.url.replacingOccurrences(of: "{porta}", with: e.porta.map(String.init) ?? "") }
        e.bloqueio = bloqueio(projetoID: p.projetoID, home: home)
        e.acoes = acoes(p.instalacao)
        return e
    }

    public static func acoes(_ e: InstalacaoCadastro) -> [String] {
        switch e.classe {
        case .nenhuma:
            return []
        case .servico:
            return (e.subir.isEmpty ? [] : ["subir"]) + ["parar"]
        case .artefato:
            return (e.empacotar.isEmpty ? [] : ["empacotar"])
                + (e.validar.isEmpty ? [] : ["validar"])
                + (e.instalar.isEmpty ? [] : ["instalar"])
        }
    }

    /// Trava: lane com card no projeto. Arquivo antigo sem `projeto` conta para o padrão.
    public static func bloqueio(projetoID: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let pasta = home.appendingPathComponent(".transcentia").appendingPathComponent("lanes")
        guard let arquivos = try? FileManager.default.contentsOfDirectory(atPath: pasta.path) else { return "" }
        var rodando: [String] = []
        for nome in arquivos.sorted() where nome.hasPrefix("lane-") && nome.hasSuffix(".json") {
            guard let d = lerJSON(pasta.appendingPathComponent(nome)) else { continue }
            let dono = texto(d["projeto"])
            let lane = texto(d["lane"])
            let rotulo = lane.isEmpty ? nome.replacingOccurrences(of: "lane-", with: "")
                .replacingOccurrences(of: ".json", with: "") : lane
            if !dono.isEmpty {
                if dono == projetoID { rodando.append(rotulo) }
            } else if projetoID == projetoPadraoID(home: home) {
                rodando.append(rotulo)
            }
        }
        return rodando.isEmpty ? "" : "lane rodando no projeto: " + rodando.joined(separator: ", ")
    }

    /// Projeto padrão do cadastro (o que o dispatcher trabalha quando a lane não diz o dono).
    static func projetoPadraoID(home: URL) -> String {
        let dados = Configuracao.lerArquivo(home: home)
        return ProjetosConfig.padrao(ProjetosConfig.ler(dados))?.projetoID ?? ""
    }

    /// Versão do git para a classe `nenhuma`: HEAD local em short SHA.
    public static func versaoGit(repo: String, home: URL,
                                 git: (String, [String]) -> Subprocesso.Resultado = { Subprocesso.rodar($0, $1) })
        -> String {
        let limpo = repo.trimmingCharacters(in: .whitespaces)
        guard !limpo.isEmpty else { return "" }
        let caminho = limpo.hasPrefix("~/")
            ? home.appendingPathComponent(String(limpo.dropFirst(2))).path : limpo
        guard FileManager.default.fileExists(atPath: caminho + "/.git") else { return "" }
        let r = git("/usr/bin/git", ["-C", caminho, "rev-parse", "--short", "HEAD"])
        return r.codigo == 0 ? r.texto.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Comando que age no projeto. nil quando o CLI não está no bundle (app não reinstalado).
    public static func comando(_ acao: String, projetoID: String, ref: String = "",
                               bundle: Bundle = .main) -> [String]? {
        guard !acao.isEmpty, !acao.hasPrefix("-"),
              !projetoID.isEmpty, !projetoID.hasPrefix("-") else { return nil }
        let versao = ref.trimmingCharacters(in: .whitespaces)
        if !versao.isEmpty {
            guard !versao.hasPrefix("-"), !versao.contains("\n"), !versao.contains("\r"),
                  !versao.contains(";"), !versao.contains("$") else { return nil }
        }
        let script = ScriptsDoBundle.url("tools/instalar.py", bundle: bundle)
            ?? ScriptsDoBundle.aplicacoes("tools/instalar.py")
        guard let script, FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        var cmd = ["/usr/bin/python3", script.path, acao, "--projeto", projetoID, "--json"]
        if !versao.isEmpty { cmd += ["--ref", versao] }
        return cmd
    }

    /// Branches e tags do projeto (com `git fetch`). A tela mostra `main` sempre.
    public static func versoes(_ p: ProjetoCadastro,
                               executar: (String, [String], [String: String]?) -> Subprocesso.Resultado
                                   = { Subprocesso.rodar($0, $1, ambiente: $2) }) -> Versoes {
        guard let cmd = comando("refs", projetoID: p.projetoID) else { return Versoes() }
        let r = executar(cmd[0], Array(cmd.dropFirst()), ambiente)
        guard let d = try? JSONSerialization.jsonObject(with: Data(r.texto.utf8)) as? [String: Any] else {
            return Versoes(erro: "não consegui ler a lista de versões (código \(r.codigo))")
        }
        let branches = (d["branches"] as? [String]) ?? []
        let tags = (d["tags"] as? [String]) ?? []
        return Versoes(branches: branches, tags: tags, erro: texto(d["erro"]))
    }

    /// Últimas linhas do log da execução, para o painel expansível.
    public static func ultimasLinhas(_ caminho: String, limite: Int = 40) -> String {
        guard !caminho.isEmpty,
              let texto = try? String(contentsOfFile: caminho, encoding: .utf8) else { return "" }
        return texto.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(limite).joined(separator: "\n")
    }

    public static let ambiente: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }()

    // MARK: - JSON tolerante

    static func lerJSON(_ url: URL) -> [String: Any]? {
        guard let dados = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return nil }
        return o
    }

    static func texto(_ v: Any?, padrao: String = "") -> String {
        guard let v else { return padrao }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return JV.ehBool(n) ? (n.boolValue ? "true" : "false") : "\(n)" }
        return "\(v)"
    }

    static func numero(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
