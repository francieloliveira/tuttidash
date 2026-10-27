import Foundation

/// Repositório do GitHub do projeto (FRA-567): a lista vem do `gh`, a pasta é achada pelo
/// `origin` e o dispatcher só envia a branch se o `origin` da pasta for este repositório.
public enum RepositorioGitHub {
    /// `dono/repo` a partir do link (https, ssh ou git@) ou do próprio `dono/repo`. nil = não dá
    /// para ler. Minúsculas: o GitHub não diferencia (mesma regra do `projetos.py`).
    public static func normalizar(_ valor: String) -> String? {
        var s = valor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for prefixo in ["https://github.com/", "http://github.com/", "ssh://git@github.com/",
                        "git@github.com:", "github.com/"] where s.lowercased().hasPrefix(prefixo) {
            s = String(s.dropFirst(prefixo.count))
            break
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.lowercased().hasSuffix(".git") { s = String(s.dropLast(4)) }
        let partes = s.split(separator: "/").map(String.init)
        guard partes.count == 2, !s.contains(where: \.isWhitespace) else { return nil }
        return "\(partes[0])/\(partes[1])".lowercased()
    }

    /// Link do repositório na web.
    public static func link(_ repo: String) -> URL? {
        normalizar(repo).flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// `url` do `[remote "origin"]` no `.git/config` da pasta, sem rodar o git. nil = não é um
    /// clone (ou é um worktree, que aponta para o clone principal).
    public static func origem(da pasta: URL, ler: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> String? {
        guard let texto = ler(pasta.appendingPathComponent(".git/config")) else { return nil }
        var dentro = false
        for linha in texto.split(whereSeparator: \.isNewline) {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { dentro = l.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"; continue }
            if dentro, l.hasPrefix("url") , let i = l.firstIndex(of: "=") {
                return l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pastas onde procurar um clone, nesta ordem.
    public static func raizesPadrao(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Developer", "Projects", "Projetos", "code", "src", "GitHub", "repos", ""].map {
            $0.isEmpty ? home : home.appendingPathComponent($0)
        }
    }

    /// Pasta que já tem o `repo` como `origin` (um nível abaixo de cada raiz). nil = não achou.
    public static func pastaLocal(para repo: String, raizes: [URL],
                                  listar: (URL) -> [URL] = { (try? FileManager.default.contentsOfDirectory(
                                      at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] },
                                  origem: (URL) -> String? = { RepositorioGitHub.origem(da: $0) }) -> URL? {
        guard let alvo = normalizar(repo) else { return nil }
        for raiz in raizes {
            for pasta in listar(raiz).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where origem(pasta).flatMap(normalizar) == alvo {
                return pasta
            }
        }
        return nil
    }

    /// Onde "Clonar aqui" põe o repositório: `~/Developer/<repo>`.
    public static func destinoDoClone(_ repo: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let r = normalizar(repo), let nome = r.split(separator: "/").last else { return nil }
        return home.appendingPathComponent("Developer").appendingPathComponent(String(nome))
    }

    /// Saída JSON do `gh repo list --json nameWithOwner,isPrivate` -> `dono/repo` em ordem.
    public static func lerLista(_ dados: Data) -> [String] {
        guard let lista = (try? JSONSerialization.jsonObject(with: dados)) as? [[String: Any]] else { return [] }
        return lista.compactMap { ($0["nameWithOwner"] as? String).flatMap(normalizar) }
    }

    /// `gh` instalado (mesmos caminhos que o dispatcher usa).
    public static func gh(existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: existe)
    }

    /// Repositórios da conta do `gh` e das organizações dela. Não chamar na thread da interface.
    public static func listar(rodar: ([String]) -> Data? = RepositorioGitHub.rodarGh) -> Result<[String], ErroGitHub> {
        guard let usuario = rodar(["repo", "list", "--limit", "1000", "--json", "nameWithOwner"]) else {
            return .failure(gh() == nil ? .semGh : .semLogin)
        }
        var todos = lerLista(usuario)
        let orgs = rodar(["org", "list"]).flatMap { String(data: $0, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        for org in orgs {
            if let d = rodar(["repo", "list", org, "--limit", "1000", "--json", "nameWithOwner"]) {
                todos += lerLista(d)
            }
        }
        var vistos = Set<String>()
        return .success(todos.filter { vistos.insert($0).inserted }.sorted())
    }

    /// Roda o `gh`; nil quando falta ou sai diferente de 0 (sem login, sem rede).
    public static func rodarGh(_ args: [String]) -> Data? {
        guard let exe = gh() else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GH_PROMPT_DISABLED"] = "1"
        let r = Subprocesso.rodar(exe, args, ambiente: env)
        return r.codigo == 0 ? r.saida : nil
    }

    /// `gh repo clone dono/repo <destino>`. Só no clique da pessoa. Não chamar na thread da interface.
    public static func clonar(_ repo: String, em destino: URL) -> Result<URL, ErroGitHub> {
        guard let r = normalizar(repo) else { return .failure(.repoInvalido) }
        if FileManager.default.fileExists(atPath: destino.path) { return .failure(.destinoExiste(destino.path)) }
        guard rodarGh(["repo", "clone", r, destino.path]) != nil,
              FileManager.default.fileExists(atPath: destino.appendingPathComponent(".git").path) else {
            return .failure(gh() == nil ? .semGh : .cloneFalhou)
        }
        return .success(destino)
    }
}

public enum ErroGitHub: Error, Equatable, LocalizedError {
    case semGh, semLogin, repoInvalido, cloneFalhou
    case destinoExiste(String)

    public var errorDescription: String? {
        switch self {
        case .semGh: return String(localized: "O GitHub CLI (gh) não está instalado. Instale com: brew install gh")
        case .semLogin: return String(localized: "O gh não respondeu. Entre com: gh auth login")
        case .repoInvalido: return String(localized: "Repositório do GitHub inválido (use dono/repo).")
        case .cloneFalhou: return String(localized: "O clone não terminou. Confira o acesso ao repositório no gh.")
        case .destinoExiste(let p): return String(localized: "Já existe uma pasta em \(p). Escolha a pasta à mão.")
        }
    }
}
