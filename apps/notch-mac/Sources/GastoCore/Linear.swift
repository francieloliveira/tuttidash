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

/// Item antigo do `security` (FRA-568). O app só lê uma vez para trazer o token ao
/// Keychain protegido e depois apaga. Não grava mais: qualquer processo lia sem prompt.
public protocol ChaveiroScripts: Sendable {
    func ler(servico: String) -> String?
    func gravar(_ segredo: String, servico: String, conta: String) throws
    func apagar(servico: String)
}

public struct ChaveiroSecurity: ChaveiroScripts {
    public init() {}

    @discardableResult
    private func rodar(_ args: [String]) -> (codigo: Int32, saida: String) {
        let r = Subprocesso.rodar("/usr/bin/security", args)
        return (r.codigo, r.texto)
    }

    public func ler(servico: String) -> String? {
        let r = rodar(["find-generic-password", "-s", servico, "-w"])
        let v = r.saida.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.codigo == 0 && !v.isEmpty ? v : nil
    }

    /// Aposentado (FRA-607): gravar aqui deixava o token legível por qualquer processo.
    public func gravar(_ segredo: String, servico: String, conta: String) throws {
        _ = (segredo, servico, conta)
        throw ErroLinear.resposta(String(localized: "o item do security está aposentado"))
    }

    public func apagar(servico: String) {
        for _ in 0..<5 where rodar(["delete-generic-password", "-s", servico]).codigo == 0 {}
    }
}

/// Token dedicado do dispatcher e do vigia (FRA-607). Fica no Keychain do app, com
/// proteção de dados e access group. Os scripts não leem o token: pedem o proxy.
public struct TokenLinear: Sendable {
    /// Conta antiga do app, antes do item dedicado.
    public static let contaAntiga = "linear"
    /// Conta só do dispatcher, do vigia e das chamadas do app ao Linear.
    public static let conta = "linear-dispatcher"
    public static let servicoSecurityAposentado = "linear-transcentia-lanes"
    public let cofre: Cofre
    public let cofreAntigo: Cofre
    public let servicoSecurity: String
    public let chaveiro: ChaveiroScripts

    public init(cofre: Cofre? = nil, cofreAntigo: Cofre? = nil, servicoSecurity: String? = nil,
                chaveiro: ChaveiroScripts = ChaveiroSecurity()) {
        self.cofre = cofre ?? Cofre(servico: Cofre.servicoPadrao, migrarLegado: false,
                                    protecaoDeDados: true, grupo: AtributosChaveiro.grupoLinear)
        self.cofreAntigo = cofreAntigo ?? Cofre(servico: Cofre.servicoPadrao)
        self.servicoSecurity = servicoSecurity ?? Self.servicoSecurityConfigurado()
        self.chaveiro = chaveiro
    }

    /// Atributos do item dedicado: proteção de dados e access group. Não é o serviço do `security`.
    public static func atributos(servico: String = Cofre.servicoPadrao, conta: String = TokenLinear.conta) -> [String: Any] {
        AtributosChaveiro.item(servico: servico, conta: conta, grupo: AtributosChaveiro.grupoLinear,
                               protecaoDeDados: true)
    }

    public static func servicoSecurityConfigurado() -> String {
        let bruto = Configuracao.valor("linear.keychain_service", em: Configuracao.lerArquivo()).map { "\($0)" } ?? ""
        let nome = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        return nome.isEmpty ? servicoSecurityAposentado : nome
    }

    public func ler() -> String? {
        if let t = cofre.ler(conta: Self.conta), !t.isEmpty {
            limparLegado(igualA: t)
            return t
        }
        if let antigo = cofreAntigo.ler(conta: Self.contaAntiga), !antigo.isEmpty {
            if guardou(antigo) { limparLegado(igualA: antigo) }
            return antigo
        }
        if let doScript = chaveiro.ler(servico: servicoSecurity), !doScript.isEmpty {
            if guardou(doScript) { chaveiro.apagar(servico: servicoSecurity) }
            return doScript
        }
        return nil
    }

    public func salvar(_ t: String) throws {
        let limpo = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpo.isEmpty { throw ErroLinear.semToken }
        if limpo.contains(where: { $0 == "\n" || $0 == "\r" }) {
            throw ErroLinear.resposta(String(localized: "token com caractere inválido"))
        }
        try cofre.salvar(limpo, conta: Self.conta)
        limparLegado(igualA: nil)
    }

    public func apagar() {
        cofre.apagar(conta: Self.conta)
        cofreAntigo.apagar(conta: Self.contaAntiga)
        chaveiro.apagar(servico: servicoSecurity)
    }

    /// Só apaga o item do `security` depois que o Keychain protegido devolve o mesmo token.
    private func guardou(_ segredo: String) -> Bool {
        (try? cofre.salvar(segredo, conta: Self.conta)) != nil && cofre.ler(conta: Self.conta) == segredo
    }

    /// `igualA == nil` apaga a conta antiga sempre (quem chamou acabou de gravar o token novo).
    private func limparLegado(igualA token: String?) {
        chaveiro.apagar(servico: servicoSecurity)
        let antigo = cofreAntigo.ler(conta: Self.contaAntiga)
        if token == nil || antigo == token { cofreAntigo.apagar(conta: Self.contaAntiga) }
        if cofreAntigo.servico == Cofre.servicoPadrao {
            Cofre(servico: Legado.servicoCofreAntigo, migrarLegado: false).apagar(conta: Self.contaAntiga)
        }
    }
}
