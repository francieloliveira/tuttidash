import Foundation

/// Última lista boa de modelos, no mesmo arquivo que o dispatcher lê
/// (`~/Library/Application Support/TuttiDash/modelos-cache.json`, reserva na pasta Lanekeeper).
public struct CacheModelos: Equatable, Sendable {
    public var atualizadoEm: String
    public var listas: [String: [String]]
    public var anteriores: [String: [String]]
    /// FRA-564: quando cada lane teve lista boa pela última vez. Lane que falhou não ganha selo,
    /// então o dispatcher tenta de novo. `atualizadoEm` fica como a última tentativa.
    public var porLane: [String: String]

    public init(atualizadoEm: String, listas: [String: [String]], anteriores: [String: [String]],
                porLane: [String: String] = [:]) {
        self.atualizadoEm = atualizadoEm
        self.listas = listas
        self.anteriores = anteriores
        self.porLane = porLane
    }

    public static let vazio = CacheModelos(atualizadoEm: "", listas: [:], anteriores: [:])
}

/// Lista de uma ferramenta e, quando veio vazia, o motivo para a tela (FRA-564).
public struct ResultadoLista: Equatable, Sendable {
    public var modelos: [String]
    public var motivo: String?

    public init(modelos: [String], motivo: String? = nil) {
        self.modelos = modelos
        self.motivo = modelos.isEmpty ? motivo : nil
    }

    public static func ok(_ modelos: [String]) -> ResultadoLista { ResultadoLista(modelos: modelos) }
    public static func falha(_ motivo: String) -> ResultadoLista { ResultadoLista(modelos: [], motivo: motivo) }
}

/// Lista viva: `opencode models`, `grok models`, API oficial do Claude (`ANTHROPIC_API_KEY`) e a
/// lista que o Codex CLI guarda em `~/.codex/models_cache.json` (ou a API com `OPENAI_API_KEY`).
/// Campo de texto livre fica na tela. Falha de rede não apaga a lista anterior.
public enum ListaModelos {
    public static func arquivoCache(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let novo = Configuracao.pastaApp(home: home).appendingPathComponent("modelos-cache.json")
        let antigo = home.appendingPathComponent(Legado.pastaLanekeeper).appendingPathComponent("modelos-cache.json")
        return FileManager.default.fileExists(atPath: novo.path) || !FileManager.default.fileExists(atPath: antigo.path)
            ? novo : antigo
    }

    public static func selo(_ data: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: data)
    }

    /// `soItens`: só linhas de lista (`*` ou `-`). O `grok models` abre com frases
    /// ("You are logged in…", "Default model: …") que viravam `You` e `Default` (FRA-564).
    public static func linhas(_ texto: String, soItens: Bool = false) -> [String] {
        var saida: [String] = []
        for bruto in texto.split(whereSeparator: \.isNewline) {
            var s = bruto.trimmingCharacters(in: .whitespaces)
            if soItens && !(s.hasPrefix("-") || s.hasPrefix("*")) { continue }
            if s.hasPrefix("-") || s.hasPrefix("*") { s.removeFirst() }
            s = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if s.isEmpty || s.hasSuffix(":") { continue }
            let tok = String(s.split(whereSeparator: \.isWhitespace).first ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "`,"))
            if pareceId(tok) { saida.append(tok) }
        }
        return saida
    }

    /// Prefixo da lane e, no OpenCode, só o que `pode` aceita. Sem `pode`, o OpenCode fica de fora.
    public static func filtrar(lane: String, linhas: [String], prefixo: String, privado: Bool,
                               pode: ((String) -> Bool)?) -> [String] {
        var saida: [String] = []
        var vistos = Set<String>()
        for tok in linhas {
            var modelo = tok
            if !prefixo.isEmpty {
                if !modelo.contains("/") { modelo = prefixo + modelo }
                if !modelo.hasPrefix(prefixo) { continue }
            }
            if privado {
                guard let pode else { continue }
                if !pode(modelo) { continue }
            }
            if vistos.insert(modelo).inserted { saida.append(modelo) }
        }
        return saida
    }

    /// Lista vazia não substitui a anterior. Lista nova guarda a que estava, para detectar sumiço.
    public static func aplicar(_ cache: CacheModelos, lane: String, modelos: [String], agora: String) -> CacheModelos {
        var saida = cache
        if !modelos.isEmpty {
            if let antiga = saida.listas[lane], !antiga.isEmpty {
                saida.anteriores[lane] = antiga
            }
            saida.listas[lane] = modelos
            if !agora.isEmpty { saida.porLane[lane] = agora }
        }
        if !agora.isEmpty { saida.atualizadoEm = agora }
        return saida
    }

    public static func ler(_ url: URL) -> CacheModelos {
        guard let dados = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return .vazio }
        var porLane: [String: String] = [:]
        for (lane, selo) in (obj["atualizado_em_por_lane"] as? [String: Any]) ?? [:] {
            if let selo = selo as? String { porLane[lane] = selo }
        }
        return CacheModelos(atualizadoEm: (obj["atualizado_em"] as? String) ?? "",
                            listas: mapa(obj["listas"]), anteriores: mapa(obj["anteriores"]),
                            porLane: porLane)
    }

    public static func gravar(_ cache: CacheModelos, em url: URL) throws {
        let obj: [String: Any] = [
            "atualizado_em": cache.atualizadoEm,
            "listas": cache.listas,
            "anteriores": cache.anteriores,
            "atualizado_em_por_lane": cache.porLane,
        ]
        let dados = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dados.write(to: url, options: .atomic)
    }

    public struct Pedido: Equatable, Sendable {
        public var lane: String
        public var prefixo: String
        public var privado: Bool
        public init(lane: String, prefixo: String, privado: Bool) {
            self.lane = lane
            self.prefixo = prefixo
            self.privado = privado
        }
    }

    /// Cache novo e, por lane, o motivo de a lista não ter vindo (a tela mostra).
    public struct Atualizacao: Equatable, Sendable {
        public var cache: CacheModelos
        public var motivos: [String: String]
    }

    /// Atualiza ao abrir os Ajustes. O dispatcher repete as lanes sem lista do dia.
    /// `rodar` devolve a saída do comando, ou nil se ele falhou.
    public static func atualizar(_ pedidos: [Pedido], cache: CacheModelos, agora: String,
                                 rodar: (String) -> String?,
                                 claude: () -> ResultadoLista, codex: () -> ResultadoLista,
                                 pode: ([String]) -> [String: Bool]?) -> Atualizacao {
        var saida = cache
        var motivos: [String: String] = [:]
        var textoOpencode: String?
        var jaOpencode = false
        for pedido in pedidos {
            let r: ResultadoLista
            switch pedido.lane {
            case "opencode", "opencode-go":
                if !jaOpencode {
                    textoOpencode = rodar("opencode")
                    jaOpencode = true
                }
                guard let texto = textoOpencode else {
                    motivos[pedido.lane] = String(localized: "O comando «opencode models» não respondeu. Vale a última lista boa.")
                    continue
                }
                let brutos = filtrar(lane: pedido.lane, linhas: linhas(texto), prefixo: pedido.prefixo,
                                     privado: false, pode: nil)
                guard let mapa = pode(brutos) else {
                    motivos[pedido.lane] = String(localized: "Não deu para conferir a privacidade dos modelos. Vale a última lista boa.")
                    continue
                }
                r = ResultadoLista(modelos: brutos.filter { mapa[$0] == true },
                                   motivo: String(localized: "Nenhum modelo do OpenCode passou na regra de privacidade."))
            case "grok":
                guard let texto = rodar("grok") else {
                    motivos[pedido.lane] = String(localized: "O comando «grok models» não respondeu. Vale a última lista boa.")
                    continue
                }
                r = ResultadoLista(modelos: filtrar(lane: pedido.lane, linhas: linhas(texto, soItens: true),
                                                    prefixo: pedido.prefixo, privado: false, pode: nil),
                                   motivo: String(localized: "O «grok models» não trouxe nenhum modelo."))
            case "claude":
                r = claude()
            case "codex":
                r = codex()
            default:
                continue
            }
            if let motivo = r.motivo { motivos[pedido.lane] = motivo }
            saida = aplicar(saida, lane: pedido.lane, modelos: r.modelos, agora: agora)
        }
        if saida.atualizadoEm.isEmpty { saida.atualizadoEm = agora }
        return Atualizacao(cache: saida, motivos: motivos)
    }

    /// Conferência real, fora do teste. Não chamar na thread da interface: espera o CLI.
    public static func atualizarNoMac(pedidos: [Pedido], cache: CacheModelos,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Atualizacao {
        let agora = selo()
        return atualizar(pedidos, cache: cache, agora: agora,
                         rodar: { cli in saida(de: [cli, "models"]) },
                         claude: { modelosClaude(home: home) },
                         codex: { modelosCodex(home: home) },
                         pode: { privacidade($0, home: home) })
    }

    /// `~/.codex/models_cache.json`, a lista que o próprio Codex CLI usa: só `visibility == "list"`
    /// (sem os ocultos), na ordem de `priority`. nil = arquivo ilegível.
    public static func modelosCacheCodex(_ dados: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let lista = obj["models"] as? [Any] else { return nil }
        var itens: [(prioridade: Int, ordem: Int, slug: String)] = []
        for (ordem, item) in lista.enumerated() {
            guard let m = item as? [String: Any], let slug = m["slug"] as? String, pareceId(slug) else { continue }
            if let visivel = m["visibility"] as? String, visivel != "list" { continue }
            let prioridade = (m["priority"] as? NSNumber)?.intValue ?? Int.max
            itens.append((prioridade, ordem, slug))
        }
        var vistos = Set<String>()
        return itens.sorted { ($0.prioridade, $0.ordem) < ($1.prioridade, $1.ordem) }
            .map(\.slug).filter { vistos.insert($0).inserted }
    }

    /// Resposta HTTP vira lista ou motivo. 401/403 = login vencido.
    public static func resultado(_ resposta: (status: Int?, dados: Data?), ferramenta: String, vencido: String) -> ResultadoLista {
        guard let status = resposta.status else {
            return .falha(String(localized: "\(ferramenta) não respondeu. Vale a última lista boa."))
        }
        if status == 401 || status == 403 { return .falha(vencido) }
        guard (200..<300).contains(status) else {
            return .falha(String(localized: "\(ferramenta) respondeu \(status). Vale a última lista boa."))
        }
        let modelos = ids(de: resposta.dados)
        return modelos.isEmpty ? .falha(String(localized: "\(ferramenta) não trouxe nenhum modelo.")) : .ok(modelos)
    }

    static func pareceId(_ s: String) -> Bool {
        guard let primeiro = s.first, primeiro.isLetter || primeiro.isNumber else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || "._:/-".contains($0) }
    }

    private static func mapa(_ valor: Any?) -> [String: [String]] {
        guard let d = valor as? [String: Any] else { return [:] }
        var saida: [String: [String]] = [:]
        for (chave, item) in d {
            if let lista = item as? [String] {
                saida[chave] = lista
            } else if let lista = item as? [Any] {
                saida[chave] = lista.compactMap { $0 as? String }
            }
        }
        return saida
    }

    private static func saida(de argv: [String]) -> String? {
        guard let dados = executar(URL(fileURLWithPath: "/usr/bin/env"), argv, entrada: nil, limite: 12,
                                   ambienteExtra: true),
              let texto = String(data: dados, encoding: .utf8) else { return nil }
        return texto
    }

    /// nil = o Python da privacidade não rodou; a lista do OpenCode não é trocada.
    static func privacidade(_ modelos: [String], home: URL) -> [String: Bool]? {
        guard !modelos.isEmpty else { return [:] }
        let casas = [
            home.appendingPathComponent(".transcentia/lanes").path,
            home.appendingPathComponent(".transcentia/tools").path,
        ].joined(separator: ":")
        let script = """
        import json, sys
        for p in sys.argv[1].split(":"):
            if p and p not in sys.path:
                sys.path.insert(0, p)
        import privacidade
        nomes = json.load(sys.stdin)
        print(json.dumps({m: bool(privacidade.pode_receber_codigo(m)[0]) for m in nomes}))
        """
        guard let entrada = try? JSONSerialization.data(withJSONObject: modelos),
              let saida = rodarPython(script, argumentos: [casas], entrada: entrada),
              let obj = try? JSONSerialization.jsonObject(with: saida) as? [String: Any] else { return nil }
        var mapa: [String: Bool] = [:]
        for (nome, valor) in obj { mapa[nome] = JV.verdadeiro(valor) }
        return mapa
    }

    private static func rodarPython(_ script: String, argumentos: [String], entrada: Data) -> Data? {
        executar(URL(fileURLWithPath: "/usr/bin/python3"), ["-c", script] + argumentos, entrada: entrada,
                 limite: 20, ambienteExtra: false)
    }

    /// Saída em arquivo temporário: um pipe cheio travaria o processo.
    private static func executar(_ exe: URL, _ args: [String], entrada: Data?, limite: TimeInterval,
                                 ambienteExtra: Bool) -> Data? {
        let destino = FileManager.default.temporaryDirectory.appendingPathComponent("modelos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destino) }
        guard FileManager.default.createFile(atPath: destino.path, contents: nil),
              let saida = try? FileHandle(forWritingTo: destino) else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if ambienteExtra {
            var ambiente = ProcessInfo.processInfo.environment
            ambiente["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (ambiente["PATH"] ?? "")
            p.environment = ambiente
        }
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        let dentro = Pipe()
        if entrada != nil { p.standardInput = dentro }
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch {
            try? saida.close()
            return nil
        }
        if let entrada {
            dentro.fileHandleForWriting.write(entrada)
            try? dentro.fileHandleForWriting.close()
        }
        if sem.wait(timeout: .now() + limite) == .timedOut {
            p.terminate()
            try? saida.close()
            return nil
        }
        try? saida.close()
        guard p.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: destino)
    }

    /// Lista do Claude pela API oficial, com `ANTHROPIC_API_KEY`. Sem a chave, uma fonte extra
    /// registrada (`ListasExtras`) pode responder; sem nenhuma, fica a última lista boa.
    static func modelosClaude(home: URL, ambiente: [String: String] = ProcessInfo.processInfo.environment) -> ResultadoLista {
        let chave = ambiente["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chave.isEmpty {
            var req = pedidoClaude()
            req.setValue(chave, forHTTPHeaderField: "x-api-key")
            return resultado(sincrono(req), ferramenta: "Claude",
                             vencido: String(localized: "A ANTHROPIC_API_KEY foi recusada. Confira a chave e reabra os Ajustes."))
        }
        if let extra = ListasExtras.fonte("claude"), let r = extra(home) { return r }
        return .falha(String(localized: "Defina ANTHROPIC_API_KEY para listar os modelos do Claude. Vale a última lista boa."))
    }

    public static func pedidoClaude() -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
        req.timeoutInterval = 8
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    /// Uma fonte só: com `models_cache.json` do Codex CLI, só ele (fontes diferentes dariam falso
    /// "saiu da lista"). Sem o arquivo, a API oficial com `OPENAI_API_KEY`, ou uma fonte extra.
    static func modelosCodex(home: URL, ambiente: [String: String] = ProcessInfo.processInfo.environment) -> ResultadoLista {
        if let dados = try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")),
           let modelos = modelosCacheCodex(dados) {
            return modelos.isEmpty
                ? .falha(String(localized: "A lista que o Codex guarda está vazia. Rode o codex uma vez e reabra os Ajustes."))
                : .ok(modelos)
        }
        let chave = ambiente["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chave.isEmpty {
            return resultado(sincrono(pedidoOpenAI(chave)), ferramenta: "OpenAI",
                             vencido: String(localized: "A OPENAI_API_KEY foi recusada. Confira a chave e reabra os Ajustes."))
        }
        if let extra = ListasExtras.fonte("codex"), let r = extra(home) { return r }
        return .falha(String(localized: "Rode o codex uma vez (ele guarda a lista) ou defina OPENAI_API_KEY. Vale a última lista boa."))
    }

    public static func pedidoOpenAI(_ tok: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.timeoutInterval = 8
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// status nil = sem resposta (rede ou tempo esgotado).
    public static func sincrono(_ req: URLRequest) -> (status: Int?, dados: Data?) {
        let sem = DispatchSemaphore(value: 0)
        let caixa = CaixaResposta()
        let tarefa = URLSession.shared.dataTask(with: req) { corpo, resp, _ in
            caixa.status = (resp as? HTTPURLResponse)?.statusCode
            caixa.dados = corpo
            sem.signal()
        }
        tarefa.resume()
        if sem.wait(timeout: .now() + 8) == .timedOut {
            tarefa.cancel()
            return (nil, nil)
        }
        return (caixa.status, caixa.dados)
    }

    private final class CaixaResposta: @unchecked Sendable {
        var status: Int?
        var dados: Data?
    }

    private static func ids(de dados: Data?) -> [String] {
        guard let dados, let json = try? JSONSerialization.jsonObject(with: dados) else { return [] }
        let blocos: [Any]
        if let d = json as? [String: Any] {
            blocos = (d["data"] as? [Any]) ?? (d["models"] as? [Any]) ?? (d["items"] as? [Any]) ?? []
        } else if let lista = json as? [Any] {
            blocos = lista
        } else {
            blocos = []
        }
        var saida: [String] = []
        var vistos = Set<String>()
        for item in blocos {
            let modelo: String?
            if let s = item as? String {
                modelo = s
            } else if let d = item as? [String: Any] {
                modelo = (d["id"] as? String) ?? (d["slug"] as? String) ?? (d["model"] as? String)
            } else {
                modelo = nil
            }
            guard let modelo, pareceId(modelo), vistos.insert(modelo).inserted else { continue }
            saida.append(modelo)
        }
        return saida
    }
}

/// Listas de modelos de outras fontes, registradas por um módulo à parte (FRA-565). Cada uma
/// recebe a home e devolve nil quando não tem como responder (vale a mensagem padrão).
public enum ListasExtras {
    public typealias Fonte = @Sendable (URL) -> ResultadoLista?
    private static let trava = NSLock()
    nonisolated(unsafe) private static var fontes: [String: Fonte] = [:]

    public static func registrar(lane: String, _ fonte: @escaping Fonte) {
        trava.lock(); defer { trava.unlock() }
        fontes[lane] = fonte
    }

    public static func fonte(_ lane: String) -> Fonte? {
        trava.lock(); defer { trava.unlock() }
        return fontes[lane]
    }
}
