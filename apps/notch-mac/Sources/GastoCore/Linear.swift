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

/// Token do Linear: item novo do app no Keychain; o item antigo dos scripts só é lido como fallback.
public struct TokenLinear: Sendable {
    public static let conta = "linear"
    public let cofre: Cofre
    /// Serviço do item dos scripts (`linear.keychain_service`); nil = sem fallback.
    public let servicoAntigo: String?
    public init(cofre: Cofre = Cofre(),
                servicoAntigo: String? = Configuracao.valor("linear.keychain_service", em: Configuracao.lerArquivo()).map { "\($0)" }) {
        self.cofre = cofre; self.servicoAntigo = servicoAntigo
    }
    public func ler() -> String? { cofre.ler(conta: Self.conta) }
    /// Lê o item dos scripts (`linear.keychain_service`); pode pedir permissão ao Keychain.
    public func lerAntigo() -> String? { servicoAntigo.flatMap { Cofre(servico: $0).lerQualquer() } }
    public func salvar(_ t: String) throws { try cofre.salvar(t.trimmingCharacters(in: .whitespacesAndNewlines), conta: Self.conta) }
    public func apagar() { cofre.apagar(conta: Self.conta) }
}
