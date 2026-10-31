import Foundation

/// Caixa do dono (PRD de 29/10): os cards com a etiqueta do dono, como o vigia grava em
/// `~/.transcentia/lanes/caixa-dono.json`, e as ações que o app faz no Linear com um clique.
/// O arquivo só traz o que a tela mostra. No clique o app resolve o issue pelo identifier
/// e usa os ids do cache/config (FRA-601), com o token já compartilhado (FRA-568).
public struct AcaoCaixa: Equatable, Sendable {
    public enum Tipo: String, Sendable { case esforco, lane, cancelar }
    public var tipo: Tipo
    public var valor: String
    public init(tipo: Tipo, valor: String) { self.tipo = tipo; self.valor = valor }
}

public struct OpcaoCaixa: Equatable, Sendable, Identifiable {
    public var letra: String
    public var texto: String
    public var acao: AcaoCaixa?
    public var id: String { letra }
    public init(letra: String, texto: String, acao: AcaoCaixa? = nil) {
        self.letra = letra; self.texto = texto; self.acao = acao
    }
}

public struct ItemCaixa: Equatable, Sendable, Identifiable {
    /// Identifier do Linear (FRA-123). É o que a tela mostra; o uuid não vem do arquivo.
    public var card: String
    public var titulo: String
    public var url: String
    public var desde: Date?
    /// Quem chamou o dono: lane, triagem, gestor ou dono.
    public var origem: String
    public var motivo: String
    /// Muda quando a pergunta muda: o contador e o aviso do macOS contam por ela.
    public var perguntaId: String
    public var pendencia: String
    public var opcoes: [OpcaoCaixa]
    public var recomenda: String
    public var porque: String
    public var esforco: String
    public var lane: String
    /// Outras etiquetas que seguram o card (`lane:falhou`, `lane:parada`).
    public var outrasTravas: [String]
    public var id: String { card }

    public init(card: String, titulo: String = "", url: String = "", desde: Date? = nil,
                origem: String = "dono", motivo: String = "", perguntaId: String = "", pendencia: String = "",
                opcoes: [OpcaoCaixa] = [], recomenda: String = "", porque: String = "",
                esforco: String = "", lane: String = "", outrasTravas: [String] = []) {
        self.card = card; self.titulo = titulo; self.url = url; self.desde = desde
        self.origem = origem; self.motivo = motivo; self.perguntaId = perguntaId.isEmpty ? card : perguntaId
        self.pendencia = pendencia; self.opcoes = opcoes; self.recomenda = recomenda; self.porque = porque
        self.esforco = esforco; self.lane = lane; self.outrasTravas = outrasTravas
    }
}

/// Issue que o Linear devolveu agora, pelo identifier. O `id` é o uuid da API, nunca o do arquivo.
public struct IssueResolvida: Equatable, Sendable {
    public var id: String
    public var identifier: String
    public var etiquetas: [String]
    /// Estado `canceled` do time deste issue, se a consulta trouxe. Vazio se não veio.
    public var estadoCancelado: String
    public init(id: String, identifier: String, etiquetas: [String] = [], estadoCancelado: String = "") {
        self.id = id; self.identifier = identifier; self.etiquetas = etiquetas; self.estadoCancelado = estadoCancelado
    }
}

public enum ResultadoResolucao: Equatable, Sendable {
    case pronta(IssueResolvida)
    case ausente
    case semEtiquetaDono
}

/// IDs de etiqueta e de estado da config e do cache `linear-ids` (a mesma ordem do vigia).
/// Nunca saem do `caixa-dono.json`.
public struct IdsCaixa: Equatable, Sendable {
    public var dono: String
    public var esforco: [String: String]
    public var lanes: [String: String]
    public var cancelado: String
    public init(dono: String = "", esforco: [String: String] = [:], lanes: [String: String] = [:], cancelado: String = "") {
        self.dono = dono; self.esforco = esforco; self.lanes = lanes; self.cancelado = cancelado
    }
}

public struct ArquivoCaixa: Equatable, Sendable {
    public var itens: [ItemCaixa]
    /// Cards cancelados nos últimos dias: as Retomadas não os mostram.
    public var cancelados: Set<String>
    public var rotuloDono: String
    public init(itens: [ItemCaixa] = [], cancelados: Set<String> = [], rotuloDono: String = "needs:dono") {
        self.itens = itens; self.cancelados = cancelados; self.rotuloDono = rotuloDono
    }
    public static let vazio = ArquivoCaixa()
}

public enum CaixaDono {
    public static func arquivo(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".transcentia/lanes/caixa-dono.json")
    }

    public static func ler(_ url: URL) -> ArquivoCaixa {
        guard let dados = try? Data(contentsOf: url) else { return .vazio }
        return interpretar(dados)
    }

    public static func interpretar(_ dados: Data) -> ArquivoCaixa {
        guard let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else { return .vazio }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        iso.timeZone = .current  // o vigia grava a hora local, sem fuso
        func t(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "" }
        var itens: [ItemCaixa] = []
        for d in (obj["itens"] as? [[String: Any]]) ?? [] {
            // `issue_id` do arquivo é ignorado: quem grava a pasta escolheria o card do clique.
            let card = t(d, "card")
            guard !card.isEmpty else { continue }
            var opcoes: [OpcaoCaixa] = []
            for o in (d["opcoes"] as? [[String: Any]]) ?? [] {
                let letra = t(o, "letra"), texto = t(o, "texto")
                guard !letra.isEmpty, !texto.isEmpty else { continue }
                var acao: AcaoCaixa?
                if let a = o["acao"] as? [String: Any], let tipo = AcaoCaixa.Tipo(rawValue: t(a, "tipo")) {
                    acao = AcaoCaixa(tipo: tipo, valor: t(a, "valor"))
                }
                opcoes.append(OpcaoCaixa(letra: letra, texto: texto, acao: acao))
            }
            itens.append(ItemCaixa(card: card, titulo: t(d, "titulo"), url: t(d, "url"),
                                   desde: iso.date(from: t(d, "desde")), origem: t(d, "origem").isEmpty ? "dono" : t(d, "origem"),
                                   motivo: t(d, "motivo"), perguntaId: t(d, "pergunta_id"), pendencia: t(d, "pendencia"),
                                   opcoes: opcoes, recomenda: t(d, "recomenda"), porque: t(d, "porque"),
                                   esforco: t(d, "esforco"), lane: t(d, "lane"),
                                   outrasTravas: (d["outras_travas"] as? [String]) ?? []))
        }
        return ArquivoCaixa(itens: itens,
                            cancelados: Set((obj["cancelados"] as? [String]) ?? []),
                            rotuloDono: t(obj, "rotulo_dono").isEmpty ? "needs:dono" : t(obj, "rotulo_dono"))
    }

    /// Respostas em aberto: o que o dono ainda não respondeu. Resposta enviada pelo app desconta
    /// na hora (`respondidas`), sem esperar o vigia regravar o arquivo.
    public static func abertas(_ itens: [ItemCaixa], respondidas: Set<String>) -> Int {
        itens.filter { !respondidas.contains($0.perguntaId) }.count
    }

    /// Perguntas que ainda não viraram aviso do macOS.
    public static func novas(_ itens: [ItemCaixa], vistas: Set<String>, respondidas: Set<String> = []) -> [ItemCaixa] {
        itens.filter { !vistas.contains($0.perguntaId) && !respondidas.contains($0.perguntaId) }
    }

    // MARK: Ações

    public enum Decisao: Equatable, Sendable {
        /// Uma das opções sugeridas: aplica a ação (se houver), comenta e libera.
        case opcao(OpcaoCaixa, comentario: String)
        /// Texto livre; `liberar` tira a etiqueta do dono.
        case responder(String, liberar: Bool)
        case liberar
        /// Move para Canceled; o vigia limpa o resto no ciclo seguinte.
        case cancelar
    }

    public enum ErroCaixa: Error, Equatable, LocalizedError {
        case semId(String)
        case ausente
        case semEtiquetaDono
        case naoConfere
        public var errorDescription: String? {
            switch self {
            case .semId(let o): return String(localized: "Falta o id do Linear para \(o). Rode o vigia uma vez e tente de novo.")
            case .ausente: return String(localized: "Não encontrei esse card no Linear. Nada foi alterado.")
            case .semEtiquetaDono: return String(localized: "Esse card não está mais na sua caixa. Nada foi alterado.")
            case .naoConfere: return String(localized: "O card resolvido não é o que está na tela. Nada foi alterado.")
            }
        }
    }

    /// As mutações GraphQL de uma decisão, em ordem. Pura: o teste confere sem rede.
    /// `issue` é o que o Linear devolveu pelo identifier; `ids` vêm da config e do cache.
    public static func mutacoes(_ decisao: Decisao, item: ItemCaixa, issue: IssueResolvida, ids: IdsCaixa, rotuloDono: String) throws -> [String] {
        guard issue.identifier == item.card, !issue.id.isEmpty else { throw ErroCaixa.naoConfere }
        guard !rotuloDono.isEmpty, issue.etiquetas.contains(rotuloDono) else { throw ErroCaixa.semEtiquetaDono }
        let ref = lit(issue.id)
        func comentar(_ corpo: String) -> String {
            "mutation { commentCreate(input: {issueId: \(ref), body: \(lit(corpo))}) { success } }"
        }
        func tirar(_ label: String) -> String { "mutation { issueRemoveLabel(id: \(ref), labelId: \(lit(label))) { success } }" }
        func por(_ label: String) -> String { "mutation { issueAddLabel(id: \(ref), labelId: \(lit(label))) { success } }" }
        func liberar() throws -> String {
            guard !ids.dono.isEmpty else { throw ErroCaixa.semId("a etiqueta do dono") }
            return tirar(ids.dono)
        }
        func cancelar() throws -> String {
            guard !ids.cancelado.isEmpty else { throw ErroCaixa.semId("o estado Canceled") }
            return "mutation { issueUpdate(id: \(ref), input: {stateId: \(lit(ids.cancelado))}) { success } }"
        }
        switch decisao {
        case let .opcao(op, extra):
            var passos: [String] = []
            switch op.acao?.tipo {
            case .esforco?:
                guard let novo = ids.esforco[op.acao?.valor ?? ""] else { throw ErroCaixa.semId("o esforço \(op.acao?.valor ?? "")") }
                if let velho = ids.esforco[item.esforco], velho != novo { passos.append(tirar(velho)) }
                passos.append(por(novo))
            case .lane?:
                guard let nova = ids.lanes[op.acao?.valor ?? ""] else { throw ErroCaixa.semId("a lane \(op.acao?.valor ?? "")") }
                if let velha = ids.lanes[item.lane], velha != nova { passos.append(tirar(velha)) }
                passos.append(por(nova))
            case .cancelar?:
                passos.append(try cancelar())
            case nil:
                break
            }
            let texto = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            passos.append(comentar("Dono decidiu: \(op.letra)) \(op.texto)" + (texto.isEmpty ? "" : "\n\n\(texto)")))
            passos.append(try liberar())
            return passos
        case let .responder(texto, solta):
            let t = texto.trimmingCharacters(in: .whitespacesAndNewlines)
            var passos = t.isEmpty ? [] : [comentar("Dono: \(t)")]
            if solta { passos.append(try liberar()) }
            return passos
        case .liberar:
            return [try liberar()]
        case .cancelar:
            return [try cancelar(), comentar("Dono cancelou o card pela caixa do dono. O vigia limpa as pendências no próximo ciclo.")]
        }
    }

    /// O clique: sem issue na API, ou sem a etiqueta do dono, não há mutação.
    /// Sem `linear.state_canceled_id` na config, o cancelar usa o estado do time do issue.
    public static func mutacoes(_ decisao: Decisao, item: ItemCaixa, resolucao: ResultadoResolucao, ids: IdsCaixa, rotuloDono: String) throws -> [String] {
        switch resolucao {
        case .ausente: throw ErroCaixa.ausente
        case .semEtiquetaDono: throw ErroCaixa.semEtiquetaDono
        case .pronta(let issue):
            var ids = ids
            if ids.cancelado.isEmpty { ids.cancelado = issue.estadoCancelado }
            return try mutacoes(decisao, item: item, issue: issue, ids: ids, rotuloDono: rotuloDono)
        }
    }

    /// Identifier no formato do Linear (FRA-123). UUID e texto livre não viram consulta:
    /// `issue(id:)` aceita os dois, e um uuid no lugar do identifier atingiria outro card.
    public static func consultaIssue(_ identifier: String) -> String? {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return "{ issue(id: \(lit(id))) { id identifier labels { nodes { name } } team { states { nodes { id type } } } } }"
    }

    /// Lê a resposta do Linear. Identifier diferente do pedido, ou issue ausente, não vira mutação.
    public static func lerResolucao(_ data: [String: Any], identifier: String, rotuloDono: String) -> ResultadoResolucao {
        guard let issue = data["issue"] as? [String: Any] else { return .ausente }
        let id = ((issue["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ident = ((issue["identifier"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, ident == identifier else { return .ausente }
        let nodes = ((issue["labels"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let etiquetas = nodes.compactMap { $0["name"] as? String }
        guard !rotuloDono.isEmpty, etiquetas.contains(rotuloDono) else { return .semEtiquetaDono }
        let states = (((issue["team"] as? [String: Any])?["states"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let cancelado = states.first { ($0["type"] as? String) == "canceled" }.flatMap { $0["id"] as? String } ?? ""
        return .pronta(IssueResolvida(id: id, identifier: ident, etiquetas: etiquetas, estadoCancelado: cancelado))
    }

    /// Resolve o issue pelo identifier. Não lê o `caixa-dono.json`.
    public static func resolver(identifier: String, rotuloDono: String, cliente: ClienteLinear, token: String) async throws -> ResultadoResolucao {
        guard let q = consultaIssue(identifier) else { return .ausente }
        return lerResolucao(try await cliente.consultar(q, token: token), identifier: identifier, rotuloDono: rotuloDono)
    }

    /// Mesmo lugar do cache do vigia (`linear_ids.caminho_cache`): `~/.transcentia/lanes`.
    /// Config por cima do cache, como `linear_ids.carregar`. O id do projeto não sai da pasta.
    public static func caminhoCacheIds(home: URL = FileManager.default.homeDirectoryForCurrentUser, projetoID: String = "") -> URL {
        let base = home.appendingPathComponent(Legado.estadoLanes)
        let pid = String(projetoID.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        if pid.isEmpty { return base.appendingPathComponent("linear-ids.json") }
        return base.appendingPathComponent("linear-ids", isDirectory: true).appendingPathComponent("\(pid).json")
    }

    public static func lerCacheIds(_ url: URL) -> [String: Any] {
        guard let dados = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return [:] }
        return obj
    }

    /// Etiquetas: config vence o cache `linear-ids`. Não olha o arquivo da caixa.
    /// O estado Canceled só entra se a config tiver `linear.state_canceled_id`.
    public static func idsDoApp(config: [String: Any], cache: [String: Any], rotuloDono: String) -> IdsCaixa {
        func mapa(_ v: Any?) -> [String: String] {
            guard let d = v as? [String: Any] else { return [:] }
            var r: [String: String] = [:]
            for (k, val) in d {
                guard let s = val as? String else { continue }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { r[k] = t }
            }
            return r
        }
        func vence(_ cfg: [String: String], _ doCache: [String: String]) -> [String: String] {
            var r = doCache
            for (k, v) in cfg { r[k] = v }
            return r
        }
        let nomesCfg = mapa(Configuracao.valor("linear.labels.nomes", em: config))
        let nomesCache = mapa(cache["labels"])
        // O vigia não grava o estado canceled no cache. Só a config fixa esse id; senão,
        // o clique usa o estado do time que a consulta do issue devolveu.
        let canceladoCfg = ((Configuracao.valor("linear.state_canceled_id", em: config) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IdsCaixa(dono: nomesCfg[rotuloDono] ?? nomesCache[rotuloDono] ?? "",
                        esforco: vence(mapa(Configuracao.valor("linear.labels.esforco", em: config)), mapa(cache["esforco"])),
                        lanes: vence(mapa(Configuracao.valor("linear.labels.lanes", em: config)), mapa(cache["lanes"])),
                        cancelado: canceladoCfg)
    }

    /// Roda as mutações em ordem e para no primeiro erro (o que já foi feito fica feito).
    public static func executar(_ passos: [String], cliente: ClienteLinear, token: String) async throws {
        for q in passos {
            let d = try await cliente.consultar(q, token: token)
            let ok = d.values.contains { (($0 as? [String: Any])?["success"] as? Bool) == true }
            guard ok else { throw ErroLinear.resposta(String(q.prefix(60))) }
        }
    }

    // MARK: O que acontece (texto do app, não do modelo: nunca omite o que a ação faz)

    static func rotuloEsforco(_ e: String) -> String {
        switch e { case "medio": return "médio"; case "": return "sem esforço definido"; default: return e }
    }

    /// Frase simples com tudo o que a decisão faz. `vaiRodar(lane, peso)` devolve «opus · high»
    /// (peso vazio = o esforço padrão da config), ou nil quando não dá para saber.
    public static func consequencia(_ decisao: Decisao, item: ItemCaixa,
                                    vaiRodar: (String, String) -> String? = { _, _ in nil }) -> String {
        func travas() -> String? {
            guard !item.outrasTravas.isEmpty else { return nil }
            let nomes = item.outrasTravas.map { $0 == "lane:falhou" ? "a marca de que a lane falhou" : "a marca de que a lane parou" }
            return "Ele ainda tem \(nomes.joined(separator: " e ")) e só volta para a fila quando a triagem ou você tirar."
        }
        func fila(lane: String, peso: String) -> String {
            if let t = travas() { return t }
            guard !lane.isEmpty else { return "Ele volta para a fila das lanes." }
            if let vr = vaiRodar(lane, peso) { return "Ele volta para a fila da lane \(lane), que vai rodar em \(vr)." }
            return "Ele volta para a fila da lane \(lane)."
        }
        let libera = "O card sai da sua caixa."
        switch decisao {
        case let .opcao(op, _):
            switch op.acao?.tipo {
            case .esforco?:
                let novo = op.acao?.valor ?? ""
                let troca = novo == item.esforco ? "Mantém o esforço \(rotuloEsforco(novo)), "
                    : "Troca o esforço do card de \(rotuloEsforco(item.esforco)) para \(rotuloEsforco(novo)), "
                return troca + "comenta a sua decisão no card e tira o card da sua caixa. " + fila(lane: item.lane, peso: novo)
            case .lane?:
                let nova = op.acao?.valor ?? ""
                if nova == item.lane {
                    return "Mantém a lane \(nova), comenta a sua decisão e tira o card da sua caixa. " + fila(lane: nova, peso: item.esforco)
                }
                let de = item.lane.isEmpty ? "" : " da lane \(item.lane)"
                return "Passa o card\(de) para a lane \(nova), comenta a sua decisão e tira o card da sua caixa. "
                    + fila(lane: nova, peso: item.esforco)
            case .cancelar?:
                return "Move o card para Canceled, comenta a sua decisão e tira o card da sua caixa agora. No próximo "
                    + "ciclo o vigia limpa o que ainda segurar o card. O worktree e a branch do card não são apagados."
            case nil:
                return "Comenta a sua decisão no card. \(libera) " + fila(lane: item.lane, peso: item.esforco)
            }
        case let .responder(texto, solta):
            let vazio = texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if solta && vazio { return consequencia(.liberar, item: item, vaiRodar: vaiRodar) }
            return solta ? "Comenta o seu texto no card. \(libera) " + fila(lane: item.lane, peso: item.esforco)
                         : "Só comenta o seu texto no card. Ele continua esperando por você."
        case .liberar:
            return "\(libera) Nada é comentado. " + fila(lane: item.lane, peso: item.esforco)
        case .cancelar:
            return "Move o card para Canceled e comenta isso nele. No próximo ciclo o vigia tira as etiquetas que "
                + "seguram o card e as instruções de retomada. O worktree e a branch do card não são apagados."
        }
    }

    /// Texto como literal de string do GraphQL (o JSON escapa do mesmo jeito).
    static func lit(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let t = String(data: d, encoding: .utf8),
              t.count >= 2 else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }
}
