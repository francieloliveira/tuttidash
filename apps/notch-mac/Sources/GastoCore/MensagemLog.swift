import Foundation

/// O que o menu da barra mostra no lugar da linha crua do `lanes-dispatcher.log`.
/// Uma frase em português claro, sem data nem prefixo técnico.
public struct MensagemBarra: Equatable, Sendable {
    public enum Tipo: String, Sendable {
        /// Uma lane pegou ou terminou um card.
        case trabalho
        /// Um card foi para revisão ou a prova passou.
        case entrega
        /// Algo pede atenção: prova falhou, limite da conta, conflito, pausa.
        case alerta
        /// Fila sem card pronto.
        case fila
        case info
    }
    public var tipo: Tipo
    public var texto: String
    public var quando: Date?
    /// Resumo dos cards que o vigia segurou no Backlog no último ciclo, quando há.
    public var detalhe: String?
}

/// Traduz o log do dispatcher/vigia numa mensagem legível para o menu da barra.
/// O que se repete a cada ciclo (freios, caffeinate, «ocupada com»…) é ruído e não vira mensagem;
/// os freios do último ciclo viram um resumo só («7 cards parados no Backlog: …»).
public enum MensagemLog {
    /// Janela em que os freios contam como «do último ciclo» em relação à última linha do log.
    static let janelaFreios: TimeInterval = 15 * 60

    public static func resumir(_ log: String) -> MensagemBarra? {
        let linhas = LeitorLogDispatcher.parsear(log)
        guard let ultima = linhas.last else {
            // Log sem o formato com data: mostra a última linha limpa, como antes.
            guard let bruta = ResumoBarra.ultimaLinha(log) else { return nil }
            return MensagemBarra(tipo: .info, texto: limpar(bruta), quando: nil, detalhe: nil)
        }
        let freios = resumoFreios(linhas, referencia: ultima.data)
        for linha in linhas.reversed() {
            guard let t = traduzir(linha.msg) else { continue }
            return MensagemBarra(tipo: t.0, texto: t.1, quando: linha.data, detalhe: freios?.texto)
        }
        if let freios {
            return MensagemBarra(tipo: .fila, texto: freios.texto, quando: freios.quando, detalhe: nil)
        }
        return nil
    }

    /// nil = ruído (a linha não vira mensagem).
    static func traduzir(_ msg: String) -> (MensagemBarra.Tipo, String)? {
        if ehRuido(msg) { return nil }
        if msg.contains("fila vazia") {
            return (.fila, "Sem cards prontos no Todo nem no Backlog")
        }
        if msg.contains("PAUSE presente") || msg.hasPrefix("PAUSE") {
            return (.alerta, "Dispatcher em pausa (arquivo PAUSE)")
        }
        if let g = casar(#"^lane:(\S+) (?:→ ASSUME|ASSUMIU) (FRA-\d+)"#, msg) {
            return (.trabalho, "\(nome(g[0])) começou \(g[1])")
        }
        if let g = casar(#"^lane:(\S+) (?:FECHOU )?(FRA-\d+) → In Review"#, msg) {
            return (.entrega, "\(nome(g[0])) entregou \(g[1]) para revisão")
        }
        if let g = casar(#"^lane:(\S+) (?:FECHOU )?(FRA-\d+) → devolvido à fila até (\d{1,2}:\d{2})"#, msg) {
            return (.alerta, "\(g[1]) volta para a fila às \(g[2]): \(nome(g[0])) bateu o limite de uso")
        }
        if let g = casar(#"^lane:(\S+) (FRA-\d+): agente terminou"#, msg) {
            return (.trabalho, "\(nome(g[0])) terminou \(g[1]); testando a entrega")
        }
        if let g = casar(#"^lane:\S+ (FRA-\d+) prova:.*?with (\d+) failures?"#, msg) {
            let n = Int(g[1]) ?? 0
            if n == 0 { return (.entrega, "Testes de \(g[0]) passaram") }
            return (.alerta, "Testes de \(g[0]) falharam (\(Formato.plural(n, "falha", "falhas")))")
        }
        if msg.range(of: #"^lane:\S+ FRA-\d+ prova:"#, options: .regularExpression) != nil {
            return nil
        }
        if let g = casar(#"^lane:(\S+) em limite da conta até (\d{1,2}:\d{2})"#, msg) {
            return (.alerta, "\(nome(g[0])) no limite da conta até \(g[1])")
        }
        if let g = casar(#"^lane:(\S+) limite da conta liberou"#, msg) {
            return (.info, "\(nome(g[0])) voltou a pegar cards")
        }
        if let g = casar(#"^lane:(\S+) segura (FRA-\d+): conta em (\d+)%"#, msg) {
            return (.alerta, "\(nome(g[0])) segurou \(g[1]): conta em \(g[2])%")
        }
        if let g = casar(#"^vigia: conflito: (FRA-\d+) PR #(\d+)"#, msg) {
            return (.alerta, "PR #\(g[1]) de \(g[0]) tem conflito com a main")
        }
        if let g = casar(#"^vigia: needs (FRA-\d+): análise feita"#, msg) {
            return (.info, "\(g[0]) analisado: a decisão está em Esperando você")
        }
        if let g = casar(#"^auto: (FRA-\d+) aguarda folga"#, msg) {
            return (.info, "\(g[0]) espera folga em alguma conta")
        }
        if let g = casar(#"^auto: (FRA-\d+) → lane:(\S+)"#, msg) {
            return (.info, "\(g[0]) vai para \(nome(g[1]))")
        }
        if let g = casar(#"^vigia: worktree fora da pasta de branches: (\S+)"#, msg) {
            return (.alerta, "Checkout fora da pasta de branches: \(g[0])")
        }
        if msg.hasPrefix("lane:") && msg.contains(" livre") { return nil }
        return (.info, limpar(msg))
    }

    /// Linhas que se repetem a cada ciclo e não dizem nada novo.
    static func ehRuido(_ msg: String) -> Bool {
        if msg.hasPrefix("vigia: freio:") || msg.hasPrefix("fora:") || msg.hasPrefix("MODO ") { return true }
        let trechos = [
            "mantendo acordado", "liberado: sem trabalho", "proof* antigos arquivados",
            " ocupada com ", "vigia: sombra ", "revisão feita por",
        ]
        return trechos.contains { msg.contains($0) }
    }

    /// Freios do último ciclo: cada card conta uma vez, agrupado pelo motivo.
    static func resumoFreios(_ linhas: [LinhaLog], referencia: Date?) -> (texto: String, quando: Date?)? {
        let freios = linhas.filter { $0.msg.hasPrefix("vigia: freio:") }
        guard let ultimo = freios.last else { return nil }
        if let ref = referencia, let d = ultimo.data, ref.timeIntervalSince(d) > janelaFreios { return nil }
        let ciclo = freios.filter { linha in
            guard let a = linha.data, let b = ultimo.data else { return linha.quando == ultimo.quando }
            return abs(a.timeIntervalSince(b)) <= 3
        }
        var decisao = Set<String>(), aceite = Set<String>(), outros = Set<String>()
        for linha in ciclo {
            guard let card = casar(#"(FRA-\d+)"#, linha.msg)?.first else { continue }
            if linha.msg.contains("decisão aberta") { decisao.insert(card) }
            else if linha.msg.contains("sem aceite") { aceite.insert(card) }
            else { outros.insert(card) }
        }
        let total = decisao.count + aceite.count + outros.count
        guard total > 0 else { return nil }
        var partes: [String] = []
        if !decisao.isEmpty { partes.append("\(decisao.count) \(decisao.count == 1 ? "espera" : "esperam") decisão sua") }
        if !aceite.isEmpty { partes.append("\(aceite.count) sem critério de aceite") }
        if !outros.isEmpty { partes.append("\(outros.count) por outro motivo") }
        let cabeca = total == 1 ? "1 card parado no Backlog" : "\(total) cards parados no Backlog"
        return (cabeca + ": " + partes.joined(separator: ", "), ultimo.data)
    }

    static func nome(_ lane: String) -> String {
        ResumoBarra.titulo(lane)
    }

    /// Tira a data e o prefixo «vigia:» e começa com maiúscula.
    static func limpar(_ linha: String) -> String {
        var s = linha
        if s.count >= 20, Datas.lerLocal(String(s.prefix(19))) != nil {
            s = String(s.dropFirst(19)).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("vigia: ") { s = String(s.dropFirst("vigia: ".count)) }
        guard let primeira = s.first else { return s }
        return primeira.uppercased() + s.dropFirst()
    }

    /// Grupos de captura do primeiro casamento, ou nil.
    static func casar(_ padrao: String, _ texto: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: padrao),
              let m = re.firstMatch(in: texto, range: NSRange(texto.startIndex..., in: texto)) else { return nil }
        if m.numberOfRanges == 1 {
            return Range(m.range, in: texto).map { [String(texto[$0])] }
        }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: texto).map { String(texto[$0]) } ?? ""
        }
    }
}
