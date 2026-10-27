import Foundation

/// Leitura de um log de execução de lane, só leitura. Porta fiel do `gasto_lanes/parser.py`.
///
/// Nome: `<CARD>-<lane>-<AAAAMMDD-HHMMSS>.jsonl` (ex.: `FRA-259-grok-20261004-153012.jsonl`).
/// Conteúdo: stream JSON por linha (claude `stream-json`, grok `streaming-messages-json`);
/// fecha com `type=result`. Linhas que não são JSON (stderr) são ignoradas.
public enum ParserLog {
    public struct Nome: Equatable, Sendable {
        public var id: String
        public var card: String
        public var lane: String
        public var inicio: String
        public var dia: String
        public var semana: String
        public var dataInicio: Date
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"^([A-Za-z][A-Za-z0-9]*-\d+)-([a-z][a-z0-9_-]*)-(\d{8})-(\d{6})\.jsonl$"#)

    public static func lerNome(_ nome: String, calendario: Calendar = Datas.calendarioISO) -> Nome? {
        let ns = nome as NSString
        guard let m = regex.firstMatch(in: nome, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let card = ns.substring(with: m.range(at: 1)).uppercased()
        let lane = ns.substring(with: m.range(at: 2))
        let ymd = ns.substring(with: m.range(at: 3))
        let hms = ns.substring(with: m.range(at: 4))
        func parte(_ s: String, _ i: Int, _ n: Int) -> String {
            let a = s.index(s.startIndex, offsetBy: i)
            return String(s[a..<s.index(a, offsetBy: n)])
        }
        let dia = "\(parte(ymd, 0, 4))-\(parte(ymd, 4, 2))-\(parte(ymd, 6, 2))"
        let hora = "\(parte(hms, 0, 2)):\(parte(hms, 2, 2)):\(parte(hms, 4, 2))"
        guard let h = Int(parte(hms, 0, 2)), h < 24, let mi = Int(parte(hms, 2, 2)), mi < 60,
              let se = Int(parte(hms, 4, 2)), se < 60,
              let data = Datas.lerLocal("\(dia)T\(hora)", calendario: calendario) else { return nil }
        return Nome(id: String(nome.dropLast(".jsonl".count)), card: card, lane: lane,
                    inicio: "\(dia)T\(hora)", dia: dia,
                    semana: Datas.rotuloSemana(data, calendario: calendario), dataInicio: data)
    }

    /// Soma de tokens de um `usage` (formato Messages). Tudo zero = desconhecido (nil).
    static func tokensTotal(_ usage: Any?) -> Int? {
        guard let u = usage as? [String: Any] else { return nil }
        let chaves = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let total = chaves.reduce(0) { $0 + (JV.inteiro(u[$1]) ?? 0) }
        return total > 0 ? total : nil
    }

    /// (custo ou nil, tipo). Zero, ausente ou parcial = desconhecido, nunca "grátis".
    /// Catálogo multi-agente: fonte única em `Agentes` (FRA-373, porta do `parser.py`).
    public static func classificarCusto(lane: String, result: [String: Any]?) -> (Double?, TipoCusto) {
        guard let r = result else { return (nil, .desconhecido) }
        if JV.verdadeiro(r["cost_is_partial"]) || JV.verdadeiro(r["usage_is_incomplete"]) {
            return (nil, .desconhecido)
        }
        guard let c = JV.numero(r["total_cost_usd"]), c > 0 else { return (nil, .desconhecido) }
        return (c, Agentes.custoEstimado.contains(lane) ? .estimado : .informado)
    }

    /// Lê o log em `url`. `emAndamento` = nomes de log que um `lane-<lane>.json` aponta agora.
    public static func ler(url: URL, emAndamento: Set<String> = [],
                           calendario: Calendar = Datas.calendarioISO) throws -> Execucao? {
        guard let meta = lerNome(url.lastPathComponent, calendario: calendario) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let tamanho = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let handle = try FileHandle(forReadingFrom: url)   // só leitura
        defer { try? handle.close() }
        let dados = try handle.readToEnd() ?? Data()
        return interpretar(dados: dados, meta: meta, nomeArquivo: url.lastPathComponent,
                           emAndamento: emAndamento, mtime: mtime, tamanho: tamanho)
    }

    /// Núcleo puro (testável sem disco).
    public static func interpretar(dados: Data, meta: Nome, nomeArquivo: String, emAndamento: Set<String>,
                                   mtime: Date, tamanho: Int) -> Execucao {
        var result: [String: Any]?
        var respostas: [String: Int] = [:]   // message.id -> tokens (a mesma mensagem repete por bloco)
        var anon = 0
        var outro = FormatoOutro()

        for linha in dados.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let ev = JV.objeto(Data(linha)) else { continue }   // não-JSON / não-objeto: ignora
            let tipo = ev["type"] as? String
            if tipo == "assistant" {
                let pai = ev["parent_tool_use_id"]
                let semPai = pai == nil || pai is NSNull || (pai as? String) == ""
                guard semPai else { continue }
                let msg = ev["message"] as? [String: Any] ?? [:]
                let toks = tokensTotal(msg["usage"]) ?? 0
                if let mid = msg["id"] as? String, !mid.isEmpty {
                    respostas[mid] = toks
                } else {
                    anon += 1
                    respostas["_anon\(anon)"] = toks
                }
            } else if tipo == "result" {
                result = ev   // vale a última
            } else if let tipo {
                outro.ver(tipo: tipo, ev: ev)
            }
        }

        var ex = Execucao(id: meta.id, card: meta.card, lane: meta.lane, inicio: meta.inicio, dia: meta.dia,
                          semana: meta.semana, status: .morta)
        if let r = result {
            let subtipo = r["subtype"] as? String
            let erros = (r["errors"] as? [Any] ?? []).map { "\($0)" }
            var erro = JV.verdadeiro(r["is_error"]) || (subtipo?.hasPrefix("error") ?? false)
            if erros.contains("cancelled") || (r["stop_reason"] as? String) == "cancelled" { erro = true }
            let cancelada = erros.contains("cancelled") || (r["stop_reason"] as? String) == "cancelled"
            ex.status = cancelada ? .cancelada : (erro ? .erro : .ok)
            ex.subtipo = subtipo
            ex.erros = Array(erros.prefix(5))
            ex.turnos = JV.inteiro(r["num_turns"])
            if let d = JV.inteiro(r["duration_ms"]), d > 0 { ex.duracaoMs = d }
            ex.tokensTotal = tokensTotal(r["usage"])
        } else if let fim = outro.status(rodando: emAndamento.contains(nomeArquivo)) {
            // opencode / codex (FRA-528): não têm a linha `result` do Claude.
            ex.status = fim
            ex.erros = Array(outro.erros.prefix(5))
            ex.tokensTotal = outro.tokens > 0 ? outro.tokens : nil
        } else {
            ex.status = emAndamento.contains(nomeArquivo) ? .emAndamento : .morta
            ex.respostasParciais = respostas.count
            let soma = respostas.values.reduce(0, +)
            ex.tokensTotal = soma > 0 ? soma : nil
        }
        (ex.custoUSD, ex.custo) = result == nil && outro.formato != nil
            ? outro.custo(lane: meta.lane) : classificarCusto(lane: meta.lane, result: result)
        if ex.duracaoMs == nil {
            let delta = mtime.timeIntervalSince(meta.dataInicio)
            if delta > 0 { ex.duracaoEstimadaMs = Int(delta * 1000) }
        }
        ex.fonte = Fonte(tamanho: tamanho, mtime: (mtime.timeIntervalSince1970 * 1000).rounded() / 1000)
        return ex
    }
}

/// Logs do opencode (`step_start`/`step_finish`/`text`/`tool_use`/`error`) e do codex
/// (`thread.started`/`turn.completed`/`turn.failed`/`error`). Mesmas regras do `parser.py`.
struct FormatoOutro {
    enum Formato { case opencode, codex }
    var formato: Formato?
    var ultimo: String?
    var ultimoMotivo: String?
    var erros: [String] = []
    var cancelou = false
    var concluiu = false
    var custoSoma = 0.0
    var tokens = 0

    static let tiposOpencode: Set<String> = ["step_start", "step_finish", "text", "tool_use", "reasoning"]

    mutating func ver(tipo: String, ev: [String: Any]) {
        if Self.tiposOpencode.contains(tipo) { formato = .opencode }
        if tipo.hasPrefix("thread.") || tipo.hasPrefix("turn.") || tipo.hasPrefix("item.") { formato = .codex }
        switch tipo {
        case "error", "turn.failed":
            if formato == nil { formato = ev["sessionID"] != nil ? .opencode : .codex }
            let e = ev["error"] as? [String: Any]
            let msg = (e?["message"] as? String) ?? (e?["name"] as? String) ?? (ev["message"] as? String) ?? tipo
            let nome = ((e?["name"] as? String) ?? "") + " " + msg
            if nome.localizedCaseInsensitiveContains("abort") || nome.localizedCaseInsensitiveContains("cancel") {
                cancelou = true
            }
            erros.append(String(msg.prefix(200)))
        case "turn.completed":
            concluiu = true
            if let u = ev["usage"] as? [String: Any] {
                tokens += (JV.inteiro(u["input_tokens"]) ?? 0) + (JV.inteiro(u["output_tokens"]) ?? 0)
            }
        case "step_finish":
            let part = ev["part"] as? [String: Any] ?? [:]
            ultimoMotivo = part["reason"] as? String
            if let c = JV.numero(part["cost"]), c > 0 { custoSoma += c }
            if let t = part["tokens"] as? [String: Any] {
                let cache = t["cache"] as? [String: Any] ?? [:]
                tokens += ["input", "output", "reasoning"].reduce(0) { $0 + (JV.inteiro(t[$1]) ?? 0) }
                tokens += (JV.inteiro(cache["read"]) ?? 0) + (JV.inteiro(cache["write"]) ?? 0)
            }
        default: break
        }
        ultimo = tipo
    }

    /// nil = não é log de opencode/codex (segue a regra do Claude).
    func status(rodando: Bool) -> StatusExecucao? {
        guard let formato else { return nil }
        if cancelou { return .cancelada }
        if !erros.isEmpty { return .erro }
        if rodando { return .emAndamento }
        switch formato {
        case .codex: return concluiu ? .ok : .morta
        case .opencode:
            // A última fala do agente é um `text` (ou um passo que parou com `stop`).
            // Se o log acaba num `tool_use`/`step_start`, o processo sumiu no meio.
            if ultimo == "text" || (ultimo == "step_finish" && ultimoMotivo == "stop") { return .ok }
            return .morta
        }
    }

    func custo(lane: String) -> (Double?, TipoCusto) {
        if custoSoma > 0 { return (custoSoma, .informado) }
        switch formato {
        case .codex: return (0, .plano)
        case .opencode: return lane == "opencode" ? (0, .gratis) : (0, .plano)
        case nil: return (nil, .desconhecido)
        }
    }
}
