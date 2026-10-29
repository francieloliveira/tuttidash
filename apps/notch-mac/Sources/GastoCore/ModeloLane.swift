import Foundation

/// Escolha de modelo de uma lane (FRA-521). O mesmo formato que `gasto_lanes/catalogo.py`
/// grava em `lanes.modelo.<lane>`: automático pelo peso do card, ou um modelo fixo.
/// Uma string antiga no config vale como modelo fixo.
public enum ModoModelo: String, Equatable, Hashable, Sendable {
    case auto
    case fixo
}

public struct EscolhaPeso: Equatable, Sendable {
    public var modelo: String
    public var esforco: String
    /// false quando o config não trouxe `esforco` (vale o do manifesto).
    public var esforcoExplicito: Bool

    public init(modelo: String, esforco: String, esforcoExplicito: Bool) {
        self.modelo = modelo
        self.esforco = esforco
        self.esforcoExplicito = esforcoExplicito
    }
}

public struct ConfigModelo: Equatable, Sendable {
    public var modo: ModoModelo
    public var fixo: String
    public var porPeso: [String: EscolhaPeso]
    public var aviso: String
    /// Esforço único do Fixo (PRD de 29/10). Vazio = o esforço de cada peso, como antes.
    public var esforcoFixo: String

    public init(modo: ModoModelo, fixo: String, porPeso: [String: EscolhaPeso], aviso: String,
                esforcoFixo: String = "") {
        self.modo = modo
        self.fixo = fixo
        self.porPeso = porPeso
        self.aviso = aviso
        self.esforcoFixo = esforcoFixo
    }

    public static let automatico = ConfigModelo(modo: .auto, fixo: "", porPeso: [:], aviso: "")
}

public struct ResolucaoModelo: Equatable, Sendable {
    public var modelo: String
    public var fixo: Bool
    public var aviso: String
    /// Esforço que vai ao CLI (vazio = o CLI não recebe esforço).
    public var esforco: String

    public init(modelo: String, fixo: Bool, aviso: String, esforco: String = "") {
        self.modelo = modelo
        self.fixo = fixo
        self.aviso = aviso
        self.esforco = esforco
    }
}

public enum ModeloLane {
    public static let pesos = ["baixo", "medio", "alto"]

    public static func rotuloPeso(_ peso: String) -> String {
        switch peso {
        case "baixo": return "Baixo"
        case "medio": return "Médio"
        case "alto": return "Alto"
        default: return peso
        }
    }

    /// «lane · modelo (peso)» do card em curso.
    public static func textoPainel(lane: String, modelo: String, peso: String) -> String {
        let nome = modelo.isEmpty ? "padrão do CLI" : modelo
        return "\(lane) · \(nome) (\(rotuloPeso(peso).lowercased()))"
    }

    public static func padrao(_ agente: CatalogoAgentes.ModeloAgente) -> [String: EscolhaPeso] {
        var saida: [String: EscolhaPeso] = [:]
        for peso in pesos {
            let modelo = agente.modelos[peso]
            saida[peso] = EscolhaPeso(modelo: modelo?.id ?? "",
                                      esforco: esforco(das: modelo?.flags ?? []),
                                      esforcoExplicito: false)
        }
        return saida
    }

    public static func esforco(das flags: [String]) -> String {
        if let i = flags.firstIndex(of: "--effort"), i + 1 < flags.count {
            return flags[i + 1]
        }
        for tok in flags where tok.contains("model_reasoning_effort=") {
            return String(tok.split(separator: "=", maxSplits: 1).last ?? "")
        }
        return ""
    }

    public static func prefixo(_ padrao: [String: EscolhaPeso]) -> String {
        for peso in pesos {
            let id = padrao[peso]?.modelo ?? ""
            if let barra = id.firstIndex(of: "/") {
                return String(id[...barra])
            }
        }
        return ""
    }

    public static func comPrefixo(_ modelo: String, _ prefixo: String) -> String {
        let m = modelo.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return "" }
        if !prefixo.isEmpty && !m.contains("/") { return prefixo + m }
        return m
    }

    /// Valor cru do config: a chave plana antiga ganha da aninhada, como no dispatcher.
    public static func bruto(lane: String, em dados: [String: Any]) -> Any? {
        if let plano = dados["lanes.modelo.\(lane)"] {
            if let s = plano as? String {
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            } else if !(plano is NSNull) {
                return plano
            }
        }
        return Configuracao.valor("lanes.modelo.\(lane)", em: dados)
    }

    public static func ler(_ valor: Any?) -> ConfigModelo {
        if let s = valor as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .automatico : ConfigModelo(modo: .fixo, fixo: t, porPeso: [:], aviso: "")
        }
        guard let d = valor as? [String: Any] else { return .automatico }
        let modo = modoDe(d)
        var por: [String: EscolhaPeso] = [:]
        let bruto = d["porPeso"] as? [String: Any] ?? [:]
        for peso in pesos {
            guard let item = bruto[peso] else { continue }
            if let s = item as? String {
                por[peso] = EscolhaPeso(modelo: s, esforco: "", esforcoExplicito: false)
            } else if let obj = item as? [String: Any] {
                let temEsforco = obj["esforco"] != nil
                por[peso] = EscolhaPeso(modelo: (obj["modelo"] as? String) ?? "",
                                        esforco: (obj["esforco"] as? String) ?? "",
                                        esforcoExplicito: temEsforco)
            }
        }
        return ConfigModelo(modo: modo, fixo: (d["fixo"] as? String) ?? "",
                            porPeso: por, aviso: (d["aviso"] as? String) ?? "",
                            esforcoFixo: (d["esforco"] as? String) ?? "")
    }

    public static func paraGravar(_ cfg: ConfigModelo) -> [String: Any] {
        var por: [String: Any] = [:]
        for (peso, escolha) in cfg.porPeso {
            var item: [String: Any] = ["modelo": escolha.modelo]
            if escolha.esforcoExplicito { item["esforco"] = escolha.esforco }
            por[peso] = item
        }
        var saida: [String: Any] = ["modo": cfg.modo.rawValue, "fixo": cfg.fixo, "porPeso": por]
        if !cfg.esforcoFixo.isEmpty { saida["esforco"] = cfg.esforcoFixo }
        if !cfg.aviso.isEmpty { saida["aviso"] = cfg.aviso }
        return saida
    }

    public static func sumiu(_ modelo: String, lane: String, prefixo: String, cache: CacheModelos) -> Bool {
        let listas = cache.listas[lane] ?? []
        let anteriores = cache.anteriores[lane] ?? []
        guard !modelo.isEmpty, !listas.isEmpty, !anteriores.isEmpty else { return false }
        return contem(modelo, prefixo, anteriores) && !contem(modelo, prefixo, listas)
    }

    /// Mesmo texto do `catalogo.AVISO_FIXO_VAZIO` (Python).
    public static let avisoFixoVazio = "modo fixo sem modelo; a lane usa o automático"

    /// O CLI da lane recebe esforço (lista do agente ou flag no manifesto). OpenCode: não.
    public static func temEsforco(_ agente: CatalogoAgentes.ModeloAgente?) -> Bool {
        guard let agente else { return false }
        if !(agente.revisao?.flagEsforco ?? []).isEmpty { return true }
        return pesos.contains { !esforco(das: agente.flags($0)).isEmpty }
    }

    /// Esforços que o modelo aceita, na mesma ordem do `catalogo.esforcos_aceitos` (Python):
    /// o que a ferramenta informou para o modelo, depois para todos (`*`), depois o manifesto.
    public static func esforcosAceitos(lane: String, modelo: String, agente: CatalogoAgentes.ModeloAgente?,
                                       cache: CacheModelos) -> [String] {
        guard temEsforco(agente) else { return [] }
        let pref = agente.map { prefixo(padrao($0)) } ?? ""
        let porLane = cache.esforcos[lane] ?? [:]
        let semPrefixo = (!pref.isEmpty && modelo.hasPrefix(pref)) ? String(modelo.dropFirst(pref.count)) : modelo
        for chave in [comPrefixo(modelo, pref), semPrefixo] where !chave.isEmpty {
            if let l = porLane[chave], !l.isEmpty { return l }
        }
        if let l = porLane["*"], !l.isEmpty { return l }
        return agente?.revisao?.esforcos ?? []
    }

    static func avisoEsforcoPadrao(_ esforco: String, modelo: String) -> String {
        "o esforço padrão \(esforco) não vale para \(modelo.isEmpty ? "o modelo padrão" : modelo); o CLI usa o dele"
    }

    /// Esforço gravado que o modelo de agora não aceita volta ao padrão (seletor ou id digitado).
    /// Devolve a config ajustada e o aviso para a tela; sem mudança, a mesma config e nil.
    public static func ajustarEsforco(_ cfg: ConfigModelo, agente: CatalogoAgentes.ModeloAgente,
                                      cache: CacheModelos) -> (ConfigModelo, String?) {
        var saida = cfg
        var aviso: String?
        let padrao = padrao(agente)
        for peso in pesos {
            guard var escolha = saida.porPeso[peso], escolha.esforcoExplicito, !escolha.esforco.isEmpty else { continue }
            let modelo = escolha.modelo.isEmpty ? (padrao[peso]?.modelo ?? "") : escolha.modelo
            if !esforcosAceitos(lane: agente.nome, modelo: modelo, agente: agente, cache: cache).contains(escolha.esforco) {
                aviso = aviso ?? "O esforço \(escolha.esforco) não vale para \(modelo); voltou ao padrão."
                escolha.esforco = ""
                escolha.esforcoExplicito = false
                saida.porPeso[peso] = escolha
            }
        }
        if !saida.esforcoFixo.isEmpty, !saida.fixo.isEmpty,
           !esforcosAceitos(lane: agente.nome, modelo: saida.fixo, agente: agente, cache: cache).contains(saida.esforcoFixo) {
            aviso = aviso ?? "O esforço \(saida.esforcoFixo) não vale para \(saida.fixo); voltou ao padrão."
            saida.esforcoFixo = ""
        }
        return (saida, aviso)
    }

    static func avisoEsforco(_ esforco: String, modelo: String, padrao: String) -> String {
        let alvo = modelo.isEmpty ? "o modelo padrão" : modelo
        return "o esforço \(esforco) não vale para \(alvo); usei o padrão" + (padrao.isEmpty ? "" : " (\(padrao))")
    }

    public static func resolver(lane: String, peso: String, config: ConfigModelo,
                                padrao: [String: EscolhaPeso], cache: CacheModelos,
                                agente: CatalogoAgentes.ModeloAgente? = nil) -> ResolucaoModelo {
        let pref = prefixo(padrao)
        let base = padrao[peso] ?? EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
        var r: ResolucaoModelo
        var pedido = ""
        if config.modo == .fixo && !config.fixo.isEmpty
            && !sumiu(config.fixo, lane: lane, prefixo: pref, cache: cache) {
            r = ResolucaoModelo(modelo: comPrefixo(config.fixo, pref), fixo: true, aviso: "modelo fixo")
            pedido = config.esforcoFixo
        } else {
            var aviso = ""
            if config.modo == .fixo {
                // FRA-564: «Fixo» sem modelo roda no automático; o aviso deixa isso visível.
                aviso = config.fixo.isEmpty ? avisoFixoVazio
                    : "o modelo \(comPrefixo(config.fixo, pref)) saiu da lista; a lane voltou ao automático"
            }
            r = resolverAuto(lane: lane, peso: peso, config: config, base: base, pref: pref,
                             cache: cache, avisoForcado: aviso)
            pedido = config.porPeso[peso].map { $0.esforcoExplicito ? $0.esforco : "" } ?? ""
        }
        r.esforco = base.esforco
        guard agente != nil else { return r }  // sem o manifesto não há como validar: vale o padrão
        let aceitos = esforcosAceitos(lane: lane, modelo: r.modelo, agente: agente, cache: cache)
        var explicito = false
        if !pedido.isEmpty {
            if aceitos.contains(pedido) {
                r.esforco = pedido
                explicito = true
            } else {
                r.aviso = avisoEsforco(pedido, modelo: r.modelo, padrao: base.esforco)
            }
        }
        if !explicito, !r.esforco.isEmpty, !aceitos.isEmpty, !aceitos.contains(r.esforco) {
            // O padrão do peso também não vai ao CLI se o modelo não o aceita (revisão do PR #17).
            r.aviso = avisoEsforcoPadrao(r.esforco, modelo: r.modelo)
            r.esforco = ""
        }
        return r
    }

    /// Devolve a config já em automático quando o modelo escolhido saiu da lista.
    public static func reconciliar(_ cfg: ConfigModelo, lane: String, padrao: [String: EscolhaPeso],
                                   cache: CacheModelos) -> ConfigModelo {
        let pref = prefixo(padrao)
        var saida = cfg
        var mudou = false
        if saida.modo == .fixo && !saida.fixo.isEmpty && sumiu(saida.fixo, lane: lane, prefixo: pref, cache: cache) {
            saida.modo = .auto
            saida.aviso = "o modelo \(comPrefixo(saida.fixo, pref)) saiu da lista; a lane voltou ao automático"
            mudou = true
        }
        for peso in pesos {
            guard var escolha = saida.porPeso[peso], !escolha.modelo.isEmpty,
                  sumiu(escolha.modelo, lane: lane, prefixo: pref, cache: cache) else { continue }
            let base = padrao[peso] ?? EscolhaPeso(modelo: "", esforco: "", esforcoExplicito: false)
            if saida.aviso.isEmpty {
                saida.aviso = "o modelo \(comPrefixo(escolha.modelo, pref)) saiu da lista; o peso \(peso) voltou ao padrão"
            }
            escolha.modelo = base.modelo
            if !escolha.esforcoExplicito { escolha.esforco = base.esforco }
            saida.porPeso[peso] = escolha
            mudou = true
        }
        return mudou ? saida : cfg
    }

    /// Textos do painel: «lane · modelo (peso)» do card em curso e o aviso, se houver.
    public static func textosPainel(rodando: [EstadoLanes.LaneRodando], dados: [String: Any],
                                    cache: CacheModelos, agentes: [CatalogoAgentes.ModeloAgente]) -> (texto: [String: String], aviso: [String: String]) {
        var texto: [String: String] = [:]
        var aviso: [String: String] = [:]
        let porNome = Dictionary(uniqueKeysWithValues: agentes.map { ($0.nome, $0) })
        for lane in rodando {
            if let modelo = lane.modelo, !modelo.isEmpty {
                let peso = lane.effort ?? "medio"
                texto[lane.lane] = textoPainel(lane: lane.lane, modelo: modelo, peso: peso)
                if let gravado = lane.avisoModelo, !gravado.isEmpty {
                    aviso[lane.lane] = gravado
                } else if lane.modeloFixo {
                    aviso[lane.lane] = "modelo fixo"
                }
            }
        }
        let nomes = Set(agentes.map(\.nome)).union(rodando.map(\.lane))
        for nome in nomes {
            let agente = porNome[nome]
            let padrao = agente.map(padrao) ?? [:]
            let cfg = ler(bruto(lane: nome, em: dados))
            let emCurso = rodando.first { $0.lane == nome }
            let peso = emCurso?.effort ?? "medio"
            let r = resolver(lane: nome, peso: peso, config: cfg, padrao: padrao, cache: cache, agente: agente)
            if texto[nome] == nil, emCurso != nil, !r.modelo.isEmpty {
                texto[nome] = textoPainel(lane: nome, modelo: r.modelo, peso: peso)
            }
            if aviso[nome] == nil {
                if !r.aviso.isEmpty {
                    aviso[nome] = r.aviso
                } else if !cfg.aviso.isEmpty && emCurso == nil {
                    aviso[nome] = cfg.aviso
                }
            }
        }
        return (texto, aviso)
    }

    private static func resolverAuto(lane: String, peso: String, config: ConfigModelo, base: EscolhaPeso,
                                     pref: String, cache: CacheModelos, avisoForcado: String) -> ResolucaoModelo {
        var aviso = avisoForcado
        var modelo = ""
        if let escolha = config.porPeso[peso], !escolha.modelo.isEmpty {
            if sumiu(escolha.modelo, lane: lane, prefixo: pref, cache: cache) {
                if aviso.isEmpty {
                    aviso = "o modelo \(comPrefixo(escolha.modelo, pref)) saiu da lista; o peso \(peso) voltou ao padrão"
                }
            } else {
                modelo = comPrefixo(escolha.modelo, pref)
            }
        }
        if modelo.isEmpty { modelo = base.modelo }
        if aviso.isEmpty { aviso = config.aviso }
        return ResolucaoModelo(modelo: modelo, fixo: false, aviso: aviso)
    }

    private static func modoDe(_ d: [String: Any]) -> ModoModelo {
        switch d["modo"] as? String {
        case "fixo": return .fixo
        case "auto": return .auto
        default:
            if let fixo = d["fixo"] as? String, !fixo.isEmpty { return .fixo }
            return .auto
        }
    }

    private static func contem(_ modelo: String, _ prefixo: String, _ lista: [String]) -> Bool {
        let alvo = comPrefixo(modelo, prefixo)
        return lista.contains { comPrefixo($0, prefixo) == alvo }
    }
}
