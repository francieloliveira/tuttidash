import Foundation

/// FRA-531: retorno ativo de cada ação. A lógica (estados, textos, níveis) fica aqui para ter teste;
/// a aparência (botão, aviso, barra) fica em NotchGasto/Retorno.swift.
public enum EstadoAcao: Equatable, Sendable {
    case ocioso
    case rodando(desde: Date)
    case ok(String, em: Date)
    case erro(String, em: Date)

    public var rodando: Bool { if case .rodando = self { return true }; return false }
}

/// Máquina de estados de uma ação: ocioso -> rodando -> ok/erro -> (some sozinho) ocioso.
public struct MaquinaAcao: Equatable, Sendable {
    public private(set) var estado: EstadoAcao = .ocioso
    /// Quanto tempo o aviso de sucesso e o de erro ficam na tela.
    public static let tempoOk: TimeInterval = 2.5
    public static let tempoErro: TimeInterval = 6

    public init() {}

    /// false se a ação já está rodando (clique duplo não dispara duas vezes).
    @discardableResult
    public mutating func iniciar(agora: Date = Date()) -> Bool {
        if estado.rodando { return false }
        estado = .rodando(desde: agora); return true
    }

    public mutating func concluir(_ mensagem: String, agora: Date = Date()) { estado = .ok(mensagem, em: agora) }
    public mutating func falhar(_ motivo: String, agora: Date = Date()) { estado = .erro(motivo, em: agora) }

    /// Volta a ocioso quando o aviso já ficou tempo suficiente. Rodando nunca expira.
    public mutating func expirar(agora: Date = Date()) {
        switch estado {
        case let .ok(_, em) where agora.timeIntervalSince(em) >= Self.tempoOk: estado = .ocioso
        case let .erro(_, em) where agora.timeIntervalSince(em) >= Self.tempoErro: estado = .ocioso
        default: break
        }
    }

    /// Há quanto tempo está rodando (nil fora de rodando).
    public func decorrido(agora: Date = Date()) -> TimeInterval? {
        if case let .rodando(d) = estado { return max(0, agora.timeIntervalSince(d)) }
        return nil
    }

    /// Motivo do erro em pt-BR, curto, para o aviso.
    public static func motivo(_ erro: Error) -> String {
        if case ModeloAjustes.Erro.invalido(let m) = erro { return m }
        let t = (erro as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Erro sem descrição.") : t
    }
}

public enum TextoTempo {
    /// "agora", "há 12 s", "há 3 min", "há 2 h".
    public static func ha(_ data: Date?, agora: Date = Date()) -> String {
        guard let data else { return String(localized: "sem leitura") }
        let s = Int(agora.timeIntervalSince(data))
        if s < 5 { return String(localized: "agora") }
        if s < 60 { return String(localized: "há \(s) s") }
        if s < 3600 { return String(localized: "há \(s / 60) min") }
        return String(localized: "há \(s / 3600) h")
    }

    /// "atualizado agora", "atualizado há 12 s".
    public static func atualizado(_ data: Date?, agora: Date = Date()) -> String {
        guard data != nil else { return String(localized: "ainda sem leitura") }
        return String(localized: "atualizado \(ha(data, agora: agora))")
    }

    /// "45 s", "2 min 05 s", "1 h 03 min".
    public static func duracao(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }
}

/// Progresso de um processo longo (build, prova, ciclo do dispatcher).
public struct ProgressoProcesso: Equatable, Sendable {
    /// nil = indeterminado.
    public let fracao: Double?
    public let etapa: String?
    public let inicio: Date?

    public init(fracao: Double? = nil, etapa: String? = nil, inicio: Date? = nil) {
        self.fracao = fracao.map { min(max($0, 0), 1) }; self.etapa = etapa; self.inicio = inicio
    }

    /// Fração estimada pelo tempo, com teto de 95% (nunca diz 100% antes de acabar).
    public static func estimado(inicio: Date, duracaoTipica: TimeInterval, etapa: String? = nil, agora: Date = Date()) -> ProgressoProcesso {
        guard duracaoTipica > 0 else { return ProgressoProcesso(etapa: etapa, inicio: inicio) }
        return ProgressoProcesso(fracao: min(0.95, agora.timeIntervalSince(inicio) / duracaoTipica), etapa: etapa, inicio: inicio)
    }

    /// "na prova · 4 min 10 s".
    public func legenda(agora: Date = Date()) -> String {
        var p: [String] = []
        if let etapa, !etapa.isEmpty { p.append(etapa) }
        if let inicio { p.append(TextoTempo.duracao(agora.timeIntervalSince(inicio))) }
        return p.joined(separator: " · ")
    }
}

extension BuildPainel {
    /// Barra da build em curso: «fase do agente» ou «na prova», estimada pela duração típica
    /// (passou dela, vira indeterminada).
    /// nil quando a build já terminou.
    public func progresso(tipica: TimeInterval, agora: Date = Date()) -> ProgressoProcesso? {
        guard status == .emAndamento || naProva, let inicio else { return nil }
        let etapa = naProva ? String(localized: "na prova") : String(localized: "fase do agente")
        // Passou do tempo típico: a barra corre sem estimativa (não finge que está quase no fim).
        if agora.timeIntervalSince(inicio) > tipica { return ProgressoProcesso(etapa: etapa, inicio: inicio) }
        return ProgressoProcesso.estimado(inicio: inicio, duracaoTipica: tipica, etapa: etapa, agora: agora)
    }

    /// Mediana das builds concluídas (padrão 20 min sem histórico).
    public static func duracaoTipica(_ builds: [BuildPainel]) -> TimeInterval {
        let d = builds.filter { $0.status == .ok }.compactMap(\.duracaoMs).sorted()
        guard !d.isEmpty else { return 20 * 60 }
        return TimeInterval(d[d.count / 2]) / 1000
    }
}
