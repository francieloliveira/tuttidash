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
    Tom: sucinto, crítico e criativo. Aponte o furo antes de elogiar. \
    Proponha uma melhoria concreta, não um cardápio.
    Português. No máximo 8 linhas. Sem título e sem preâmbulo.
    """

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
        """
    }

    /// Id que pode ir no argv. Fora do formato, a chamada começa sessão nova.
    public static func sessaoUtil(_ id: String?) -> String? {
        guard let id, Retomadas.sessaoAceita(id) else { return nil }
        return id
    }

    /// Comando só leitura. `nil` = este CLI não entra no brainstorm.
    /// `sessao` inválida é ignorada: o id vai parar no argv.
    public static func chamada(cli: String, prompt: String, sessao: String?, saidaCodex: String?) -> Chamada? {
        let id = sessaoUtil(sessao)
        switch cli {
        case "claude":
            // `plan` pesquisa o repositório inteiro antes de falar. Só leitura aqui é
            // a lista de ferramentas, com poucos turnos, no modelo rápido do chat.
            var args = ["-p"]
            if let id { args += ["--resume", id] }
            args += ["--output-format", "json",
                     "--permission-mode", "dontAsk",
                     "--permission-prompts", "none",
                     "--tools", "Read,Grep,Glob",
                     "--max-turns", id == nil ? "3" : "2",
                     "--model", "sonnet",
                     "--effort", "low"]
            if id == nil { args += ["--append-system-prompt", sistema] }
            return Chamada(argumentos: args, stdin: prompt, retomando: id != nil)
        case "opencode":
            let corpo = id == nil ? sistema + "\n\n" + prompt : prompt
            var args = ["run", "--format", "json", "-m", "opencode/glm-5.3-flash-free", "--agent", "plan"]
            if let id { args += ["--session", id] }
            args += ["--", corpo]
            return Chamada(argumentos: args, stdin: nil, retomando: id != nil)
        case "grok":
            let corpo = id == nil ? sistema + "\n\n" + prompt : prompt
            var args = ["--tools", "read_file,grep,list_dir", "--disable-web-search",
                        "--max-turns", "4", "-m", "grok-4.7-build-fast"]
            if let id { args += ["--resume", id] }
            args += ["-p", corpo]
            return Chamada(argumentos: args, stdin: nil, retomando: id != nil)
        case "codex":
            // O `exec` não retoma no mesmo formato. O histórico vai no prompt; a caixa é só leitura.
            guard let saidaCodex else { return nil }
            return Chamada(
                argumentos: ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never",
                             "--output-last-message", saidaCodex, "-c", "model_reasoning_effort=low", "-"],
                stdin: sistema + "\n\n" + prompt,
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
