import Foundation

/// Como o chat do Brainstorm chama o CLI, sem processo e sem AppKit.
///
/// O que deixava cada pergunta lenta estava aqui: o prompt mandava ler o repositório,
/// o Claude ia em `--permission-mode plan` (um passeio de planejamento) e, se a lane
/// do revisor falhasse por qualquer motivo, o OpenCode repetia o mesmo passeio.
/// A resposta continua só leitura. A sessão da primeira resposta é retomada na seguinte.
public enum BrainstormCLI {
    public struct Chamada: Equatable, Sendable {
        public var argumentos: [String]
        public var stdin: String?
        public var retomando: Bool
    }

    public struct Saida: Equatable, Sendable {
        public var texto: String
        public var sessao: String?
        public var erro: Bool
    }

    /// O que fazer depois que um CLI não devolveu resposta.
    public enum Seguinte: Equatable, Sendable {
        /// Sem sessão, comando desconhecido ou flag que o binário não tem: tenta o próximo.
        case proximo
        /// A sessão guardada não existe mais: o mesmo CLI, uma vez, com o prompt inteiro.
        case recomecar
        /// Erro de verdade. Não abre um segundo agente em seguida.
        case parar
    }

    public static let sistema = """
    Você é o agente de brainstorm deste repositório. Não edite arquivos e não rode comandos.
    Não percorra o repositório: responda com o que esta conversa já tem. \
    Se o pedido citar um arquivo que você ainda não abriu, leia só esse arquivo.
    Tom: sucinto, crítico e criativo. Aponte o furo antes de elogiar.
    Português. No máximo 6 linhas, sem título e sem preâmbulo.
    Depois feche com um bloco ITENS: e de 2 a 4 linhas começando com "- ".
    Cada item é uma frase curta que pode ser acrescentada à ideia. Nada depois do bloco.
    """

    /// Só devolve o texto novo da ideia. Não conversa e não lista itens.
    public static let sistemaReescrita = """
    Você escreve o esboço da ideia do brainstorm. Não edite arquivos e não rode comandos.
    Não percorra o repositório. Não converse, não liste opções e não explique.
    Devolva apenas o texto da ideia, em português, em um ou dois parágrafos.
    Se a ideia atual estiver vazia, reúna a conversa e os itens num primeiro esboço.
    Se já houver texto, conserve o que está e acrescente os pontos novos. Não apague o que já estava certo.
    Sem título, sem aspas, sem preâmbulo.
    """

    /// Quebra a idéia em histórias. Cada uma leva um par lane + esforço do catálogo.
    public static let sistemaHistorias = """
    Você quebra uma idéia em histórias de usuário. Não edite arquivos e não rode comandos.
    Não percorra o repositório. Não converse e não explique.
    Cada história implementa um pedaço diferente da idéia. Não copie a idéia inteira em todo card.
    Não invente história sobre gerar cards, etiquetas ou envio ao Linear, a menos que a idéia trate disso.
    Cada história usa um par da lista: a lane é a etiqueta do grupo lane, o esforço é a etiqueta do grupo esforco.
    O dispatcher escolhe o modelo dessa lane por esse esforço. Não invente lane nem esforço.
    Português. Devolva só os blocos HISTORIA:, sem texto antes ou depois.
    """

    public struct Fala: Equatable, Sendable {
        public var texto: String
        public var itens: [String]
    }

    /// Separa o comentário dos itens acrescentáveis. Sem o bloco `ITENS:`, o texto inteiro fica na fala.
    public static func separarItens(_ bruto: String) -> Fala {
        let linhas = bruto.components(separatedBy: "\n")
        guard let indice = linhas.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "ITENS:"
        }) else {
            return Fala(texto: bruto.trimmingCharacters(in: .whitespacesAndNewlines), itens: [])
        }
        let texto = linhas[..<indice].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var vistos = Set<String>()
        let itens = linhas[(indice + 1)...].compactMap { linha -> String? in
            let s = linha.trimmingCharacters(in: .whitespaces)
            let corpo: String
            if s.hasPrefix("- ") || s.hasPrefix("• ") {
                corpo = String(s.dropFirst(2))
            } else {
                return nil
            }
            let item = corpo.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty, vistos.insert(item).inserted else { return nil }
            return item
        }
        return Fala(texto: texto, itens: itens)
    }

    /// Tira cerca, rótulo e aspas que o modelo cola em volta da ideia.
    public static func textoReescrito(_ bruto: String) -> String {
        var t = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var linhas = t.components(separatedBy: "\n")
            if linhas.first?.hasPrefix("```") == true { linhas.removeFirst() }
            if linhas.last?.trimmingCharacters(in: .whitespaces) == "```" { linhas.removeLast() }
            t = linhas.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fala = separarItens(t)
        if t.hasPrefix("ITENS:") || t.contains("\nITENS:") {
            t = fala.texto
        }
        let baixo = t.lowercased()
        for prefixo in ["idéia:", "ideia:"] where baixo.hasPrefix(prefixo) {
            t = String(t.dropFirst(prefixo.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if t.count >= 2 {
            let abre = t.first
            let fecha = t.last
            let aspas = (abre == "\"" && fecha == "\"") || (abre == "“" && fecha == "”")
            if aspas {
                t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    public static func promptReescrita(ideia: String, conversa: String, itens: [String]) -> String {
        let assunto = ideia.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = assunto.isEmpty
            ? "(ainda vazia — escreva o primeiro esboço)"
            : assunto
        let fala = conversa.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversaTexto = fala.isEmpty ? "(nenhum trecho novo)" : fala
        let lista = itens.isEmpty ? "(nenhum)" : itens.map { "- \($0)" }.joined(separator: "\n")
        let passo = assunto.isEmpty
            ? "Reúna a conversa e os itens num esboço."
            : "Conserve a ideia atual e acrescente só o que a conversa nova e os itens trazem."
        return """
        Ideia atual:
        \(base)

        Conversa nova:
        \(conversaTexto)

        Itens selecionados:
        \(lista)

        \(passo)
        Devolva só o texto novo da ideia.
        """
    }

    /// Lane do catálogo e os esforços (`modelos`) que ela aceita. São as etiquetas do Linear.
    public struct EtiquetaLane: Equatable, Sendable {
        public var nome: String
        public var esforcos: [String]

        public init(nome: String, esforcos: [String]) {
            self.nome = nome
            self.esforcos = esforcos
        }
    }

    public struct HistoriaGerada: Equatable, Sendable {
        public var titulo: String
        public var descricao: String
        public var criterios: [String]
        public var prioridade: Int
        public var estimativa: Int
        public var esforco: String
        public var lane: String
    }

    public static let niveisEsforco = ["baixo", "medio", "alto"]

    /// Lanes com modelo para pelo menos um esforço. Se há lanes habilitadas no meio delas, só essas.
    public static func etiquetas(lanes: [(nome: String, esforcos: [String])], habilitadas: Set<String>) -> [EtiquetaLane] {
        let limpas: [EtiquetaLane] = lanes.compactMap { item in
            let nome = item.nome.trimmingCharacters(in: .whitespacesAndNewlines)
            var vistos = Set<String>()
            let es = item.esforcos.filter { niveisEsforco.contains($0) && vistos.insert($0).inserted }
            guard !nome.isEmpty, !es.isEmpty else { return nil }
            return EtiquetaLane(nome: nome, esforcos: es)
        }
        let conhecidas = Set(limpas.map(\.nome))
        let ligadas = habilitadas.intersection(conhecidas)
        guard !ligadas.isEmpty else { return limpas }
        return limpas.filter { ligadas.contains($0.nome) }
    }

    public static func promptHistorias(ideia: String, etiquetas: [EtiquetaLane]) -> String {
        let assunto = ideia.trimmingCharacters(in: .whitespacesAndNewlines)
        let pares = etiquetas.isEmpty
            ? "(nenhuma lane)"
            : etiquetas.map { "- \($0.nome): \($0.esforcos.joined(separator: ", "))" }.joined(separator: "\n")
        return """
        Ideia:
        \(assunto)

        Pares aceitos (lane: esforços do catálogo):
        \(pares)

        Quebre a idéia em 3 a 6 histórias. Cada uma cobre um pedaço diferente.
        Esforço baixo é ajuste pequeno; medio é o miolo; alto atravessa várias partes.
        Distribua as lanes quando mais de uma aceitar o esforço. Não ponha todas na mesma sem motivo.
        Repita o bloco, sem texto fora dele:

        HISTORIA:
        titulo: frase curta do pedaço
        descricao: Como … Eu quero … Para que …
        criterios:
        - critério
        prioridade: 3
        estimativa: 5
        esforco: medio
        lane: \(etiquetas.first?.nome ?? "claude")
        """
    }

    /// Lê os blocos e força cada história num par lane/esforço que o catálogo aceita.
    public static func historias(de bruto: String, etiquetas: [EtiquetaLane]) -> [HistoriaGerada] {
        let linhas = semCerca(bruto).components(separatedBy: "\n")
        var blocos: [[String]] = []
        var atual: [String] = []
        var dentro = false
        for linha in linhas {
            let marca = linha.trimmingCharacters(in: .whitespaces)
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
                .uppercased()
            if marca == "HISTORIA:" {
                if dentro { blocos.append(atual) }
                atual = []
                dentro = true
                continue
            }
            if dentro { atual.append(linha) }
        }
        if dentro { blocos.append(atual) }
        var cursor = 0
        var vistos = Set<String>()
        var saida: [HistoriaGerada] = []
        for bloco in blocos {
            guard let historia = lerHistoria(bloco, etiquetas: etiquetas, cursor: &cursor) else { continue }
            let chave = historia.titulo
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
                .lowercased()
            guard vistos.insert(chave).inserted else { continue }
            saida.append(historia)
            if saida.count == 6 { break }
        }
        return saida
    }

    private static func semCerca(_ bruto: String) -> String {
        var t = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        var linhas = t.components(separatedBy: "\n")
        if linhas.first?.hasPrefix("```") == true { linhas.removeFirst() }
        if linhas.last?.trimmingCharacters(in: .whitespaces) == "```" { linhas.removeLast() }
        t = linhas.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    private static func campoDe(_ linha: String) -> (String, String)? {
        guard let i = linha.firstIndex(of: ":") else { return nil }
        let bruto = String(linha[..<i]).trimmingCharacters(in: .whitespaces)
        let valor = String(linha[linha.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        let chave = bruto
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
            .lowercased()
        let conhecidas = ["titulo", "descricao", "criterios", "prioridade", "estimativa", "esforco", "lane"]
        guard conhecidas.contains(chave) else { return nil }
        return (chave, valor)
    }

    private static func nivel(_ texto: String) -> String {
        let n = texto
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        switch n {
        case "baixo", "low": return "baixo"
        case "medio", "medium", "mid": return "medio"
        case "alto", "high": return "alto"
        default: return ""
        }
    }

    private static func lerHistoria(_ linhas: [String], etiquetas: [EtiquetaLane], cursor: inout Int) -> HistoriaGerada? {
        var titulo = ""
        var descricao: [String] = []
        var criterios: [String] = []
        var prioridade: Int?
        var estimativa: Int?
        var esforco = ""
        var lane = ""
        var campo = ""
        for bruta in linhas {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            if linha.isEmpty { continue }
            if let (k, v) = campoDe(linha) {
                campo = k
                switch k {
                case "titulo": titulo = v
                case "descricao": if !v.isEmpty { descricao = [v] }
                case "criterios": if !v.isEmpty { criterios.append(conteudoItem(v)) }
                case "prioridade": prioridade = Int(v.filter(\.isNumber))
                case "estimativa": estimativa = Int(v.filter(\.isNumber))
                case "esforco": esforco = nivel(v)
                case "lane": lane = v.lowercased()
                default: break
                }
                continue
            }
            if linha.hasPrefix("- ") || linha.hasPrefix("• ") {
                let item = conteudoItem(String(linha.dropFirst(2)))
                if !item.isEmpty { criterios.append(item) }
                campo = "criterios"
                continue
            }
            switch campo {
            case "descricao": descricao.append(linha)
            case "titulo" where titulo.isEmpty: titulo = linha
            case "titulo": titulo += " " + linha
            default: break
            }
        }
        return encaixar(titulo: titulo, descricao: descricao.joined(separator: "\n"),
                        criterios: criterios, prioridade: prioridade, estimativa: estimativa,
                        esforco: esforco, lane: lane, etiquetas: etiquetas, cursor: &cursor)
    }

    private static func conteudoItem(_ texto: String) -> String {
        texto.trimmingCharacters(in: .whitespaces)
    }

    /// Lane pedida só fica se o catálogo tiver modelo para aquele esforço. Senão, a próxima lane que tenha.
    private static func encaixar(titulo: String, descricao: String, criterios: [String],
                                 prioridade: Int?, estimativa: Int?, esforco: String, lane: String,
                                 etiquetas: [EtiquetaLane], cursor: inout Int) -> HistoriaGerada? {
        let nome = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nome.isEmpty else { return nil }
        var nivelEscolhido = niveisEsforco.contains(esforco) ? esforco : "medio"
        func aceitam(_ e: String) -> [EtiquetaLane] {
            etiquetas.filter { $0.esforcos.contains(e) }
        }
        if aceitam(nivelEscolhido).isEmpty {
            nivelEscolhido = niveisEsforco.first { !aceitam($0).isEmpty } ?? nivelEscolhido
        }
        let candidatas = aceitam(nivelEscolhido)
        guard !candidatas.isEmpty else { return nil }
        let laneFinal: String
        if candidatas.contains(where: { $0.nome == lane }) {
            laneFinal = lane
        } else {
            laneFinal = candidatas[cursor % candidatas.count].nome
            cursor += 1
        }
        let pontos: Int
        if let estimativa, (1...20).contains(estimativa) {
            pontos = estimativa
        } else {
            switch nivelEscolhido {
            case "baixo": pontos = 3
            case "alto": pontos = 8
            default: pontos = 5
            }
        }
        let prio = min(max(prioridade ?? 3, 1), 4)
        var vistos = Set<String>()
        let acs = criterios.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && vistos.insert($0).inserted }
        return HistoriaGerada(titulo: nome, descricao: descricao, criterios: acs,
                              prioridade: prio, estimativa: pontos,
                              esforco: nivelEscolhido, lane: laneFinal)
    }

    /// `claudeFora`: o Claude desta execução não tem sessão ou recusou o comando.
    /// `escolhida`: o CLI que já respondeu nesta conversa entra na frente, para a
    /// pergunta seguinte não esperar o outro antes de começar.
    public static func fila(preferida: String, escolhida: String?, claudeFora: Bool) -> [String] {
        var base = preferida == "opencode" ? ["opencode"] : [preferida, "opencode"]
        if claudeFora {
            base.removeAll { $0 == "claude" }
        }
        if let escolhida, let indice = base.firstIndex(of: escolhida), indice != 0 {
            base.remove(at: indice)
            base.insert(escolhida, at: 0)
        }
        var vistos = Set<String>()
        return base.filter { vistos.insert($0).inserted }
    }

    public static func prompt(mensagem: String, ideia: String, historias: [String],
                              historico: [(agente: Bool, texto: String)], retomando: Bool) -> String {
        let assunto = ideia.trimmingCharacters(in: .whitespacesAndNewlines)
        let ideiaTexto = assunto.isEmpty ? "(ainda vazia)" : assunto
        let cards = historias.isEmpty ? "(nenhuma)" : historias.joined(separator: "\n")
        if retomando {
            return """
            Ideia:
            \(ideiaTexto)

            Histórias já geradas:
            \(cards)

            Pedido:
            \(mensagem)

            Responda direto, sem reler o repositório.
            Feche com o bloco ITENS: e de 2 a 4 linhas "- ". Nada depois do bloco.
            """
        }
        let fala = historico.suffix(8).map { ($0.agente ? "Agente" : "Pessoa") + ": " + $0.texto }
            .joined(separator: "\n")
        return """
        A ideia abaixo é o assunto. O pedido refere-se a ela. Não responda só ao rótulo do pedido.

        Ideia:
        \(ideiaTexto)

        Pedido:
        \(mensagem)

        Histórias já geradas:
        \(cards)

        Conversa:
        \(fala)

        Feche com o bloco ITENS: e de 2 a 4 linhas "- ". Nada depois do bloco.
        """
    }

    public enum Papel: Equatable, Sendable {
        case conversa
        case reescrita
        case historias
    }

    /// Id que pode ir no argv. Fora do formato, a chamada começa sessão nova.
    public static func sessaoUtil(_ id: String?) -> String? {
        guard let id, Retomadas.sessaoAceita(id) else { return nil }
        return id
    }

    /// Comando só leitura. `nil` = este CLI não entra no brainstorm.
    /// `sessao` inválida é ignorada: o id vai parar no argv.
    public static func chamada(cli: String, prompt: String, sessao: String?, saidaCodex: String?,
                               papel: Papel = .conversa) -> Chamada? {
        let id = sessaoUtil(sessao)
        let instrucao: String
        switch papel {
        case .conversa: instrucao = sistema
        case .reescrita: instrucao = sistemaReescrita
        case .historias: instrucao = sistemaHistorias
        }
        switch cli {
        case "claude":
            // `plan` pesquisa o repositório inteiro antes de falar. A conversa lê pouco.
            // Reescrita e histórias não abrem ferramenta: devolvem só o texto pedido.
            var args = ["-p"]
            if let id { args += ["--resume", id] }
            let turnos: String
            let ferramentas: String
            switch papel {
            case .conversa:
                turnos = id == nil ? "3" : "2"
                ferramentas = "Read,Grep,Glob"
            case .reescrita, .historias:
                turnos = "1"
                ferramentas = ""
            }
            args += ["--output-format", "json",
                     "--permission-mode", "dontAsk",
                     "--permission-prompts", "none",
                     "--tools", ferramentas,
                     "--max-turns", turnos,
                     "--model", "sonnet",
                     "--effort", "low"]
            if id == nil { args += ["--append-system-prompt", instrucao] }
            return Chamada(argumentos: args, stdin: prompt, retomando: id != nil)
        case "opencode":
            let corpo = id == nil ? instrucao + "\n\n" + prompt : prompt
            var args = ["run", "--format", "json", "-m", "opencode/glm-5.3-flash-free", "--agent", "plan"]
            if let id { args += ["--session", id] }
            args += ["--", corpo]
            return Chamada(argumentos: args, stdin: nil, retomando: id != nil)
        case "grok":
            let corpo = id == nil ? instrucao + "\n\n" + prompt : prompt
            let turnos: String
            switch papel {
            case .conversa: turnos = "4"
            case .reescrita, .historias: turnos = "1"
            }
            var args = ["--tools", "read_file,grep,list_dir", "--disable-web-search",
                        "--max-turns", turnos, "-m", "grok-4.7-build-fast"]
            if let id { args += ["--resume", id] }
            args += ["-p", corpo]
            return Chamada(argumentos: args, stdin: nil, retomando: id != nil)
        case "codex":
            // O `exec` não retoma no mesmo formato. O histórico vai no prompt; a caixa é só leitura.
            guard let saidaCodex else { return nil }
            return Chamada(
                argumentos: ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never",
                             "--output-last-message", saidaCodex, "-c", "model_reasoning_effort=low", "-"],
                stdin: instrucao + "\n\n" + prompt,
                retomando: false)
        default:
            return nil
        }
    }

    public static func flagDesconhecida(_ texto: String) -> Bool {
        let l = texto.lowercased()
        let marcas = ["unknown option", "unknown flag", "unrecognized option",
                      "unexpected argument", "unrecognized flag"]
        return marcas.contains { l.contains($0) }
    }

    public static func sessaoPerdida(_ texto: String) -> Bool {
        if flagDesconhecida(texto) { return false }
        let l = texto.lowercased()
        let marcas = ["session not found", "no conversation", "unknown session",
                      "session does not exist", "no such session", "invalid session",
                      "failed to resume", "could not resume", "sessão não encontrada"]
        return marcas.contains { l.contains($0) }
    }

    public static func seguinte(texto: String, codigo: Int32?, semLogin: Bool, tinhaSessao: Bool) -> Seguinte {
        if semLogin || codigo == 127 || flagDesconhecida(texto) { return .proximo }
        if tinhaSessao && sessaoPerdida(texto) { return .recomecar }
        return .parar
    }

    /// Tira o texto e o id da sessão do stdout. Texto puro (CLI antigo) passa direto.
    public static func interpretar(cli: String, saida: String) -> Saida {
        let cru = saida.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cli {
        case "claude":
            return interpretarClaude(cru)
        case "opencode":
            return interpretarOpenCode(cru)
        default:
            return Saida(texto: cru, sessao: nil, erro: false)
        }
    }

    private static func jsonObjeto(_ texto: String) -> [String: Any]? {
        guard let dados = texto.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return nil }
        return obj
    }

    private static func objetosJSON(_ cru: String) -> [[String: Any]] {
        var lista: [[String: Any]] = []
        for linha in cru.split(whereSeparator: \.isNewline) {
            let s = linha.trimmingCharacters(in: .whitespaces)
            if let obj = jsonObjeto(s) { lista.append(obj) }
        }
        if lista.isEmpty, let obj = jsonObjeto(cru) { lista.append(obj) }
        return lista
    }

    private static func interpretarClaude(_ cru: String) -> Saida {
        let objs = objetosJSON(cru)
        guard !objs.isEmpty else {
            if cru.hasPrefix("{") || cru.hasPrefix("[") { return Saida(texto: "", sessao: nil, erro: true) }
            return Saida(texto: cru, sessao: nil, erro: false)
        }
        let result = objs.last { ($0["type"] as? String) == "result" }
            ?? objs.last { $0["result"] is String }
            ?? objs[objs.count - 1]
        let texto = (result["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessao = (result["session_id"] as? String) ?? objs.compactMap { $0["session_id"] as? String }.first
        let subtipo = result["subtype"] as? String
        let erro = (result["is_error"] as? Bool) == true || subtipo == "error"
        return Saida(texto: texto, sessao: sessao, erro: erro)
    }

    private static func interpretarOpenCode(_ cru: String) -> Saida {
        let objs = objetosJSON(cru)
        guard !objs.isEmpty else {
            if cru.hasPrefix("{") || cru.hasPrefix("[") { return Saida(texto: "", sessao: nil, erro: true) }
            return Saida(texto: cru, sessao: nil, erro: false)
        }
        var partes: [String] = []
        var sessao: String?
        var erros: [String] = []
        for obj in objs {
            if sessao == nil {
                sessao = (obj["sessionID"] as? String) ?? (obj["session_id"] as? String)
            }
            guard let tipo = obj["type"] as? String else { continue }
            if tipo == "text" {
                let part = obj["part"] as? [String: Any]
                let bruto = (part?["text"] as? String) ?? (obj["text"] as? String) ?? ""
                let limpo = bruto.trimmingCharacters(in: .whitespacesAndNewlines)
                if !limpo.isEmpty { partes.append(limpo) }
            } else if tipo == "error" {
                erros.append(mensagemErro(obj))
            }
        }
        if partes.isEmpty && !erros.isEmpty {
            return Saida(texto: erros.joined(separator: "\n"), sessao: sessao, erro: true)
        }
        return Saida(texto: partes.joined(separator: "\n"), sessao: sessao, erro: false)
    }

    private static func mensagemErro(_ obj: [String: Any]) -> String {
        if let e = obj["error"] as? [String: Any] {
            if let data = e["data"] as? [String: Any], let m = data["message"] as? String, !m.isEmpty { return m }
            if let m = e["message"] as? String, !m.isEmpty { return m }
            if let n = e["name"] as? String, !n.isEmpty { return n }
        }
        if let m = obj["message"] as? String, !m.isEmpty { return m }
        return "erro"
    }
}
