import Foundation

public struct RespostaHTTP: Sendable {
    public var status: Int
    public var corpo: Data
    public init(status: Int, corpo: Data) { self.status = status; self.corpo = corpo }
}

/// Uma chamada HTTP, injetável para os testes não tocarem a rede.
/// GET para claude e grok CLI; POST com `{}` para o Grok Bot (Connect, só consulta).
public protocol TransporteHTTP: Sendable {
    func enviar(_ url: URL, metodo: String, cabecalhos: [String: String], corpo: Data?) async throws -> RespostaHTTP
}

public struct TransporteURLSession: TransporteHTTP {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 12) { self.timeout = timeout }

    public func enviar(_ url: URL, metodo: String, cabecalhos: [String: String], corpo: Data?) async throws -> RespostaHTTP {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = metodo
        req.httpBody = corpo
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in cabecalhos { req.setValue(v, forHTTPHeaderField: k) }
        let (dados, resposta) = try await URLSession.shared.data(for: req)
        return RespostaHTTP(status: (resposta as? HTTPURLResponse)?.statusCode ?? 0, corpo: dados)
    }
}

/// Como montar a leitura de uso de um tipo de conta (FRA-565).
///
/// O TuttiDash traz só leituras oficiais ou locais: `copilot` (API de cobrança do GitHub, com o
/// token que a pessoa cola) e `opencode_sessao` (o banco local do OpenCode, sem rede). Outras
/// fontes entram por `FontesUso.registrar`, de um módulo à parte que não faz parte deste
/// repositório. Cada fonte só lê: nunca renova nem regrava credencial de outra ferramenta.
public protocol FonteUso: Sendable {
    /// Tipo de conta que esta fonte mede (o `tipo` de `contas` na config).
    var tipo: String { get }
    /// Campos de Ajustes que esta fonte usa (por exemplo, o caminho de uma credencial).
    var camposAjuste: [CampoAjuste] { get }
    func alvo(_ ctx: ContextoUso) -> AlvoUso
}

public extension FonteUso {
    var camposAjuste: [CampoAjuste] { [] }
}

/// O que uma fonte recebe para montar a leitura.
public struct ContextoUso: Sendable {
    public let config: Configuracao
    public let ler: @Sendable (URL) -> Data?
    public let transporte: TransporteHTTP

    public init(config: Configuracao, ler: @escaping @Sendable (URL) -> Data?, transporte: TransporteHTTP) {
        self.config = config; self.ler = ler; self.transporte = transporte
    }

    /// Credencial em arquivo: ausente = a ferramenta nunca logou; senão quem interpreta é `interpretar`.
    public func arquivo(_ url: URL, cli: String,
                        _ interpretar: @escaping @Sendable (Data, String) -> Result<TokenConta, ErroUso>)
        -> @Sendable () -> Result<TokenConta, ErroUso> {
        let ler = self.ler
        return {
            guard let dados = ler(url) else { return .failure(.semCredencial(cli)) }
            return interpretar(dados, url.path)
        }
    }
}

/// Uma leitura montada: de onde vem o token, para onde vai o pedido e como ler a resposta.
public struct AlvoUso {
    public var conta: String
    public var rotulo: String
    public var tipo = ""
    public var nome = ""
    public var sigla = ""
    public var fonte: String
    public var url: URL?
    public var metodo = "GET"
    public var corpo: Data?
    /// Motivo quando o token do disco já venceu.
    public var vencido: ErroUso
    public var cabecalhos: (TokenConta) -> [String: String]
    public var token: () -> Result<TokenConta, ErroUso>
    public var lerResposta: (Data) -> Result<[JanelaUso], ErroUso>
    /// Leitura local (sem rede): quando presente, é usada em vez da chamada HTTP.
    public var lerLocal: ((URL?) -> Result<[JanelaUso], ErroUso>)?
    /// Antes da cota. Sucesso troca o corpo do POST; falha vira «sem dado» e a cota não é chamada.
    public var preparar: ((TokenConta) async -> Result<Data?, ErroUso>)? = nil
    /// Monta a URL na hora (usuário e mês). Falha vira «sem dado» e a rede não é chamada.
    public var montarPedido: ((Date) -> Result<URL, ErroUso>)? = nil
    /// Lê a resposta com a data do pedido. nil = `lerResposta`.
    public var interpretar: ((Data, Date) -> Result<[JanelaUso], ErroUso>)? = nil
    /// Erro para 401/403 (padrão: não autorizado).
    public var recusado: ErroUso = .naoAutorizado
    /// Erro para 404. nil = vale o HTTP 404 como erro genérico.
    public var naoEncontrado: ErroUso? = nil

    public init(conta: String, rotulo: String, fonte: String, url: URL?, metodo: String = "GET",
                corpo: Data? = nil, vencido: ErroUso,
                cabecalhos: @escaping (TokenConta) -> [String: String],
                token: @escaping () -> Result<TokenConta, ErroUso>,
                lerResposta: @escaping (Data) -> Result<[JanelaUso], ErroUso>,
                lerLocal: ((URL?) -> Result<[JanelaUso], ErroUso>)? = nil,
                preparar: ((TokenConta) async -> Result<Data?, ErroUso>)? = nil) {
        self.conta = conta; self.rotulo = rotulo; self.fonte = fonte; self.url = url
        self.metodo = metodo; self.corpo = corpo; self.vencido = vencido; self.cabecalhos = cabecalhos
        self.token = token; self.lerResposta = lerResposta; self.lerLocal = lerLocal; self.preparar = preparar
    }
}

extension ErroUso {
    /// Depois deste erro a conta espera `ColetorUso.esperaLimitado`, como num 429.
    public var esperaLonga: Bool {
        if case .motivoEsperar = self { return true }
        return false
    }
}

/// Fontes de uso conhecidas: as do TuttiDash mais as registradas por um módulo à parte.
public enum FontesUso {
    private static let trava = NSLock()
    nonisolated(unsafe) private static var registradas: [FonteUso] = []

    /// Só leituras oficiais ou locais.
    public static var publicas: [FonteUso] { [FonteOpenCodeSessao(), FonteCopilot()] }

    /// Acrescenta fontes; uma do mesmo `tipo` substitui a anterior.
    public static func registrar(_ novas: [FonteUso]) {
        trava.lock(); defer { trava.unlock() }
        let tipos = Set(novas.map(\.tipo))
        registradas = registradas.filter { !tipos.contains($0.tipo) } + novas
    }

    public static var todas: [FonteUso] {
        trava.lock(); defer { trava.unlock() }
        let tipos = Set(registradas.map(\.tipo))
        return publicas.filter { !tipos.contains($0.tipo) } + registradas
    }
}

/// `opencode_sessao`: contexto da sessão no banco local do OpenCode. Sem rede.
public struct FonteOpenCodeSessao: FonteUso {
    public let tipo = "opencode_sessao"
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [CampoAjuste("opencode_db", String(localized: "Banco do OpenCode (sessão)"),
                     .caminho(deveExistir: true, opcional: true), "~/.local/share/opencode/opencode.db")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let banco = ctx.config.opencodeDb
        return AlvoUso(conta: tipo, rotulo: "OpenCode (sessão)",
                       fonte: "opencode.db · session_v2 (contexto da sessão)",
                       url: banco, vencido: .semCredencial("opencode"),
                       cabecalhos: { _ in [:] },
                       token: { .success(TokenConta(valor: "")) },
                       lerResposta: { _ in .failure(.respostaIlegivel) },
                       lerLocal: { b in ParserUsoOpenCodeSession.ler(banco: b ?? banco) })
    }
}

/// `copilot` (opt-in): relatório de cobrança do GitHub, com o token que a pessoa colou
/// no Keychain do app ou apontou num arquivo. Usuário e cota mensal vêm da conta.
public struct FonteCopilot: FonteUso {
    public let tipo = "copilot"
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [CampoAjuste("copilot_token", String(localized: "Arquivo do token do Copilot (opcional)"),
                     .caminho(deveExistir: true, opcional: true), "",
                     ajuda: String(localized: "Só o caminho. O token em si fica no Keychain. Vazio = só o Keychain."))]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        var a = AlvoUso(conta: tipo, rotulo: "Copilot",
                        fonte: "api.github.com/users/{username}/settings/billing/premium_request/usage",
                        url: nil, vencido: .semTokenCopilot,
                        cabecalhos: ParserUsoCopilot.cabecalhos,
                        token: { .failure(.semTokenCopilot) },
                        lerResposta: { _ in .failure(.semCotaInformada) })
        a.recusado = .tokenCopilotRecusado
        a.naoEncontrado = .copilotSemRelatorio
        return a
    }
}

/// Pergunta às contas quanto falta do limite, pelas fontes registradas (`FontesUso`). Só
/// consultas: nada é gravado nas credenciais das ferramentas.
///
/// Guarda o último valor bom em memória e respeita um intervalo mínimo entre chamadas; em 429
/// espera bem mais. Token vencido não é renovado (viraria escrita na credencial): a conta fica
/// "sem dado" com o motivo.
public actor ColetorUso {
    public typealias LeitorArquivo = @Sendable (URL) -> Data?
    public typealias LeitorTokenCopilot = @Sendable () -> String?

    /// Nunca mais de uma chamada por conta nesse intervalo.
    public static let intervaloMinimo: TimeInterval = 90
    /// Depois de um 429, espera isso antes de tentar de novo.
    public static let esperaLimitado: TimeInterval = 15 * 60

    private let transporte: TransporteHTTP
    private let ler: LeitorArquivo
    private let lerTokenCopilot: LeitorTokenCopilot
    private let fontes: [FonteUso]
    private var ultimo: [String: UsoConta] = [:]
    private var proxima: [String: Date] = [:]

    public init(transporte: TransporteHTTP = TransporteURLSession(),
                ler: @escaping LeitorArquivo = { try? Data(contentsOf: $0) },
                lerTokenCopilot: @escaping LeitorTokenCopilot = { TokenCopilot().ler() },
                fontes: [FonteUso] = FontesUso.todas) {
        self.transporte = transporte
        self.ler = ler
        self.lerTokenCopilot = lerTokenCopilot
        self.fontes = fontes
    }

    /// Uma leitura por conta, na ordem da lista `contas` da config. Lista vazia = desligado na config.
    public func coletar(config: Configuracao, agora: Date = Date()) async -> [UsoConta] {
        guard config.usoContas else { return [] }
        var saida: [UsoConta] = []
        for alvo in alvos(config: config) {
            var u = await coletarUma(alvo, agora: agora)
            u.tipo = alvo.tipo; u.nome = alvo.nome; u.sigla = alvo.sigla
            saida.append(u)
        }
        return saida
    }

    /// Uma medição por conta da config, no tipo dela, com o id/rótulo escolhidos. Tipo sem
    /// fonte registrada fica de fora (no TuttiDash aberto, só as fontes oficiais e locais).
    private func alvos(config: Configuracao) -> [AlvoUso] {
        let ctx = ContextoUso(config: config, ler: ler, transporte: transporte)
        let porTipo = Dictionary(fontes.map { ($0.tipo, $0) }, uniquingKeysWith: { _, ultima in ultima })
        let lerToken = self.lerTokenCopilot
        let lerArquivo = self.ler
        let global = config.authCopilot
        return config.contas.compactMap { c in
            guard let fonte = porTipo[c.tipo] else { return nil }
            var a = fonte.alvo(ctx)
            a.tipo = c.tipo; a.conta = c.id; a.rotulo = c.rotulo; a.nome = c.nome; a.sigla = c.sigla
            if c.tipo == "copilot" {
                let usuario = c.githubUsuario
                let cota = c.cotaPremiumMes
                let arquivo = c.arquivoToken
                a.montarPedido = { agora in
                    ParserUsoCopilot.pedido(usuario: usuario, cota: cota, agora: agora)
                }
                a.token = {
                    CredenciaisCopilot.resolver(keychain: lerToken(), arquivoConta: arquivo,
                                                arquivoGlobal: global, ler: lerArquivo)
                }
                a.interpretar = { dados, quando in
                    ParserUsoCopilot.ler(dados, cota: cota ?? 0, agora: quando)
                }
            }
            return a
        }
    }

    private func coletarUma(_ alvo: AlvoUso, agora: Date) async -> UsoConta {
        func semDado(_ erro: ErroUso) -> UsoConta {
            // um valor bom recente continua valendo: mostra o número com a idade dele
            if var antigo = ultimo[alvo.conta], antigo.temDado {
                antigo.motivo = erro.mensagem
                return antigo
            }
            let uso = UsoConta(conta: alvo.conta, rotulo: alvo.rotulo, fonte: alvo.fonte, motivo: erro.mensagem)
            // guarda o motivo: no freio seguinte a tela não troca a causa por um 429 inventado
            ultimo[alvo.conta] = uso
            return uso
        }

        if let quando = proxima[alvo.conta], quando > agora {
            return ultimo[alvo.conta]
                ?? UsoConta(conta: alvo.conta, rotulo: alvo.rotulo, fonte: alvo.fonte,
                            motivo: ErroUso.limitado.mensagem)
        }
        let urlMontada: URL?
        if let montar = alvo.montarPedido {
            switch montar(agora) {
            case .failure(let e): return semDado(e)
            case .success(let u): urlMontada = u
            }
        } else {
            urlMontada = nil
        }
        let token: TokenConta
        switch alvo.token() {
        case .failure(let e): return semDado(e)
        case .success(let t): token = t
        }
        if token.expirado(agora: agora) { return semDado(alvo.vencido) }

        // Leitura local (sem rede): usada por bancos SQLite locais (ex.: opencode.db
        // da sessão OpenCode). Não consome freio de rede nem chamadas HTTP.
        if let lerLocal = alvo.lerLocal {
            let banco = alvo.url
            switch lerLocal(banco) {
            case .failure(let e):
                return semDado(e)
            case .success(let janelas):
                let uso = UsoConta(conta: alvo.conta, rotulo: alvo.rotulo, fonte: alvo.fonte,
                                   janelas: janelas, motivo: nil, atualizadoEm: agora)
                ultimo[alvo.conta] = uso
                return uso
            }
        }

        proxima[alvo.conta] = agora.addingTimeInterval(Self.intervaloMinimo)
        var corpo = alvo.corpo
        if let preparar = alvo.preparar {
            switch await preparar(token) {
            case .failure(let e):
                if e == .limitado || e.esperaLonga {
                    proxima[alvo.conta] = agora.addingTimeInterval(Self.esperaLimitado)
                }
                return semDado(e)
            case .success(let novo):
                if let novo { corpo = novo }
            }
        }
        let resposta: RespostaHTTP
        do {
            guard let url = urlMontada ?? alvo.url else {
                return semDado(.credencialIlegivel("URL ausente"))
            }
            resposta = try await transporte.enviar(url, metodo: alvo.metodo,
                                                   cabecalhos: alvo.cabecalhos(token), corpo: corpo)
        } catch {
            return semDado(.rede((error as? URLError).map { "\($0.code.rawValue)" } ?? "\(error)"))
        }
        switch resposta.status {
        case 200:
            break
        case 401, 403:
            return semDado(alvo.recusado)
        case 404 where alvo.naoEncontrado != nil:
            return semDado(alvo.naoEncontrado!)
        case 429:
            proxima[alvo.conta] = agora.addingTimeInterval(Self.esperaLimitado)
            return semDado(.limitado)
        default:
            return semDado(.http(resposta.status))
        }
        let lido: Result<[JanelaUso], ErroUso>
        if let interpretar = alvo.interpretar {
            lido = interpretar(resposta.corpo, agora)
        } else {
            lido = alvo.lerResposta(resposta.corpo)
        }
        switch lido {
        case .failure(let e):
            return semDado(e)
        case .success(let janelas):
            let uso = UsoConta(conta: alvo.conta, rotulo: alvo.rotulo, fonte: alvo.fonte,
                               janelas: janelas, motivo: nil, atualizadoEm: agora)
            ultimo[alvo.conta] = uso
            return uso
        }
    }
}
