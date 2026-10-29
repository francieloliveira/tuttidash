import Foundation

/// Caixa do dono (PRD de 29/10): os cards com a etiqueta do dono, como o vigia grava em
/// `~/.transcentia/lanes/caixa-dono.json`, e as ações que o app faz no Linear com um clique.
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
    public var card: String
    public var issueId: String
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

    public init(card: String, issueId: String, titulo: String = "", url: String = "", desde: Date? = nil,
                origem: String = "dono", motivo: String = "", perguntaId: String = "", pendencia: String = "",
                opcoes: [OpcaoCaixa] = [], recomenda: String = "", porque: String = "",
                esforco: String = "", lane: String = "", outrasTravas: [String] = []) {
        self.card = card; self.issueId = issueId; self.titulo = titulo; self.url = url; self.desde = desde
        self.origem = origem; self.motivo = motivo; self.perguntaId = perguntaId.isEmpty ? card : perguntaId
        self.pendencia = pendencia; self.opcoes = opcoes; self.recomenda = recomenda; self.porque = porque
        self.esforco = esforco; self.lane = lane; self.outrasTravas = outrasTravas
    }
}

/// IDs do Linear que o vigia resolveu (o app não procura nada pelo nome).
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
    public var ids: IdsCaixa
    /// Cards cancelados nos últimos dias: as Retomadas não os mostram.
    public var cancelados: Set<String>
    public var rotuloDono: String
    public init(itens: [ItemCaixa] = [], ids: IdsCaixa = IdsCaixa(), cancelados: Set<String> = [], rotuloDono: String = "needs:dono") {
        self.itens = itens; self.ids = ids; self.cancelados = cancelados; self.rotuloDono = rotuloDono
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
            let card = t(d, "card"), issue = t(d, "issue_id")
            guard !card.isEmpty, !issue.isEmpty else { continue }
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
            itens.append(ItemCaixa(card: card, issueId: issue, titulo: t(d, "titulo"), url: t(d, "url"),
                                   desde: iso.date(from: t(d, "desde")), origem: t(d, "origem").isEmpty ? "dono" : t(d, "origem"),
                                   motivo: t(d, "motivo"), perguntaId: t(d, "pergunta_id"), pendencia: t(d, "pendencia"),
                                   opcoes: opcoes, recomenda: t(d, "recomenda"), porque: t(d, "porque"),
                                   esforco: t(d, "esforco"), lane: t(d, "lane"),
                                   outrasTravas: (d["outras_travas"] as? [String]) ?? []))
        }
        let ids = (obj["ids"] as? [String: Any]) ?? [:]
        func mapa(_ v: Any?) -> [String: String] { ((v as? [String: Any]) ?? [:]).compactMapValues { $0 as? String } }
        return ArquivoCaixa(itens: itens,
                            ids: IdsCaixa(dono: t(ids, "dono"), esforco: mapa(ids["esforco"]), lanes: mapa(ids["lanes"]),
                                          cancelado: t(ids, "cancelado")),
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
        public var errorDescription: String? {
            switch self {
            case .semId(let o): return String(localized: "Falta o id do Linear para \(o). Rode o vigia uma vez e tente de novo.")
            }
        }
    }

    /// As mutações GraphQL de uma decisão, em ordem. Pura: o teste confere sem rede.
    public static func mutacoes(_ decisao: Decisao, item: ItemCaixa, ids: IdsCaixa) throws -> [String] {
        let issue = lit(item.issueId)
        func comentar(_ corpo: String) -> String {
            "mutation { commentCreate(input: {issueId: \(issue), body: \(lit(corpo))}) { success } }"
        }
        func tirar(_ label: String) -> String { "mutation { issueRemoveLabel(id: \(issue), labelId: \(lit(label))) { success } }" }
        func por(_ label: String) -> String { "mutation { issueAddLabel(id: \(issue), labelId: \(lit(label))) { success } }" }
        func liberar() throws -> String {
            guard !ids.dono.isEmpty else { throw ErroCaixa.semId("a etiqueta do dono") }
            return tirar(ids.dono)
        }
        func cancelar() throws -> String {
            guard !ids.cancelado.isEmpty else { throw ErroCaixa.semId("o estado Canceled") }
            return "mutation { issueUpdate(id: \(issue), input: {stateId: \(lit(ids.cancelado))}) { success } }"
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
