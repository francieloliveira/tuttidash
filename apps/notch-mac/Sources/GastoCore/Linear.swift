import Foundation

/// Cliente da API GraphQL do Linear (FRA-297). Protocolo para trocar por um falso nos testes.
public protocol ClienteLinear: Sendable {
    /// Devolve o objeto `data` da resposta GraphQL.
    func consultar(_ query: String, token: String) async throws -> [String: Any]
}

public enum ErroLinear: Error, Equatable, LocalizedError {
    case semToken
    case tokenInvalido
    case rede(String)
    case resposta(String)

    public var errorDescription: String? {
        switch self {
        case .semToken: return String(localized: "Cole o token da API do Linear.")
        case .tokenInvalido: return String(localized: "Token do Linear inválido ou sem permissão. Gere um novo em Linear › Settings › API.")
        case .rede(let m): return String(localized: "Não foi possível falar com o Linear: \(m)")
        case .resposta(let m): return String(localized: "Resposta inesperada do Linear: \(m)")
        }
    }
}

public struct HTTPClienteLinear: ClienteLinear {
    public var endpoint = URL(string: "https://api.linear.app/graphql")!
    public init() {}

    public func consultar(_ query: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let dados: Data, resp: URLResponse
        do { (dados, resp) = try await URLSession.shared.data(for: req) } catch {
            throw ErroLinear.rede(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any]
        return try ServicoLinear.interpretar(status: status, corpo: obj)
    }
}

public struct ItemLinear: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var nome: String
    public init(id: String, nome: String) { self.id = id; self.nome = nome }
}

public struct OpcoesTime: Equatable, Sendable {
    public var projetos: [ItemLinear] = []
    public var estados: [ItemLinear] = []
    public var rotulos: [ItemLinear] = []
    public init(projetos: [ItemLinear] = [], estados: [ItemLinear] = [], rotulos: [ItemLinear] = []) {
        self.projetos = projetos; self.estados = estados; self.rotulos = rotulos
    }
}

/// Projeto do Linear com o time dele (FRA-567): o cadastro escolhe por aqui, sem UUID digitado.
public struct ProjetoLinear: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var nome: String
    public var url: String
    public var timeID: String
    public var timeNome: String
    public init(id: String, nome: String, url: String = "", timeID: String = "", timeNome: String = "") {
        self.id = id; self.nome = nome; self.url = url; self.timeID = timeID; self.timeNome = timeNome
    }
    /// "Nome · Time", para a lista.
    public var rotulo: String { timeNome.isEmpty ? nome : "\(nome) · \(timeNome)" }
}

/// Só leitura: nenhuma mutação é enviada ao Linear.
public struct ServicoLinear: Sendable {
    public let cliente: ClienteLinear
    public init(cliente: ClienteLinear = HTTPClienteLinear()) { self.cliente = cliente }

    static func interpretar(status: Int, corpo: [String: Any]?) throws -> [String: Any] {
        let erros = corpo?["errors"] as? [[String: Any]] ?? []
        let autenticacao = erros.contains {
            let ext = $0["extensions"] as? [String: Any]
            return (ext?["code"] as? String) == "AUTHENTICATION_ERROR" || (ext?["type"] as? String) == "authentication error"
        }
        if status == 401 || status == 403 || autenticacao { throw ErroLinear.tokenInvalido }
        if let m = erros.first?["message"] as? String { throw ErroLinear.resposta(m) }
        guard (200..<300).contains(status), let d = corpo?["data"] as? [String: Any] else {
            throw ErroLinear.resposta("HTTP \(status)")
        }
        return d
    }

    private func token(_ t: String) throws -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw ErroLinear.semToken }
        return s
    }

    private static func itens(_ d: [String: Any]?, _ chave: String, nome: String = "name") -> [ItemLinear] {
        let nodes = (d?[chave] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            guard let id = n["id"] as? String, let nm = n[nome] as? String else { return nil }
            return ItemLinear(id: id, nome: nm)
        }.sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }

    /// URL do workspace (https://linear.app/<urlKey>) e times.
    public func conectar(token t: String) async throws -> (workspace: String, times: [ItemLinear]) {
        let d = try await cliente.consultar("{ organization { urlKey } teams(first: 100) { nodes { id name } } }", token: try token(t))
        guard let chave = (d["organization"] as? [String: Any])?["urlKey"] as? String, !chave.isEmpty else {
            throw ErroLinear.resposta("organization.urlKey")
        }
        return ("https://linear.app/\(chave)", Self.itens(d, "teams"))
    }

    /// Todos os projetos do workspace, com o time de cada um (FRA-567).
    public func projetos(token t: String) async throws -> [ProjetoLinear] {
        let d = try await cliente.consultar(
            "{ projects(first: 250) { nodes { id name url teams(first: 1) { nodes { id name } } } } }", token: try token(t))
        return Self.projetos(d)
    }

    static func projetos(_ d: [String: Any]) -> [ProjetoLinear] {
        let nodes = (d["projects"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            guard let id = n["id"] as? String, let nome = n["name"] as? String else { return nil }
            let time = ((n["teams"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
            return ProjetoLinear(id: id, nome: nome, url: n["url"] as? String ?? "",
                                 timeID: time?["id"] as? String ?? "", timeNome: time?["name"] as? String ?? "")
        }.sorted { $0.rotulo.localizedCaseInsensitiveCompare($1.rotulo) == .orderedAscending }
    }

    public func opcoes(time: String, token t: String) async throws -> OpcoesTime {
        let id = time.replacingOccurrences(of: "\"", with: "")
        let q = """
        { team(id: "\(id)") { projects(first: 100) { nodes { id name } } states(first: 100) { nodes { id name } } \
        labels(first: 250) { nodes { id name } } } }
        """
        let d = try await cliente.consultar(q, token: try token(t))
        guard let team = d["team"] as? [String: Any] else { throw ErroLinear.resposta("team") }
        return OpcoesTime(projetos: Self.itens(team, "projects"), estados: Self.itens(team, "states"),
                          rotulos: Self.itens(team, "labels"))
    }
}

/// Item do Keychain que o dispatcher e o vigia leem (`linear.keychain_service`), gravado e lido
/// pelo `/usr/bin/security` (FRA-568). Assim o item fica confiável para o `security` dos scripts
/// e não abre aviso de permissão quando eles leem; o token nunca vai na linha de comando.
public protocol ChaveiroScripts: Sendable {
    func ler(servico: String) -> String?
    func gravar(_ segredo: String, servico: String, conta: String) throws
    func apagar(servico: String)
}

public struct ChaveiroSecurity: ChaveiroScripts {
    public init() {}

    @discardableResult
    private func rodar(_ args: [String], entrada: String? = nil) -> (codigo: Int32, saida: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let saida = Pipe(), erro = Pipe(), dentro = Pipe()
        p.standardOutput = saida; p.standardError = erro
        if entrada != nil { p.standardInput = dentro }
        do { try p.run() } catch { return (-1, "") }
        if let entrada {
            dentro.fileHandleForWriting.write(Data(entrada.utf8))
            try? dentro.fileHandleForWriting.close()
        }
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: dados, encoding: .utf8) ?? "")
    }

    public func ler(servico: String) -> String? {
        let r = rodar(["find-generic-password", "-s", servico, "-w"])
        let v = r.saida.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.codigo == 0 && !v.isEmpty ? v : nil
    }

    public func gravar(_ segredo: String, servico: String, conta: String) throws {
        // `security -i` lê o comando da entrada: o segredo não aparece no `ps`.
        guard !segredo.isEmpty, !(segredo + servico + conta).contains(where: { "\"\\\n\r".contains($0) }) else {
            throw ErroLinear.resposta(String(localized: "token com caractere inválido"))
        }
        apagar(servico: servico)
        let r = rodar(["-i"], entrada: "add-generic-password -U -a \"\(conta)\" -s \"\(servico)\" -w \"\(segredo)\"\n")
        guard r.codigo == 0, ler(servico: servico) == segredo else {
            throw ErroLinear.resposta(String(localized: "não foi possível gravar no Keychain"))
        }
    }

    public func apagar(servico: String) {
        for _ in 0..<5 where rodar(["delete-generic-password", "-s", servico]).codigo == 0 {}
    }
}

/// Token do Linear num lugar só (FRA-568): o item que os scripts leem. O item antigo do app
/// (`app.tuttidash.mac`, conta `linear`) só é lido para migrar e depois apagado.
public struct TokenLinear: Sendable {
    public static let conta = "linear"
    public static let servicoPadrao = "linear-transcentia-lanes"
    public let cofre: Cofre
    public let servico: String
    public let chaveiro: ChaveiroScripts
    public init(cofre: Cofre = Cofre(),
                servico: String = Configuracao.valor("linear.keychain_service", em: Configuracao.lerArquivo())
                    .map { "\($0)" }.flatMap { $0.isEmpty ? nil : $0 } ?? TokenLinear.servicoPadrao,
                chaveiro: ChaveiroScripts = ChaveiroSecurity()) {
        self.cofre = cofre; self.servico = servico; self.chaveiro = chaveiro
    }

    public func ler() -> String? {
        if let t = chaveiro.ler(servico: servico) { return t }
        guard let antigo = cofre.ler(conta: Self.conta) else { return nil }
        if (try? chaveiro.gravar(antigo, servico: servico, conta: NSUserName())) != nil {
            cofre.apagar(conta: Self.conta)
        }
        return antigo
    }

    public func salvar(_ t: String) throws {
        try chaveiro.gravar(t.trimmingCharacters(in: .whitespacesAndNewlines), servico: servico, conta: NSUserName())
        cofre.apagar(conta: Self.conta)
    }

    public func apagar() {
        chaveiro.apagar(servico: servico)
        cofre.apagar(conta: Self.conta)
    }
}
