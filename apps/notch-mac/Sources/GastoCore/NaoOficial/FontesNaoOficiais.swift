import Foundation

/// Leituras de uso fora das APIs oficiais: endpoints não documentados, chamados com o login que a
/// própria ferramenta guardou nesta máquina. Cada conta liga a sua com `"nao_oficial": true`.
/// Nenhum token fica no código ou na config, e nada é renovado ou regravado.
public enum FontesNaoOficiais {
    /// Variáveis de ambiente que trocam o caminho de cada credencial.
    public static let env: [String: String] = [
        "claude_cred": "TRANSCENTIA_CLAUDE_CRED",
        "claude_keychain": "TRANSCENTIA_CLAUDE_KEYCHAIN",
        "grok_auth": "TRANSCENTIA_GROK_AUTH",
        "cursor_db": "TRANSCENTIA_CURSOR_DB",
        "codex_auth": "TRANSCENTIA_CODEX_AUTH",
        "gemini_auth": "TRANSCENTIA_GEMINI_AUTH",
        "opencode_auth": "TRANSCENTIA_OPENCODE_AUTH",
        "deepseek_cred": "TRANSCENTIA_DEEPSEEK_CRED",
    ]

    public static let urlClaude = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let urlGrok = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    public static let urlSand = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    public static let urlCodex = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let urlOpenCode = URL(string: "https://opencode.ai/console/api/go/status")!
    public static let urlGeminiAssist = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let urlDeepSeek = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
    public static let urlGeminiCota = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    /// Todas as fontes não oficiais, com leitores injetáveis para o teste.
    public static func fontes(lerKeychain: @escaping @Sendable () -> Data? = { KeychainClaude.ler() },
                              lerCursor: @escaping @Sendable (URL) -> Result<TokenConta, ErroUso> = { CredenciaisCursor.ler($0) })
        -> [FonteUso] {
        [FonteClaude(lerKeychain: lerKeychain), FonteGrok(), FonteCursor(lerCursor: lerCursor),
         FonteCodex(), FonteOpenCodeConsole(), FonteDeepSeek(), FonteGemini()]
    }

    /// Listas de modelos pelo login (Claude e Codex), só das contas com `nao_oficial`.
    /// Chamar uma vez, no início, com a config já resolvida.
    public static func registrarListas(config: Configuracao) {
        let ligados = Set(config.contas.filter { $0.naoOficial && $0.ativo }.map(\.tipo))
        ModelosNaoOficiais.registrar(tipos: ligados)
    }

    static func campo(_ chave: String, _ rotulo: String, _ padrao: String) -> CampoAjuste {
        CampoAjuste(chave, rotulo, .caminho(deveExistir: true, opcional: true), padrao)
    }
}

public struct FonteClaude: FonteUso {
    public let tipo = "claude"
    public let naoOficial = true
    let lerKeychain: @Sendable () -> Data?
    public init(lerKeychain: @escaping @Sendable () -> Data? = { KeychainClaude.ler() }) { self.lerKeychain = lerKeychain }

    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("claude_cred", String(localized: "Credencial do Claude"), "~/.claude/.credentials.json"),
         CampoAjuste("claude_keychain", String(localized: "Ler credencial do Claude no Keychain"), .booleano, "true")]
    }

    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let cred = ctx.config.credClaude
        let versao = CredenciaisClaude.versao(
            ctx.ler(cred.deletingLastPathComponent().appendingPathComponent(".last-update-result.json")))
        let usarKeychain = ctx.config.claudeKeychain
        let doArquivo = ctx.arquivo(cred, cli: CredenciaisClaude.cli) { CredenciaisClaude.ler($0, caminho: $1) }
        let lerKeychain = self.lerKeychain
        return AlvoUso(conta: tipo, rotulo: "Claude Code", fonte: "api.anthropic.com/api/oauth/usage",
                       url: FontesNaoOficiais.urlClaude, vencido: .tokenExpirado(CredenciaisClaude.cli),
                       cabecalhos: { t in
                           ["Authorization": "Bearer \(t.valor)",
                            "anthropic-beta": "oauth-2025-04-20",
                            "User-Agent": "claude-code/\(versao)",
                            "Accept": "application/json"]
                       },
                       token: {
                           let arquivo = doArquivo()
                           guard usarKeychain else { return arquivo }
                           let keychain = lerKeychain().map { CredenciaisClaude.ler($0, caminho: KeychainClaude.rotulo) }
                           return CredenciaisClaude.escolher(arquivo: arquivo, keychain: keychain)
                       },
                       lerResposta: ParserUsoClaude.ler)
    }
}

public struct FonteGrok: FonteUso {
    public let tipo = "grok"
    public let naoOficial = true
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("grok_auth", String(localized: "Credencial do grok CLI"), "~/.grok/auth.json")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let auth = ctx.config.authGrok
        return AlvoUso(conta: tipo, rotulo: "Grok CLI", fonte: "cli-chat-proxy.grok.com/v1/billing",
                       url: FontesNaoOficiais.urlGrok, vencido: .tokenExpirado(CredenciaisGrok.cli),
                       cabecalhos: { t in
                           ["Authorization": "Bearer \(t.valor)",
                            "x-xai-token-auth": "xai-grok-cli",
                            "Accept": "application/json"]
                       },
                       token: ctx.arquivo(auth, cli: CredenciaisGrok.cli) { CredenciaisGrok.ler($0, caminho: $1) },
                       lerResposta: ParserUsoGrok.ler)
    }
}

public struct FonteCursor: FonteUso {
    public let tipo = "cursor"
    public let naoOficial = true
    let lerCursor: @Sendable (URL) -> Result<TokenConta, ErroUso>
    public init(lerCursor: @escaping @Sendable (URL) -> Result<TokenConta, ErroUso> = { CredenciaisCursor.ler($0) }) {
        self.lerCursor = lerCursor
    }
    static let banco = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("cursor_db", String(localized: "Banco do Cursor"), Self.banco)]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let banco = ctx.config.cursorDB
        let lerCursor = self.lerCursor
        return AlvoUso(conta: tipo, rotulo: "Grok Bot / SuperGrok (via Cursor)",
                       fonte: "api2.cursor.sh · DashboardService/GetSandUsageStatus",
                       url: FontesNaoOficiais.urlSand, metodo: "POST", corpo: Data("{}".utf8), vencido: .tokenCursorVencido,
                       cabecalhos: { t in
                           ["Authorization": "Bearer \(t.valor)",
                            "Content-Type": "application/json",
                            "Accept": "application/json"]
                       },
                       token: { lerCursor(banco) },
                       lerResposta: ParserUsoSand.ler)
    }
}

public struct FonteCodex: FonteUso {
    public let tipo = "codex"
    public let naoOficial = true
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("codex_auth", String(localized: "Credencial do Codex"), "~/.codex/auth.json")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let auth = ctx.config.authCodex
        return AlvoUso(conta: tipo, rotulo: "Codex", fonte: "chatgpt.com/backend-api · wham/usage",
                       url: FontesNaoOficiais.urlCodex, vencido: .tokenExpirado(CredenciaisCodex.cli),
                       cabecalhos: { t in
                           var h = ["Authorization": "Bearer \(t.valor)", "Accept": "application/json"]
                           if let o = t.orgID, !o.isEmpty { h["ChatGPT-Account-Id"] = o }
                           return h
                       },
                       token: ctx.arquivo(auth, cli: CredenciaisCodex.cli) { CredenciaisCodex.ler($0, caminho: $1) },
                       lerResposta: ParserUsoCodex.ler)
    }
}

/// Plano OpenCode Go (janelas de 5 h, semana e mês), pela mesma chamada da página Go do Console.
public struct FonteOpenCodeConsole: FonteUso {
    public let tipo = "opencode-go"
    public let naoOficial = true
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("opencode_auth", String(localized: "Credencial do OpenCode (arquivo)"),
                            "~/.local/share/opencode/auth.json")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let banco = ctx.config.opencodeDb
        let arquivo = ctx.config.authOpenCode
        let ler = ctx.ler
        return AlvoUso(conta: tipo, rotulo: "OpenCode Go", fonte: "opencode.ai/console · api/go/status",
                       url: FontesNaoOficiais.urlOpenCode, vencido: .tokenExpirado(CredenciaisOpenCode.cli),
                       cabecalhos: { t in
                           // User-Agent explícito: o console barra UAs genéricos de bot com 403.
                           var h = ["Authorization": "Bearer \(t.valor)",
                                    "Accept": "application/json",
                                    "User-Agent": "Lanekeeper"]
                           if let o = t.orgID, !o.isEmpty { h["x-org-id"] = o }
                           return h
                       },
                       token: { CredenciaisOpenCode.ler(banco: banco, arquivo: arquivo, lerArquivo: ler) },
                       lerResposta: ParserUsoOpenCode.ler)
    }
}

public struct FonteGemini: FonteUso {
    public let tipo = "gemini"
    public let naoOficial = true
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("gemini_auth", String(localized: "Credencial do Gemini"), "~/.gemini/oauth_creds.json")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let auth = ctx.config.authGemini
        let transporte = ctx.transporte
        return AlvoUso(conta: tipo, rotulo: "Gemini",
                       fonte: "cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
                       url: FontesNaoOficiais.urlGeminiCota, metodo: "POST",
                       vencido: .tokenExpirado(CredenciaisGemini.cli),
                       cabecalhos: ConsultaGemini.cabecalhos,
                       token: ctx.arquivo(auth, cli: CredenciaisGemini.cli) { CredenciaisGemini.ler($0, caminho: $1) },
                       lerResposta: ParserUsoGemini.ler,
                       preparar: { token in await ConsultaGemini.preparar(transporte: transporte, token: token) })
    }
}

/// Saldo da conta DeepSeek (Platform), pela mesma chamada do app DeepSeek Harness, com o grant
/// que ele guardou em `~/.dsh/.credentials.yaml`. A conta é pré-paga: não há janela, há saldo
/// (recarga + bônus) em US$. A API oficial (`/user/balance`) pede chave de API, que o dsh não usa.
public struct FonteDeepSeek: FonteUso {
    public let tipo = "deepseek"
    public let naoOficial = true
    public init() {}
    public var camposAjuste: [CampoAjuste] {
        [FontesNaoOficiais.campo("deepseek_cred", String(localized: "Credencial do DeepSeek Harness"),
                                 "~/.dsh/.credentials.yaml")]
    }
    public func alvo(_ ctx: ContextoUso) -> AlvoUso {
        let cred = ctx.config.credDeepSeek
        var a = AlvoUso(conta: tipo, rotulo: "DeepSeek", fonte: "platform.deepseek.com · users/get_user_summary",
                        url: FontesNaoOficiais.urlDeepSeek, vencido: .tokenExpirado(CredenciaisDeepSeek.cli),
                        cabecalhos: { t in
                            ["x-dsh-auth-token": t.valor,
                             "Accept": "application/json",
                             "x-client-platform": "desktop-mac",
                             "x-client-locale": "en_US",
                             "User-Agent": "TuttiDash"]
                        },
                        token: ctx.arquivo(cred, cli: CredenciaisDeepSeek.cli) { CredenciaisDeepSeek.ler($0, caminho: $1) },
                        lerResposta: ParserUsoDeepSeek.ler)
        a.recusado = .tokenExpirado(CredenciaisDeepSeek.cli)
        return a
    }
}
