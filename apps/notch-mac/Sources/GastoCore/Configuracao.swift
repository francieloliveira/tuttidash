import Foundation

/// Mesma configuração da ferramenta `gasto` (gasto_lanes/config.py), sem flags:
/// variável de ambiente > arquivo de config > padrão do Mac.
public struct Configuracao: Equatable, Sendable {
    public var logsDir: URL
    public var stateDir: URL
    public var ledger: URL
    /// nil = sem teto definido (ausente, vazio ou <= 0).
    public var tetoSemanalUSD: Double?
    /// Reais por dólar. nil ou <= 0 = o painel mostra US$ com o rótulo «US$».
    public var taxaUsdBrl: Double?
    public var avisoPct: Double
    /// Banco local do OpenCode (contexto da sessão). Só leitura.
    public var opencodeDb: URL
    /// Arquivo opcional com o token do GitHub Copilot. Só o caminho; o segredo não fica aqui.
    /// nil = não configurado (vale o Keychain).
    public var authCopilot: URL? = nil
    /// false = o app não consulta os limites das contas (nenhuma chamada de rede).
    public var usoContas: Bool
    /// `linear.owner_label`: rótulo "precisa do dono" (padrão só no `cfg`). nil = não configurado.
    public var rotuloDono: String?
    /// `linear.workspace_url`, vindo da API do Linear. nil = não configurado.
    public var workspaceLinear: String?
    /// Contas cujo limite aparece no painel (`contas`). Sem a chave, uma por agente.
    /// Entrada com `ativo: false` continua no arquivo e sai da medição.
    public var contas: [ContaUso] = ContaUso.padrao
    /// Lanes que entram nos cálculos e no painel. nil = todas (sem chave `contas` na config).
    /// Com a chave presente, só os tipos listados contam — inclusive gasto, retomadas e "agora".
    public var lanesHabilitadas: Set<String>?
    public var arquivoConfig: URL
    public var arquivoConfigExiste: Bool
    /// Campo "version" da config (FRA-295). nil = arquivo legado sem versão ou sem arquivo.
    public var versao: Int?
    /// Cadastro de projetos que o dispatcher e o vigia enxergam (chave `projetos`).
    /// Sem a chave na config, nenhum projeto (FRA-565).
    public var projetos: [ProjetoCadastro] = []
    /// O projeto em que o dispatcher trabalha agora (o marcado `padrao` ou o primeiro ativo).
    public var projetoPadrao: ProjetoCadastro? { ProjetosConfig.padrao(projetos) }
    /// true quando o arquivo em uso é o legado (`Legado.configLegada`).
    public var usandoLegado: Bool = false
    /// Erro de leitura da config (o app continua com os padrões e mostra o aviso).
    public var erro: String?

    /// Home e ambiente usados na resolução, para quem resolve caminhos depois (fontes de uso).
    public var home: URL = FileManager.default.homeDirectoryForCurrentUser
    public var ambiente: [String: String] = [:]
    /// Valores simples do arquivo (texto, número ou booleano) que o GastoCore não interpreta:
    /// ficam para as fontes de uso registradas de fora (FRA-565).
    public var extras: [String: String] = [:]

    /// Caminho de uma chave extra: variável de ambiente `env` > arquivo > `padrao` (relativo à home).
    public func caminhoExtra(_ chave: String, env: String? = nil, padrao: String) -> URL {
        if let env, let v = ambiente[env], !v.isEmpty { return Self.expandir(v, ambiente: ambiente, home: home) }
        if let v = extras[chave], !v.isEmpty { return Self.expandir(v, ambiente: ambiente, home: home) }
        return Self.expandir(padrao, ambiente: ambiente, home: home)
    }

    /// Booleano de uma chave extra: aceita true/false, 1/0, sim/não.
    public func booleanoExtra(_ chave: String, env: String? = nil, padrao: Bool) -> Bool {
        let bruto = env.flatMap { ambiente[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? extras[chave]
        switch bruto?.lowercased() {
        case "1", "true", "sim", "s", "yes", "on": return true
        case "0", "false", "nao", "não", "n", "no", "off": return false
        default: return padrao
        }
    }

    public static let envConfig = Legado.envConfig
    public static let env = Legado.env
    public static let avisoPctPadrao = 80.0
    public static let versaoAtual = 1

    /// Pasta do app (FRA-523): ~/Library/Application Support/TuttiDash
    public static func pastaApp(home: URL) -> URL {
        home.appendingPathComponent(Legado.pastaApp)
    }
    /// Arquivo novo: ~/Library/Application Support/TuttiDash/config.json
    public static func arquivoNovo(home: URL) -> URL {
        pastaApp(home: home).appendingPathComponent("config.json")
    }
    /// Arquivo de antes do FRA-523 (pasta Lanekeeper); lido como reserva e nunca apagado.
    public static func arquivoLanekeeper(home: URL) -> URL {
        home.appendingPathComponent(Legado.pastaLanekeeper).appendingPathComponent("config.json")
    }

    /// FRA-523: copia (não move) os arquivos da pasta Lanekeeper para a pasta TuttiDash.
    /// Não sobrescreve o que já existe na pasta nova. Devolve os nomes copiados.
    @discardableResult
    public static func copiarPastaAntiga(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let fm = FileManager.default
        let antiga = home.appendingPathComponent(Legado.pastaLanekeeper)
        let nova = pastaApp(home: home)
        guard let itens = try? fm.contentsOfDirectory(at: antiga, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        try? fm.createDirectory(at: nova, withIntermediateDirectories: true)
        var copiados: [String] = []
        for u in itens where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let alvo = nova.appendingPathComponent(u.lastPathComponent)
            if fm.fileExists(atPath: alvo.path) { continue }
            if (try? fm.copyItem(at: u, to: alvo)) != nil { copiados.append(u.lastPathComponent) }
        }
        return copiados.sorted()
    }
    /// Nome provisório usado antes de TuttiDash; aceito como fallback e origem de migração.
    public static func arquivoIntermedio(home: URL) -> URL {
        home.appendingPathComponent(Legado.configProvisoria)
    }
    /// Arquivo legado, ainda lido como fallback e nunca apagado.
    public static func arquivoLegado(home: URL) -> URL {
        home.appendingPathComponent(Legado.configLegada)
    }

    /// Lê o JSON da config em uso (mesma ordem do `cfg`): env > novo > legado. Vazio se ausente/ilegível.
    public static func lerArquivo(ambiente: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any] {
        let candidatos: [URL]
        if let p = ambiente[envConfig], !p.isEmpty {
            candidatos = [expandir(p, ambiente: ambiente, home: home)]
        } else {
            candidatos = [arquivoNovo(home: home), arquivoLanekeeper(home: home), arquivoIntermedio(home: home),
                          arquivoLegado(home: home)]
        }
        for u in candidatos where FileManager.default.fileExists(atPath: u.path) {
            guard let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        return [:]
    }

    /// Valor por chave pontuada ("preflight.max_load"), igual ao `cfg get`. nil se ausente.
    public static func valor(_ chave: String, em d: [String: Any]) -> Any? {
        var atual: Any? = d
        for parte in chave.split(separator: ".") {
            guard let dict = atual as? [String: Any], let v = dict[String(parte)] else { return nil }
            atual = v
        }
        if atual is NSNull || (atual as? String) == "" { return nil }
        return atual
    }

    public static func numero(_ chave: String, padrao: Double, em d: [String: Any]) -> Double {
        guard let v = valor(chave, em: d), !JV.ehBool(v) else { return padrao }
        return (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? padrao
    }

    /// Cria o arquivo novo (versão atual) a partir do legado, sem apagar o legado.
    /// Não faz nada se o novo já existir. Devolve true se criou.
    @discardableResult
    public static func migrar(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        let novo = arquivoNovo(home: home)
        let fm = FileManager.default
        if fm.fileExists(atPath: novo.path) { return false }
        var d: [String: Any] = [:]
        let origem = [arquivoLanekeeper(home: home), arquivoIntermedio(home: home)]
            .first { fm.fileExists(atPath: $0.path) } ?? arquivoLegado(home: home)
        if let dados = try? Data(contentsOf: origem),
           let o = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] { d = o }
        d["version"] = versaoAtual
        try fm.createDirectory(at: novo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saida = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
        try saida.write(to: novo, options: .atomic)
        return true
    }

    /// Expande `~`, `$VAR`, `${VAR}` e `%VAR%`.
    public static func expandir(_ valor: String, ambiente: [String: String], home: URL) -> URL {
        var s = valor
        for (k, v) in ambiente {
            s = s.replacingOccurrences(of: "%\(k)%", with: v).replacingOccurrences(of: "${\(k)}", with: v)
        }
        if let re = try? NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#) {
            let ns = s as NSString
            var out = ""
            var pos = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
                let nome = ns.substring(with: m.range(at: 1))
                out += ambiente[nome] ?? ns.substring(with: m.range)
                pos = m.range.location + m.range.length
            }
            out += ns.substring(from: pos)
            s = out
        }
        if s == "~" || s.hasPrefix("~/") {
            s = home.path + s.dropFirst()
        }
        return URL(fileURLWithPath: s)
    }

    public static func resolver(ambiente: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Configuracao {
        var cfg = Configuracao(
            logsDir: home.appendingPathComponent(Legado.logsLanes),
            stateDir: home.appendingPathComponent(Legado.estadoLanes),
            ledger: home.appendingPathComponent(Legado.ledger),
            tetoSemanalUSD: nil, taxaUsdBrl: nil, avisoPct: avisoPctPadrao,
            opencodeDb: home.appendingPathComponent(".local/share/opencode/opencode.db"),
            usoContas: true,
            rotuloDono: nil, workspaceLinear: nil,
            arquivoConfig: arquivoNovo(home: home),
            arquivoConfigExiste: false, versao: nil, erro: nil)
        cfg.home = home
        cfg.ambiente = ambiente
        if !FileManager.default.fileExists(atPath: cfg.arquivoConfig.path),
           FileManager.default.fileExists(atPath: arquivoLanekeeper(home: home).path) {
            cfg.arquivoConfig = arquivoLanekeeper(home: home)
        } else if !FileManager.default.fileExists(atPath: cfg.arquivoConfig.path),
           FileManager.default.fileExists(atPath: arquivoIntermedio(home: home).path) {
            cfg.arquivoConfig = arquivoIntermedio(home: home)
        } else if !FileManager.default.fileExists(atPath: cfg.arquivoConfig.path),
           FileManager.default.fileExists(atPath: arquivoLegado(home: home).path) {
            cfg.arquivoConfig = arquivoLegado(home: home)
            cfg.usandoLegado = true
        }

        var obrigatoria = false
        if let p = ambiente[envConfig], !p.isEmpty {
            cfg.arquivoConfig = expandir(p, ambiente: ambiente, home: home)
            cfg.usandoLegado = false
            obrigatoria = true
        }
        var arquivo: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: cfg.arquivoConfig.path) {
            cfg.arquivoConfigExiste = true
            let obj = (try? FileHandle(forReadingFrom: cfg.arquivoConfig))
                .flatMap { h -> Any? in
                    defer { try? h.close() }
                    return (try? h.readToEnd()).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                }
            if let d = obj as? [String: Any] {
                arquivo = d
                cfg.versao = (d["version"] as? NSNumber).flatMap { JV.ehBool($0) ? nil : $0.intValue }
            } else {
                cfg.erro = "config ilegível em \(cfg.arquivoConfig.path)"
            }
        } else if obrigatoria {
            cfg.erro = "arquivo de config não encontrado: \(cfg.arquivoConfig.path)"
        }

        func bruto(_ chave: String) -> Any? {
            if let e = env[chave], let v = ambiente[e], !v.isEmpty { return v }
            if let v = arquivo[chave], !(v is NSNull), (v as? String) != "" { return v }
            return nil
        }
        func caminho(_ chave: String) -> URL? {
            guard let v = bruto(chave) else { return nil }
            return expandir("\(v)", ambiente: ambiente, home: home)
        }
        func numero(_ chave: String) -> Double? {
            guard let v = bruto(chave) else { return nil }
            let n: Double? = JV.ehBool(v) ? nil : ((v as? NSNumber)?.doubleValue ?? Double("\(v)"))
            guard let n, n.isFinite, n >= 0 else {
                cfg.erro = cfg.erro ?? "\(chave) inválido: \(v)"
                return nil
            }
            return n
        }
        /// Aceita true/false do JSON e "1"/"0"/"true"/"false"/"sim"/"nao" do ambiente.
        func booleano(_ chave: String) -> Bool? {
            guard let v = bruto(chave) else { return nil }
            if JV.ehBool(v) { return (v as? NSNumber)?.boolValue }
            if let n = v as? NSNumber { return n.doubleValue != 0 }
            switch "\(v)".lowercased() {
            case "1", "true", "sim", "s", "yes", "on": return true
            case "0", "false", "nao", "não", "n", "no", "off": return false
            default:
                cfg.erro = cfg.erro ?? "\(chave) inválido: \(v)"
                return nil
            }
        }
        if let u = caminho("logs_dir") { cfg.logsDir = u }
        if let u = caminho("state_dir") { cfg.stateDir = u }
        if let u = caminho("ledger") { cfg.ledger = u }
        if let t = numero("teto_semanal_usd"), t > 0 { cfg.tetoSemanalUSD = t }
        if let v = ambiente["TRANSCENTIA_GASTO_USD_BRL"], let n = Double(v.replacingOccurrences(of: ",", with: ".")), n > 0 {
            cfg.taxaUsdBrl = n
        } else if let t = numero("usd_brl"), t > 0 {
            cfg.taxaUsdBrl = t
        } else if let n = JV.numero(Self.valor("cambio.usd_brl", em: arquivo)), n > 0 {
            cfg.taxaUsdBrl = n
        }
        if let a = numero("aviso_pct") { cfg.avisoPct = a }
        if let u = caminho("opencode_db") { cfg.opencodeDb = u }
        for (k, v) in arquivo {
            if JV.ehBool(v) { cfg.extras[k] = (v as? NSNumber)?.boolValue == true ? "true" : "false" }
            else if let t = v as? String { cfg.extras[k] = t }
            else if let n = v as? NSNumber { cfg.extras[k] = n.stringValue }
        }
        if let u = caminho("copilot_token") { cfg.authCopilot = u }
        if let b = booleano("uso_contas") { cfg.usoContas = b }
        if let l = arquivo["contas"] as? [[String: Any]] {
            cfg.contas = l.compactMap(ContaUso.init(dict:)).filter(\.ativo)
            // FRA-528: uma conta com o nome de uma lane (ex.: `opencode-go`, que mede o mesmo
            // Console do opencode) também habilita a lane, mesmo sem medidor próprio.
            // `ativo: false` tira a conta da medição e da lane. Sem a chave, continua ligada.
            let nomesLane = Set(Agentes.ordem)
            let tiposLane = l.filter(ContasConfig.entradaAtiva)
                .compactMap { $0["tipo"] as? String }
                .filter(nomesLane.contains)
            cfg.lanesHabilitadas = Set(cfg.contas.map(\.tipo)).union(tiposLane)
        }
        cfg.rotuloDono = valor("linear.owner_label", em: arquivo).map { "\($0)" }
        cfg.workspaceLinear = valor("linear.workspace_url", em: arquivo).map { "\($0)" }
        cfg.projetos = ProjetosConfig.ler(arquivo)
        return cfg
    }
}

/// Uma conta mostrada no card de limites. `tipo` diz como medir: claude, grok, cursor, codex, opencode, gemini, copilot.
public struct ContaUso: Equatable, Sendable {
    public var id: String
    public var tipo: String
    public var rotulo: String
    public var nome: String
    public var sigla: String
    /// false = a linha fica no cadastro, fora da medição. Ausente no JSON = true.
    public var ativo: Bool
    /// Usuário do GitHub (Copilot). Não é segredo.
    public var githubUsuario: String
    /// Cota mensal de requisições premium informada pela pessoa. nil = não informada. 0 = sem cota.
    public var cotaPremiumMes: Int?
    /// Caminho opcional do arquivo com o token. O token em si não entra aqui.
    public var arquivoToken: String
    public static let tipos = Agentes.tiposConta
    /// Contas ligadas quando o arquivo ainda não tem a chave `contas`.
    /// Agente com `optIn` (gemini, copilot) fica de fora até a pessoa adicionar em Ajustes › Contas.
    public static var padrao: [ContaUso] {
        todas.filter { !(Agentes.def($0.id)?.optIn ?? false) }
    }
    /// Uma entrada por agente do registry: adicionar lane = aparecer aqui sozinho.
    /// Siglas vêm do `Agentes.Def.sigla` (não mais hardcoded aqui).
    public static var todas: [ContaUso] {
        Agentes.todos.map { a in
            ContaUso(id: a.nome, tipo: a.nome, rotulo: a.rotulo, nome: a.nome,
                     sigla: a.sigla)
        }
    }
    public init(id: String, tipo: String, rotulo: String, nome: String? = nil, sigla: String? = nil,
                ativo: Bool = true, githubUsuario: String = "", cotaPremiumMes: Int? = nil,
                arquivoToken: String = "") {
        self.id = id; self.tipo = tipo; self.rotulo = rotulo
        self.nome = nome ?? id
        self.sigla = sigla ?? String(id.prefix(1)).uppercased()
        self.ativo = ativo
        self.githubUsuario = githubUsuario
        self.cotaPremiumMes = cotaPremiumMes
        self.arquivoToken = arquivoToken
    }
    public init?(dict d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty, let tipo = d["tipo"] as? String, Self.tipos.contains(tipo) else { return nil }
        self.init(id: id, tipo: tipo, rotulo: d["rotulo"] as? String ?? id, nome: d["nome"] as? String,
                  sigla: d["sigla"] as? String, ativo: ContasConfig.ativo(d["ativo"]),
                  githubUsuario: (d["githubUsuario"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                  cotaPremiumMes: ContasConfig.cota(d["cotaPremiumMes"]),
                  arquivoToken: (d["arquivoToken"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
    /// `ativo` só é gravado quando é false, para o arquivo antigo continuar igual.
    /// Segredo nunca entra: token fica no Keychain ou no arquivo apontado.
    public var dict: [String: Any] {
        var item: [String: Any] = ["id": id, "tipo": tipo, "rotulo": rotulo, "nome": nome, "sigla": sigla]
        if !ativo { item["ativo"] = false }
        if tipo == "copilot" {
            if !githubUsuario.isEmpty { item["githubUsuario"] = githubUsuario }
            if let cotaPremiumMes { item["cotaPremiumMes"] = cotaPremiumMes }
            if !arquivoToken.isEmpty { item["arquivoToken"] = arquivoToken }
        }
        return item
    }
}
