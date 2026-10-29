import Foundation

/// Leitores puros do painel. Só leem texto ou bytes. Não criam PAUSE, não gravam `enabled`.
public enum LeitorMedida {
    /// `medida-cache.json` do dispatcher: `{"at": epoch, "m": {"claude": [100, "semana"]}}`.
    /// Percentual ausente fica nil. Arquivo inválido devolve lista vazia.
    public static func ler(dados: Data) -> [MedidaConta] {
        guard let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any],
              let mapa = obj["m"] as? [String: Any] else { return [] }
        var saida: [MedidaConta] = []
        for lane in mapa.keys.sorted() {
            let valor = mapa[lane]
            var pct: Double?
            var janela: String?
            if let par = valor as? [Any] {
                pct = JV.numero(par.first)
                if par.count > 1 { janela = JV.texto(par[1]) }
            } else {
                pct = JV.numero(valor)
            }
            saida.append(MedidaConta(lane: lane, pct: pct, janela: janela))
        }
        return saida
    }
}

public enum LeitorPlanos {
    /// `planos.json`. Aceita `{"claude": "pago"}` ou `{"lanes": {"claude": {"plano": "free"}}}`.
    /// Valor desconhecido não vira pago nem free.
    public static func ler(dados: Data) -> [String: PlanoLane] {
        guard let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else { return [:] }
        let mapa = (obj["lanes"] as? [String: Any]) ?? (obj["planos"] as? [String: Any]) ?? obj
        var saida: [String: PlanoLane] = [:]
        for (chave, valor) in mapa {
            guard LanesPainel.ordem.contains(chave) || Agentes.ordem.contains(chave) else { continue }
            let texto: String?
            if let s = valor as? String {
                texto = s
            } else if let d = valor as? [String: Any] {
                texto = JV.texto(d["plano"]) ?? JV.texto(d["plan"]) ?? JV.texto(d["tipo"]) ?? JV.texto(d["type"])
            } else {
                texto = nil
            }
            if let plano = classificar(texto) { saida[chave] = plano }
        }
        return saida
    }

    static func classificar(_ texto: String?) -> PlanoLane? {
        guard var s = texto?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
        switch s {
        case "pago", "paga", "paid", "pro", "max", "assinatura": return .pago
        case "free", "gratis", "gratuito": return .free
        default: return nil
        }
    }
}

public enum LeitorStrikes {
    /// `opencode-strikes.json`. Sem o arquivo, o montador mostra «sem registro» (não inventa 0/3).
    public static func ler(dados: Data) -> StrikesOpencode? {
        let json = try? JSONSerialization.jsonObject(with: dados)
        if let n = JV.inteiro(json) {
            return StrikesOpencode(atual: max(0, n), limite: nil, motivos: [])
        }
        if let lista = json as? [Any] {
            let motivos = lista.compactMap { JV.texto($0) }
            return StrikesOpencode(atual: motivos.count, limite: nil, motivos: motivos)
        }
        guard let obj = json as? [String: Any] else { return nil }
        let eventos = (obj["eventos"] as? [Any] ?? obj["motivos"] as? [Any] ?? []).compactMap { JV.texto($0) }
        let atual = JV.inteiro(obj["strikes"]) ?? JV.inteiro(obj["atual"]) ?? JV.inteiro(obj["count"]) ?? JV.inteiro(obj["n"]) ?? eventos.count
        let limite = JV.inteiro(obj["max"]) ?? JV.inteiro(obj["limite"]) ?? JV.inteiro(obj["limit"])
        return StrikesOpencode(atual: max(0, atual), limite: limite.map { max(0, $0) }, motivos: eventos)
    }
}

/// Lê o cache de títulos gravado pelo dispatcher (titulos-cache.json).
public enum LeitorTitulosCache {
    public static func ler(pasta: URL) -> [String: String] {
        let arquivo = pasta.appendingPathComponent("titulos-cache.json")
        guard let dados = try? Data(contentsOf: arquivo),
              let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else {
            return [:]
        }
        var saida: [String: String] = [:]
        for (chave, valor) in obj {
            if let titulo = JV.texto(valor) {
                saida[chave] = titulo
            }
        }
        return saida
    }
}

public enum LeitorLogDispatcher {
    /// Trecho do `lanes-dispatcher.log`. Cada linha começa com `AAAA-MM-DD HH:MM:SS`.
    public static func ler(texto: String) -> (decisao: DecisaoDispatcher, fechamentos: [FechamentoLog]) {
        let linhas = parsear(texto)
        let modo = linhas.last { $0.msg.hasPrefix("MODO ") }?.msg
        let decisaoLinhas = linhas.filter { ehDecisao($0.msg) }
        let ancora = decisaoLinhas.last
        let ciclo: [LinhaLog]
        if let ancora, let data = ancora.data {
            ciclo = linhas.filter { linha in
                guard let d = linha.data else { return false }
                return abs(d.timeIntervalSince(data)) <= 3
            }
        } else {
            ciclo = []
        }
        let fila = extrairFila(ciclo.map(\.msg))
        let proxima = extrairProxima(ciclo.map(\.msg))
        let pausa = ciclo.contains { $0.msg.contains("PAUSE presente") }
        let decisao = DecisaoDispatcher(quando: ancora?.quando, fila: fila, proxima: proxima,
                                        modo: modo, pausaNoLog: pausa)
        let fechamentos = linhas.compactMap(fechamento).suffix(60).map { $0 }
        return (decisao, Array(fechamentos))
    }

    static func parsear(_ texto: String) -> [LinhaLog] {
        texto.split(whereSeparator: \.isNewline).compactMap { bruto in
            let linha = String(bruto)
            guard linha.count >= 20 else { return nil }
            let quando = String(linha.prefix(19))
            guard Datas.lerLocal(quando) != nil else { return nil }
            let resto = linha.dropFirst(19).trimmingCharacters(in: .whitespaces)
            let msg = resto.hasPrefix("[SIMULAÇÃO] ") ? String(resto.dropFirst("[SIMULAÇÃO] ".count)) : String(resto)
            return LinhaLog(quando: quando, msg: msg, data: Datas.lerLocal(quando))
        }
    }

    /// Só o bloco que o dispatcher grava junto (`lane:`, `fora:`, `auto:`, `PAUSE`).
    /// Uma linha solta depois, como «limite da conta liberou», não é decisão e não apaga a fila.
    static func ehDecisao(_ msg: String) -> Bool {
        if msg.hasPrefix("PAUSE") || msg.hasPrefix("fora:") || msg.hasPrefix("auto:") { return true }
        guard msg.hasPrefix("lane:") else { return false }
        return msg.contains(" ocupada com ")
            || msg.contains(" livre")
            || msg.contains(" segura ")
            || msg.contains("→ ASSUME ") || msg.contains("-> ASSUME ")
            || msg.contains("→ ASSUMIRIA ") || msg.contains("-> ASSUMIRIA ")
            || msg.contains("aguardando:")
            || msg.contains("limite da conta até")
    }

    static func extrairFila(_ msgs: [String]) -> [String] {
        var vistos: [String] = []
        func acrescentar(_ ids: [String]) {
            for id in ids where !vistos.contains(id) { vistos.append(id) }
        }
        let ocupados = Set(msgs.compactMap { grupos(#"ocupada com (FRA-\d+)"#, $0).first })
        for msg in msgs {
            if let id = grupos(#"ASSUMIRIA (FRA-\d+)"#, msg).first ?? grupos(#"ASSUME (FRA-\d+)"#, msg).first {
                if !ocupados.contains(id) { acrescentar([id]) }
            }
            if let bloco = grupos(#"fila: ([^;)]+)"#, msg).first {
                acrescentar(cards(bloco).filter { !ocupados.contains($0) })
            }
            if let bloco = grupos(#"aguardando: ([^)]+)"#, msg).first {
                acrescentar(cards(bloco))
            }
        }
        return vistos
    }

    static func extrairProxima(_ msgs: [String]) -> String? {
        for msg in msgs.reversed() {
            if let m = primeiro(#"lane:([a-z0-9_-]+) (?:→|->) ASSUME (FRA-\d+)"#, msg)
                ?? primeiro(#"lane:([a-z0-9_-]+) (?:→|->) ASSUMIRIA (FRA-\d+)"#, msg) {
                return "\(m[1]) na \(m[0])"
            }
            if let m = primeiro(#"lane:([a-z0-9_-]+) segura (FRA-\d+)"#, msg) {
                return "segura \(m[1]) na \(m[0])"
            }
        }
        return nil
    }

    static func fechamento(_ linha: LinhaLog) -> FechamentoLog? {
        guard let m = primeiro(#"lane:([a-z0-9_-]+) FECHOU (FRA-\d+)\s*(?:→|->)?\s*(.*)$"#, linha.msg) else {
            return nil
        }
        return FechamentoLog(quando: linha.quando, lane: m[0], card: m[1], resto: m.count > 2 ? m[2] : "")
    }

    static func cards(_ texto: String) -> [String] {
        grupos(#"FRA-\d+"#, texto)
    }

    static func grupos(_ pattern: String, _ texto: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = texto as NSString
        return re.matches(in: texto, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else {
                let r = m.range(at: 0)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let r = m.range(at: 1)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func primeiro(_ pattern: String, _ texto: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = texto as NSString
        let faixa = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: texto, range: faixa), m.numberOfRanges > 1 else { return nil }
        var saida: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            saida.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return saida
    }
}

struct LinhaLog: Equatable {
    var quando: String
    var msg: String
    var data: Date?
}

public enum LeitorBuildInstalada {
    /// Procura `DEVICE INSTALL OK` e `WATCH INSTALL OK` e um sha curto na vizinhança.
    public static func ler(texto: String) -> InstalacoesPainel {
        let linhas = texto.split(whereSeparator: \.isNewline).map(String.init)
        guard !linhas.isEmpty else { return InstalacoesPainel(leu: false, iphone: nil, relogio: nil) }
        return InstalacoesPainel(leu: true,
                                 iphone: sha(linhas, marcador: "DEVICE INSTALL OK"),
                                 relogio: sha(linhas, marcador: "WATCH INSTALL OK"))
    }

    static func sha(_ linhas: [String], marcador: String) -> String? {
        guard let indice = linhas.lastIndex(where: { $0.contains(marcador) }) else { return nil }
        let inicio = max(0, indice - 8)
        let trecho = linhas[inicio...indice].joined(separator: "\n")
        guard let re = try? NSRegularExpression(pattern: #"\b([0-9a-f]{7,12})\b"#) else { return nil }
        let ns = trecho as NSString
        let faixa = NSRange(location: 0, length: ns.length)
        guard let m = re.matches(in: trecho, range: faixa).last, m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

public enum LeitorNomes {
    /// `disabled-by-user`: nomes separados por espaço ou linha. Diretório: um arquivo por lane.
    public static func lanes(texto: String) -> Set<String> {
        let conhecidas = Set(Agentes.ordem)
        return Set(texto.split(whereSeparator: \.isWhitespace).map(String.init).filter { conhecidas.contains($0) })
    }
}

/// Leitura do disco. Abre tudo só para leitura. Não cria arquivo nenhum.
public enum LeitorPainelDisco {
    public static let caudaLog = 256 * 1024
    public static let caudaProva = 400 * 1024

    public static func ler(pasta: URL, logDispatcher: URL, logsDir: URL, agora: Date = Date()) -> EntradaPainel {
        let fm = FileManager.default
        let estado = EstadoLanes.ler(pasta: pasta)
        var titulos: [String: String] = [:]
        var provas: [ProvaBruta] = []
        var pastasLane: [URL] = []
        for lane in estado.lanes {
            if let titulo = lane.titulo, !titulo.isEmpty { titulos[lane.card] = titulo }
            guard let base = pastaLane(lane, pasta: pasta) else { continue }
            pastasLane.append(base)
            if let bruta = provaDaLane(lane, base: base, agora: agora) { provas.append(bruta) }
        }
        // Mesclar com o cache de títulos do dispatcher (FRA-563)
        let cacheTitulos = LeitorTitulosCache.ler(pasta: pasta)
        for (card, titulo) in cacheTitulos {
            if titulos[card] == nil { titulos[card] = titulo }
        }
        provas += provasAntigas(pasta: pasta)
        provas = provas.map { prova in
            guard prova.descricao == nil, let titulo = titulos[prova.card] else { return prova }
            var comTitulo = prova
            comTitulo.descricao = titulo
            return comTitulo
        }

        let habilitadas: Set<String>? = fm.fileExists(atPath: LanesHabilitadas.arquivo(stateDir: pasta).path)
            ? LanesHabilitadas.ler(stateDir: pasta) : nil
        let desligadas = desligadasPeloUsuario(pasta: pasta)
        let pausa = fm.fileExists(atPath: pasta.appendingPathComponent("PAUSE").path)
        let medidas = lerJSON(pasta.appendingPathComponent("medida-cache.json")).map { LeitorMedida.ler(dados: $0) } ?? []
        let planos = lerJSON(pasta.appendingPathComponent("planos.json")).map { LeitorPlanos.ler(dados: $0) } ?? [:]
        let strikes = lerJSON(pasta.appendingPathComponent("opencode-strikes.json")).flatMap { LeitorStrikes.ler(dados: $0) }
        let logTexto = cauda(logDispatcher, maxBytes: caudaLog) ?? ""
        let (decisao, fechamentos) = LeitorLogDispatcher.ler(texto: logTexto)
        let simulador = texto(pasta.appendingPathComponent("simulador"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let instalacoes = buildMaisRecente(logsDir: logsDir)
        let limites = limites(pasta: pasta, agora: agora)
        let config = Configuracao.lerArquivo()
        let cache = ListaModelos.ler(ListaModelos.arquivoCache())
        let modelos = ModeloLane.textosPainel(rodando: estado.lanes, dados: config, cache: cache,
                                              agentes: CatalogoAgentes.carregar())

        return EntradaPainel(
            heartbeat: estado.heartbeat, rodando: estado.lanes, titulos: titulos,
            habilitadas: habilitadas, desligadasPeloUsuario: desligadas, pausa: pausa,
            medidas: medidas, planos: planos, strikes: strikes, decisao: decisao,
            provas: provas, simulador: simulador.flatMap { $0.isEmpty ? nil : $0 },
            instalacoes: instalacoes, limitesAte: limites, logTexto: logTexto,
            fechamentos: fechamentos, textoModelo: modelos.texto, avisoModelo: modelos.aviso,
            pastasLane: pastasLane)
    }

    /// Pasta `.lane` do worktree da lane (`worktree` no `lane-<lane>.json`).
    static func pastaLane(_ lane: EstadoLanes.LaneRodando, pasta: URL) -> URL? {
        guard let dados = lerJSON(pasta.appendingPathComponent("lane-\(lane.lane).json")),
              let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any],
              let worktree = JV.texto(obj["worktree"]) else { return nil }
        return URL(fileURLWithPath: worktree).appendingPathComponent(".lane")
    }

    static func provaDaLane(_ lane: EstadoLanes.LaneRodando, base: URL, agora: Date) -> ProvaBruta? {
        let fm = FileManager.default
        let finalizado = fm.fileExists(atPath: base.appendingPathComponent("finalized").path)
        let agenteSaiu = fm.fileExists(atPath: base.appendingPathComponent("exit_code").path)
        let inicioURL = base.appendingPathComponent("proof_started")
        let saidaURL = base.appendingPathComponent("proof_exit")
        let logURL = base.appendingPathComponent("proof.log")
        let temInicio = fm.fileExists(atPath: inicioURL.path)
        guard temInicio || (agenteSaiu && !finalizado) else { return nil }
        let pedido = texto(inicioURL).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Date(timeIntervalSince1970: $0) }
        let saida = texto(saidaURL).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let esperando = agenteSaiu && !temInicio && !finalizado
        return ProvaBruta(lane: lane.lane, card: lane.card, descricao: lane.titulo, pedidoEm: pedido,
                          log: cauda(logURL, maxBytes: caudaProva) ?? "", saida: saida,
                          esperandoLock: esperando, historico: finalizado)
    }

    static func provasAntigas(pasta: URL, limite: Int = Provas.limiteHistorico) -> [ProvaBruta] {
        let fm = FileManager.default
        let nomes = ((try? fm.contentsOfDirectory(atPath: pasta.path)) ?? [])
            .filter { $0.hasPrefix("stale-proof-") }
        let ordenados = nomes.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: pasta.appendingPathComponent(a).path))?[.modificationDate] as? Date
            let db = (try? fm.attributesOfItem(atPath: pasta.appendingPathComponent(b).path))?[.modificationDate] as? Date
            return (da ?? .distantPast) > (db ?? .distantPast)
        }
        let lidas = ordenados.compactMap { nome -> ProvaBruta? in
            let dir = pasta.appendingPathComponent(nome)
            guard let card = cardArquivado(nome) else { return nil }
            let pedido = texto(dir.appendingPathComponent("proof_started"))
                .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .map { Date(timeIntervalSince1970: $0) }
            let saida = texto(dir.appendingPathComponent("proof_exit"))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return ProvaBruta(lane: "", card: card, descricao: nil, pedidoEm: pedido,
                              log: cauda(dir.appendingPathComponent("proof.log"), maxBytes: caudaProva) ?? "",
                              saida: saida, esperandoLock: false, historico: true)
        }
        return Array(lidas.prefix(max(0, limite)))
    }

    static func cardArquivado(_ nome: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"fra-\d+"#, options: [.caseInsensitive]) else { return nil }
        let ns = nome as NSString
        guard let m = re.firstMatch(in: nome, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range).uppercased()
    }

    static func desligadasPeloUsuario(pasta: URL) -> Set<String> {
        let fm = FileManager.default
        let arquivo = pasta.appendingPathComponent("disabled-by-user")
        var ehPasta: ObjCBool = false
        guard fm.fileExists(atPath: arquivo.path, isDirectory: &ehPasta) else { return [] }
        if ehPasta.boolValue {
            let nomes = (try? fm.contentsOfDirectory(atPath: arquivo.path)) ?? []
            return LeitorNomes.lanes(texto: nomes.joined(separator: " "))
        }
        return LeitorNomes.lanes(texto: texto(arquivo) ?? "")
    }

    static func limites(pasta: URL, agora: Date) -> [String: Date] {
        let fm = FileManager.default
        let nomes = ((try? fm.contentsOfDirectory(atPath: pasta.path)) ?? [])
            .filter { $0.hasPrefix("limite-") && $0.hasSuffix(".json") }
        var saida: [String: Date] = [:]
        for nome in nomes {
            let lane = String(nome.dropFirst("limite-".count).dropLast(".json".count))
            guard let dados = lerJSON(pasta.appendingPathComponent(nome)),
                  let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any],
                  let until = JV.numero(obj["until"]) else { continue }
            let data = Date(timeIntervalSince1970: until)
            if data > agora { saida[lane] = data }
        }
        return saida
    }

    static func buildMaisRecente(logsDir: URL) -> InstalacoesPainel {
        let pasta = logsDir.deletingLastPathComponent()
        let fm = FileManager.default
        let nomes = ((try? fm.contentsOfDirectory(atPath: pasta.path)) ?? [])
            .filter { $0.hasPrefix("device-build-") && $0.hasSuffix(".log") }
        guard let recente = nomes.max(by: { a, b in
            let da = (try? fm.attributesOfItem(atPath: pasta.appendingPathComponent(a).path))?[.modificationDate] as? Date
            let db = (try? fm.attributesOfItem(atPath: pasta.appendingPathComponent(b).path))?[.modificationDate] as? Date
            return (da ?? .distantPast) < (db ?? .distantPast)
        }) else { return InstalacoesPainel(leu: false, iphone: nil, relogio: nil) }
        let texto = cauda(pasta.appendingPathComponent(recente), maxBytes: caudaLog) ?? ""
        return LeitorBuildInstalada.ler(texto: texto)
    }

    static func lerJSON(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return try? h.readToEnd()
    }

    static func texto(_ url: URL) -> String? {
        guard let dados = lerJSON(url) else { return nil }
        return String(data: dados, encoding: .utf8)
    }

    static func cauda(_ url: URL, maxBytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let tamanho = (try? h.seekToEnd()) ?? 0
        let inicio: UInt64 = tamanho > UInt64(maxBytes) ? tamanho - UInt64(maxBytes) : 0
        try? h.seek(toOffset: inicio)
        guard let dados = try? h.readToEnd(), let texto = String(data: dados, encoding: .utf8) else { return nil }
        if inicio > 0, let quebra = texto.firstIndex(of: "\n") {
            return String(texto[texto.index(after: quebra)...])
        }
        return texto
    }
}
