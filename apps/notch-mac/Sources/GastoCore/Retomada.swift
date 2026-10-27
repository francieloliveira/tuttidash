import Foundation

/// Lane que parou sem fechar o card (`lane:falhou` ou o rótulo de dono configurado em `linear.owner_label`) e cuja sessão do agente
/// ainda pode ser retomada com `<cli> --resume <id>`.
public struct Retomada: Equatable, Sendable {
    public var card: String
    public var lane: String
    public var worktree: String
    public var sessao: String
    /// O que o dispatcher gravou em `.lane/finalized` (ex.: `lane:falhou (motivo)`).
    public var desfecho: String
    public var inicio: Date

    public init(card: String, lane: String, worktree: String, sessao: String, desfecho: String, inicio: Date) {
        self.card = card; self.lane = lane; self.worktree = worktree
        self.sessao = sessao; self.desfecho = desfecho; self.inicio = inicio
    }

    /// O rótulo do desfecho, sem o motivo (`lane:falhou` ou o rótulo de dono).
    public var rotulo: String {
        if desfecho.hasPrefix("lane:falhou") { return "lane:falhou" }
        let r = desfecho.split(separator: " ", maxSplits: 1).first.map(String.init) ?? desfecho
        return r.isEmpty ? "lane:falhou" : r
    }

    /// O motivo entre os parênteses de `lane:falhou (…)`, quando há.
    public var motivo: String? {
        guard let a = desfecho.firstIndex(of: "("), desfecho.hasSuffix(")") else { return nil }
        let m = desfecho[desfecho.index(after: a)..<desfecho.index(before: desfecho.endIndex)]
        return m.isEmpty ? nil : String(m)
    }

    /// Comando pronto para colar no terminal. O CLI é o da própria lane quando ele tem
    /// `--resume` conhecido (fonte única em `Agentes`, FRA-373); lane desconhecida cai em `claude`.
    public var comando: String {
        let cli = Agentes.cliResume(lane: lane)
        return "cd \(Retomadas.aspas(worktree)) && \(cli) --resume \(sessao)"
    }
}

/// Acha as lanes que pararam e podem ser retomadas, só leitura.
///
/// Para cada card, só o log mais novo conta: o dispatcher apaga `.lane/finalized` ao assumir o
/// card de novo, então o `finalized` do worktree é o desfecho desse log. O worktree e o id da
/// sessão vêm do próprio stream (`cwd` e `session_id` do `init`, no Claude e no Grok).
public enum Retomadas {
    static func desfechosRetomaveis(rotuloDono: String?) -> [String] {
        ["lane:falhou"] + [rotuloDono].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// `rotuloDono`: rótulo "precisa do dono" vindo da config (`linear.owner_label`).
    public static func ler(logsDir: URL, cardsRodando: Set<String>, rotuloDono: String? = nil, agora: Date = Date(),
                           janelaDias: Int = 7, limite: Int = 3,
                           calendario: Calendar = Datas.calendarioISO) -> [Retomada] {
        let fm = FileManager.default
        let nomes = (try? fm.contentsOfDirectory(atPath: logsDir.path)) ?? []
        let corte = agora.addingTimeInterval(-Double(janelaDias) * 86_400)
        var maisNovo: [String: ParserLog.Nome] = [:]
        for nome in nomes {
            guard let n = ParserLog.lerNome(nome, calendario: calendario), n.dataInicio >= corte else { continue }
            if let atual = maisNovo[n.card], atual.dataInicio >= n.dataInicio { continue }
            maisNovo[n.card] = n
        }
        let retomaveis = desfechosRetomaveis(rotuloDono: rotuloDono)
        var out: [Retomada] = []
        for n in maisNovo.values.sorted(by: { $0.dataInicio > $1.dataInicio }) {
            guard !cardsRodando.contains(n.card) else { continue }
            let log = logsDir.appendingPathComponent(n.id + ".jsonl")
            guard let (sessao, cwd) = sessaoECwd(log: log) else { continue }
            let finalizado = URL(fileURLWithPath: cwd).appendingPathComponent(".lane/finalized")
            guard let texto = try? String(contentsOf: finalizado, encoding: .utf8) else { continue }
            let desfecho = texto.trimmingCharacters(in: .whitespacesAndNewlines)
            guard retomaveis.contains(where: { desfecho.hasPrefix($0) }) else { continue }
            out.append(Retomada(card: n.card, lane: n.lane, worktree: cwd, sessao: sessao,
                                desfecho: desfecho, inicio: n.dataInicio))
            if out.count == limite { break }
        }
        return out
    }

    /// `session_id` e `cwd` das primeiras linhas do stream (o `init` vem primeiro). Lê no máximo
    /// 256 KiB do começo do arquivo.
    static func sessaoECwd(log: URL) -> (String, String)? {
        guard let h = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? h.close() }
        guard let dados = try? h.read(upToCount: 256 * 1024), !dados.isEmpty else { return nil }
        var sessao: String?
        var cwd: String?
        for linha in dados.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(linha)) as? [String: Any] else { continue }
            if sessao == nil { sessao = JV.texto(obj["session_id"]) }
            if cwd == nil { cwd = JV.texto(obj["cwd"]) }
            if let s = sessao, let c = cwd { return (s, c) }
        }
        return nil
    }

    /// Aspas simples de shell só quando o caminho precisa.
    static func aspas(_ s: String) -> String {
        let seguros = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ seguros.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}
