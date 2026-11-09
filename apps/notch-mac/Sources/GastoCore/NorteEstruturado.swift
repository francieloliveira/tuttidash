import Foundation

/// Norte em passos fixos (PRD "wizard do norte em passos fixos").
///
/// O rascunho do agente vira passos com itens que o dono marca, edita ou acrescenta. As
/// perguntas ficam no passo que resolvem e a resposta vira item marcado. O `caminho.md` só é
/// montado no fim, a partir do que está marcado: não há texto livre nem marca de pendência
/// para procurar.
public struct NorteEstruturado: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var texto: String
        /// Arquivo de onde o agente tirou o item; nil quando não disse.
        public var fonte: String?
        /// O agente não tinha base no material.
        public var palpite: Bool
        public var marcado: Bool
        /// O dono escreveu ou mudou: «sugerir de novo» não mexe.
        public var editado: Bool

        public init(texto: String, fonte: String? = nil, palpite: Bool = false, marcado: Bool = true, editado: Bool = false) {
            self.texto = texto
            self.fonte = fonte
            self.palpite = palpite
            self.marcado = marcado
            self.editado = editado
        }
    }

    public struct Pergunta: Identifiable, Equatable, Sendable {
        public var id = UUID()
        /// Passo que a pergunta resolve (0 = Objetivo … 4 = Glossário).
        public var passo: Int
        public var texto: String
        public var sugestao: String
        public var resolvida = false
    }

    /// Títulos dos passos de conteúdo, na ordem do `caminho.md`.
    public static let passos = NorteRascunho.secoes
    /// Passos sem os quais o norte não sai (o glossário é opcional).
    public static let obrigatorios = 0...3

    public var objetivo: String
    public var objetivoEditado = false
    /// Itens de cada passo; o índice 0 (Objetivo) fica vazio: o objetivo é texto.
    public var itens: [[Item]]
    public var perguntas: [Pergunta]

    public init(objetivo: String = "", itens: [[Item]] = Array(repeating: [], count: 5), perguntas: [Pergunta] = []) {
        self.objetivo = objetivo
        self.itens = itens.count == 5 ? itens : Array(repeating: [], count: 5)
        self.perguntas = perguntas
    }

    // MARK: - Do rascunho

    public static func de(_ r: NorteRascunho.Rascunho) -> NorteEstruturado {
        var n = NorteEstruturado()
        let obj = r.corpos.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        n.objetivo = obj.contains(NorteRascunho.aDefinir) ? "" : semOrigem(obj).texto
        for passo in 1..<min(5, r.corpos.count) {
            n.itens[passo] = itens(de: r.corpos[passo])
        }
        n.perguntas = r.perguntas.enumerated().map { i, bruta in
            let (passo, texto) = passoDaPergunta(bruta)
            let sug = r.sugestoes.indices.contains(i) ? r.sugestoes[i] : ""
            return Pergunta(passo: passo, texto: texto, sugestao: sug)
        }
        return n
    }

    /// Um item por linha de lista. Linha solta continua o item anterior.
    static func itens(de corpo: String) -> [Item] {
        var saida: [Item] = []
        for bruta in corpo.components(separatedBy: "\n") {
            var l = bruta.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.contains(NorteRascunho.aDefinir) else { continue }
            let ehItem = l.hasPrefix("- ") || l.hasPrefix("• ") || l.hasPrefix("* ") || l.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
            if ehItem {
                l = l.replacingOccurrences(of: #"^(- |• |\* |\d+[.)]\s+)"#, with: "", options: .regularExpression)
                // "R1: texto" vira "texto": a numeração sai no markdown final.
                l = l.replacingOccurrences(of: #"^\**R\d+\**\s*[:.—-]\s*"#, with: "", options: .regularExpression)
                let o = semOrigem(l)
                guard !o.texto.isEmpty else { continue }
                saida.append(Item(texto: o.texto, fonte: o.fonte, palpite: o.palpite, marcado: !o.palpite))
            } else if var ultimo = saida.popLast() {
                ultimo.texto += " " + l
                saida.append(ultimo)
            } else {
                let o = semOrigem(l)
                saida.append(Item(texto: o.texto, fonte: o.fonte, palpite: o.palpite, marcado: !o.palpite))
            }
        }
        return saida
    }

    /// Tira "palpite:" do começo e "(fonte: …)" do fim.
    static func semOrigem(_ texto: String) -> (texto: String, fonte: String?, palpite: Bool) {
        var t = texto.trimmingCharacters(in: .whitespaces)
        var palpite = false
        if t.lowercased().hasPrefix("palpite:") {
            palpite = true
            t = String(t.dropFirst("palpite:".count)).trimmingCharacters(in: .whitespaces)
        }
        var fonte: String?
        if let r = t.range(of: #"\(\s*fontes?\s*:\s*([^)]+)\)\s*\.?\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            let dentro = t[r].replacingOccurrences(of: #"^\(\s*fontes?\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            fonte = dentro.replacingOccurrences(of: #"\)\s*\.?\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(".") == false, !t.isEmpty { t += "." }
        }
        return (t, fonte, palpite)
    }

    /// "[§2] pergunta" → (1, "pergunta"). Sem marca: passo 0.
    static func passoDaPergunta(_ bruta: String) -> (Int, String) {
        let t = bruta.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^\[\s*§?\s*([1-5])\s*\]\s*"#, options: .regularExpression),
              let d = t[r].first(where: \.isNumber), let n = d.wholeNumberValue else { return (0, t) }
        return (n - 1, String(t[r.upperBound...]))
    }

    // MARK: - Prontidão

    /// Por que o passo não está pronto; nil quando está.
    public func pendencia(_ passo: Int) -> String? {
        switch passo {
        case 0:
            return objetivo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "Escreva o objetivo: para quem é e que resultado entrega.") : nil
        case 1, 2, 3:
            let ok = itens[passo].contains { $0.marcado && !$0.texto.trimmingCharacters(in: .whitespaces).isEmpty }
            return ok ? nil : String(localized: "Marque ou adicione pelo menos um item.")
        default:
            return nil
        }
    }

    /// Primeiro passo obrigatório que falta; nil quando dá para abrir o PR.
    public var primeiroPendente: Int? { Self.obrigatorios.first { pendencia($0) != nil } }

    // MARK: - Ações do dono

    /// «Usar sugestão» ou «Responder»: vira item marcado do passo (no Objetivo, entra no texto).
    public mutating func responder(_ id: Pergunta.ID, com texto: String) {
        guard let i = perguntas.firstIndex(where: { $0.id == id }) else { return }
        let t = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let o = Self.semOrigem(t)
        let passo = perguntas[i].passo
        if passo == 0 {
            objetivo = objetivo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? o.texto : objetivo + " " + o.texto
            objetivoEditado = true
        } else {
            itens[passo].append(Item(texto: o.texto, fonte: o.fonte, palpite: false, marcado: true, editado: true))
        }
        perguntas[i].resolvida = true
    }

    /// «Sugerir de novo» num passo: troca só o que o dono não marcou nem editou.
    public mutating func mesclar(passo: Int, com novo: NorteEstruturado) {
        if passo == 0 {
            if !objetivoEditado, !novo.objetivo.isEmpty { objetivo = novo.objetivo }
        } else {
            let mantidos = itens[passo].filter { $0.marcado || $0.editado }
            let ja = Set(mantidos.map { $0.texto.lowercased() })
            itens[passo] = mantidos + novo.itens[passo].filter { !ja.contains($0.texto.lowercased()) }
        }
        perguntas.removeAll { $0.passo == passo && !$0.resolvida }
        perguntas += novo.perguntas.filter { $0.passo == passo }
    }

    // MARK: - Arquivo final

    /// `caminho.md` a partir do que está marcado. Fonte e "palpite" não vão para o arquivo.
    public func markdown(nome: String) -> String {
        func marcados(_ p: Int) -> [String] {
            itens[p].filter(\.marcado).map { $0.texto.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let corpos = [
            objetivo.trimmingCharacters(in: .whitespacesAndNewlines),
            marcados(1).enumerated().map { "- R\($0.offset + 1): \($0.element)" }.joined(separator: "\n"),
            marcados(2).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
            marcados(3).map { "- \($0)" }.joined(separator: "\n"),
            marcados(4).map { "- \($0)" }.joined(separator: "\n"),
        ].map { $0.isEmpty ? NorteRascunho.aDefinir : $0 }
        return NorteRascunho.Rascunho(corpos: corpos, perguntas: []).markdown(nome: nome)
    }

    // MARK: - Ajuda de cada passo

    public static func ajuda(_ passo: Int) -> String {
        switch passo {
        case 0: return String(localized: "Para quem é o projeto e que resultado ele entrega, em 1 a 3 frases. Os cards do Brainstorm citam este trecho para dizer o que servem.")
        case 1: return String(localized: "Regras que nenhum card pode violar. Marque as que valem, edite o texto ou adicione. Precisa de pelo menos uma. Item «palpite» o agente não achou no repositório: confira antes de marcar.")
        case 2: return String(localized: "O que vence quando duas metas brigam, em ordem: o primeiro vence o segundo. Use as setas para ordenar. Precisa de pelo menos um.")
        case 3: return String(localized: "Ações proibidas em qualquer card. Precisa de pelo menos uma.")
        case 4: return String(localized: "Termos do projeto que os cards usam. Opcional: pode avançar sem nenhum.")
        default: return String(localized: "O arquivo final, montado do que você marcou. «Abrir PR» grava numa branch e abre o PR no repositório; o norte só vale depois do seu merge. Ajuste fino de texto você pode fazer no próprio PR, no GitHub. Depois do merge, nenhuma lane edita o norte: mudança é proposta a você.")
        }
    }
}
