import Foundation

/// Quem gerencia as lanes: decide pela % (auto) ou forçado. Grava `bots_chave.modo_forcado`
/// no config.json; o `bots-chave` lê pelo `cfg`. `PAUSE.manual` continua vencendo tudo.
public enum ModoForcado: String, CaseIterable, Identifiable, Sendable {
    case auto, vigia, grokbot
    public var id: String { rawValue }
    public static let chave = "bots_chave.modo_forcado"

    public var rotulo: String {
        switch self {
        case .auto: return String(localized: "Automático")
        case .vigia: return String(localized: "Sempre o vigia")
        case .grokbot: return String(localized: "Sempre o gestor")
        }
    }

    /// Valor desconhecido ou ausente vira `.auto` (igual ao bots-chave).
    public init(texto: String?) {
        self = ModoForcado(rawValue: (texto ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .auto
    }
}

/// Estado gravado pelo bots-chave em ~/.transcentia/bots/modo.json.
public struct EstadoChave: Equatable, Sendable {
    public let modo: String
    public let pct: Double?
    public let medidoEm: String?
    public let motivo: String?

    public init(modo: String, pct: Double?, medidoEm: String?, motivo: String?) {
        self.modo = modo; self.pct = pct; self.medidoEm = medidoEm; self.motivo = motivo
    }

    public init?(dados: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any],
              let m = o["modo"] as? String else { return nil }
        self.init(modo: m, pct: (o["grokbot_pct"] as? NSNumber)?.doubleValue,
                  medidoEm: o["medido_em"] as? String, motivo: o["motivo"] as? String)
    }

    /// Ex.: "vigia · 94% · 22:56".
    public var resumo: String {
        var partes = [modo]
        if let p = pct { partes.append(Formatar.n(p.rounded()) + "%") }
        if let h = Self.hora(medidoEm) { partes.append(h) }
        return partes.joined(separator: " · ")
    }

    /// "2026-10-10 22:56:35-0300" -> "22:56".
    static func hora(_ s: String?) -> String? {
        guard let s, s.count >= 16 else { return nil }
        let i = s.index(s.startIndex, offsetBy: 11)
        return String(s[i..<s.index(i, offsetBy: 5)])
    }
}

/// Lê/grava o modo forçado e roda o bots-chave na hora para a troca ser imediata.
public final class GestaoLanes {
    public let modelo: ModeloAjustes
    public let executar: (URL) -> Int32

    public init(modelo: ModeloAjustes, executar: @escaping (URL) -> Int32 = GestaoLanes.rodar) {
        self.modelo = modelo; self.executar = executar
    }

    public var home: URL { modelo.home }
    public var modoJSON: URL { home.appendingPathComponent(".transcentia/bots/modo.json") }
    public var script: URL { home.appendingPathComponent(".transcentia/tools/bots-chave") }

    public var modo: ModoForcado { ModoForcado(texto: modelo.valorTexto(ModoForcado.chave)) }

    /// Só leitura: a tela nunca cria nem apaga estes arquivos (quem mexe é o bots-chave e o dono).
    public var pause: URL { home.appendingPathComponent(".transcentia/bots/PAUSE") }
    public var pauseManual: URL { home.appendingPathComponent(".transcentia/bots/PAUSE.manual") }
    public var gestor: URL { home.appendingPathComponent(".transcentia/bots/gestor") }
    public var limitePct: Double { Double(modelo.valorTexto("bots_chave.limite_pct") ?? "") ?? 90 }

    public func quemCuida(chaveLigada: Bool?) -> QuemCuida {
        let fm = FileManager.default
        let g = (try? String(contentsOf: gestor, encoding: .utf8))?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return QuemCuida.calcular(modo: modo, estado: estado(), pauseManual: fm.fileExists(atPath: pauseManual.path),
                                  pause: fm.fileExists(atPath: pause.path), gestor: g, limitePct: limitePct, chaveLigada: chaveLigada)
    }

    public func estado() -> EstadoChave? {
        (try? Data(contentsOf: modoJSON)).flatMap(EstadoChave.init(dados:))
    }

    /// Grava no config e roda o bots-chave. Devolve o código de saída do script.
    @discardableResult
    public func escolher(_ m: ModoForcado) throws -> Int32 {
        try modelo.definirValor(ModoForcado.chave, m.rawValue)
        return executar(script)
    }

    /// Roda pelo `Subprocesso`: é chamado no clique, na thread da interface (FRA-579).
    public static func rodar(_ script: URL) -> Int32 {
        Subprocesso.rodar(script.path, []).codigo
    }
}

/// Quem está cuidando das lanes agora, com o motivo em palavras simples (FRA-531).
/// O que vale é o arquivo PAUSE (com ele, o vigia fica parado e o gestor cuida); o resto explica o porquê.
public enum ResponsavelLanes: Equatable, Sendable {
    case gestor, vigia, pausaGeral, outro(String)
}

public struct QuemCuida: Equatable, Sendable {
    public let responsavel: ResponsavelLanes
    public let titulo: String
    public let motivo: String
    /// Avisos extras (chave desligada, troca pendente).
    public let avisos: [String]

    public static func calcular(modo: ModoForcado, estado: EstadoChave?, pauseManual: Bool, pause: Bool,
                                gestor: String?, limitePct: Double, chaveLigada: Bool?) -> QuemCuida {
        let lim = Formatar.n(limitePct.rounded())
        var avisos: [String] = []
        if chaveLigada == false {
            avisos.append(String(localized: "A TuttiChave está desligada: a troca automática fica congelada como está."))
        }
        if pauseManual {
            return QuemCuida(responsavel: .pausaGeral, titulo: String(localized: "Tudo em pausa"),
                             motivo: String(localized: "Você pausou tudo. A chave não troca nada até você tirar a pausa geral."),
                             avisos: avisos)
        }
        let validos = ["grokbot", "vigia", "opencode", "claude", "agente", "humano"]
        if let gestor = gestor?.lowercased(), validos.contains(String(gestor.split(separator: ":").first ?? "")) {
            let resp: ResponsavelLanes = gestor == "vigia" ? .vigia : gestor == "grokbot" ? .gestor : .outro(gestor)
            return QuemCuida(responsavel: resp, titulo: titulo(resp),
                             motivo: String(localized: "A gestão foi passada à mão para \(nome(resp)). A chave só registra, não decide."),
                             avisos: avisos)
        }
        let resp: ResponsavelLanes = pause ? .gestor : .vigia
        let motivo: String
        switch modo {
        case .grokbot: motivo = String(localized: "Você escolheu «Sempre o gestor».")
        case .vigia: motivo = String(localized: "Você escolheu «Sempre o vigia».")
        case .auto:
            if let p = estado?.pct {
                let pct = Formatar.n(p.rounded())
                motivo = p < limitePct
                    ? String(localized: "O uso do Grok Bot está em \(pct)%, abaixo do limite de \(lim)%. O gestor cuida.")
                    : String(localized: "O uso do Grok Bot chegou a \(pct)%, o limite é \(lim)%. O vigia assume.")
            } else if estado != nil {
                motivo = String(localized: "Não deu para medir o uso do Grok Bot. Na dúvida, o vigia assume.")
            } else {
                motivo = String(localized: "A chave ainda não conferiu. Até lá vale quem já estava cuidando.")
            }
        }
        let esperado: ResponsavelLanes? = {
            switch modo {
            case .grokbot: return .gestor
            case .vigia: return .vigia
            case .auto:
                guard let e = estado else { return nil }
                return e.modo == "grokbot" ? .gestor : e.modo == "vigia" ? .vigia : nil
            }
        }()
        if let esperado, esperado != resp {
            avisos.append(String(localized: "A troca para \(nome(esperado)) acontece na próxima conferência da chave."))
        }
        return QuemCuida(responsavel: resp, titulo: titulo(resp), motivo: motivo, avisos: avisos)
    }

    static func nome(_ r: ResponsavelLanes) -> String {
        switch r {
        case .gestor: return String(localized: "o gestor")
        case .vigia: return String(localized: "o vigia")
        case .pausaGeral: return String(localized: "ninguém")
        case .outro(let n): return n
        }
    }

    static func titulo(_ r: ResponsavelLanes) -> String {
        switch r {
        case .gestor: return String(localized: "O gestor está cuidando")
        case .vigia: return String(localized: "O vigia está cuidando")
        case .pausaGeral: return String(localized: "Tudo em pausa")
        case .outro(let n): return String(localized: "\(n) está cuidando")
        }
    }
}
