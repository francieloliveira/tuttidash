import Foundation

/// Leitura (só leitura) do estado das lanes: `heartbeat.json` e `lane-<lane>.json`.
/// Porta do `gasto_lanes/estado.py`.
public struct EstadoLanes: Equatable, Sendable {
    public struct Heartbeat: Equatable, Sendable {
        public var at: String
        public var dryRun: Bool
        public var habilitadas: [String]
        /// Lanes com execução real, quando o heartbeat traz `implemented`.
        public var implemented: [String] = []
    }

    public struct LaneRodando: Equatable, Sendable {
        public var lane: String
        public var card: String
        public var titulo: String?
        public var startedAt: String?
        public var log: String
        public var travada: Bool
        /// Branch do card (`branch` no `lane-<lane>.json`). Sem chave, nil.
        public var branch: String? = nil
        /// Peso do card em curso (`effort`: baixo, medio, alto).
        public var effort: String? = nil
        /// Modelo com que a lane assumiu o card.
        public var modelo: String? = nil
        /// true quando a lane rodou com modelo fixo.
        public var modeloFixo: Bool = false
        /// «modelo fixo» ou o aviso de modelo que saiu da lista.
        public var avisoModelo: String? = nil
        /// PR em rascunho enquanto o check remoto não fecha (FRA-611).
        public var provaRemotaURL: String? = nil
        /// Link do check `prova-remota`, quando o GitHub já publicou.
        public var provaRemotaCheck: String? = nil
        /// Desde quando o PR espera o check (`prova_remota_desde`, epoch).
        public var provaRemotaDesde: Date? = nil
        public var provaRemotaSHA: String? = nil

        /// Nome do log (o caminho vem do Mac; compara pelo nome).
        public var nomeLog: String {
            String(log.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(log))
        }
    }

    public var heartbeat: Heartbeat?
    public var lanes: [LaneRodando]

    public init(heartbeat: Heartbeat? = nil, lanes: [LaneRodando] = []) {
        self.heartbeat = heartbeat
        self.lanes = lanes
    }

    public var logsEmAndamento: Set<String> { Set(lanes.map(\.nomeLog)) }

    private static let nomeLane = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9_-]*$"#)

    /// Forma gravada por `save_state()` no dispatcher.py: `lane` igual ao nome do arquivo,
    /// `card` e `log` como texto não vazio. Outros `lane-*.json` (ex.: `lane-mcp.json`) ficam de fora.
    public static func ehEstadoDeLane(nomeArquivo: String, dados: Any?) -> Bool {
        guard let d = dados as? [String: Any], nomeArquivo.hasPrefix("lane-"), nomeArquivo.hasSuffix(".json") else {
            return false
        }
        let stem = String(nomeArquivo.dropFirst("lane-".count).dropLast(".json".count))
        let ns = stem as NSString
        guard nomeLane.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) != nil else { return false }
        guard (d["lane"] as? String) == stem else { return false }
        return JV.texto(d["card"]) != nil && JV.texto(d["log"]) != nil
    }

    public static func ler(pasta: URL) -> EstadoLanes {
        var out = EstadoLanes()
        let fm = FileManager.default
        var ehPasta: ObjCBool = false
        guard fm.fileExists(atPath: pasta.path, isDirectory: &ehPasta), ehPasta.boolValue else { return out }
        if let d = lerJSON(pasta.appendingPathComponent("heartbeat.json")) as? [String: Any] {
            out.heartbeat = heartbeat(d)
        }
        let nomes = ((try? fm.contentsOfDirectory(atPath: pasta.path)) ?? [])
            .filter { $0.hasPrefix("lane-") && $0.hasSuffix(".json") }.sorted()
        for nome in nomes {
            let dados = lerJSON(pasta.appendingPathComponent(nome))
            if let l = laneRodando(nomeArquivo: nome, dados: dados) { out.lanes.append(l) }
        }
        return out
    }

    static func heartbeat(_ d: [String: Any]) -> Heartbeat? {
        guard let at = JV.texto(d["at"]) else { return nil }
        let hab = (d["enabled"] as? [Any] ?? []).compactMap { JV.texto($0) }
        let impl = (d["implemented"] as? [Any] ?? []).compactMap { JV.texto($0) }
        let dry = d["dry_run"].map { JV.verdadeiro($0) } ?? true
        return Heartbeat(at: at, dryRun: dry, habilitadas: hab, implemented: impl)
    }

    public static func laneRodando(nomeArquivo: String, dados: Any?) -> LaneRodando? {
        guard ehEstadoDeLane(nomeArquivo: nomeArquivo, dados: dados), let d = dados as? [String: Any],
              let lane = d["lane"] as? String, let card = JV.texto(d["card"]), let log = JV.texto(d["log"]) else {
            return nil
        }
        return LaneRodando(lane: lane, card: card.uppercased(), titulo: JV.texto(d["title"]),
                           startedAt: JV.texto(d["started_at"]), log: log,
                           travada: JV.verdadeiro(d["stuck"]), branch: JV.texto(d["branch"]),
                           effort: JV.texto(d["effort"]), modelo: JV.texto(d["modelo"]),
                           modeloFixo: JV.verdadeiro(d["modelo_fixo"]),
                           avisoModelo: JV.texto(d["aviso_modelo"]),
                           provaRemotaURL: JV.texto(d["prova_remota_url"]),
                           provaRemotaCheck: JV.texto(d["prova_remota_check"]),
                           provaRemotaDesde: JV.numero(d["prova_remota_desde"]).map { Date(timeIntervalSince1970: $0) },
                           provaRemotaSHA: JV.texto(d["prova_remota_sha"]))
    }

    static func lerJSON(_ url: URL) -> Any? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let dados = try? h.readToEnd() else { return nil }
        return try? JSONSerialization.jsonObject(with: dados, options: [.fragmentsAllowed])
    }
}
