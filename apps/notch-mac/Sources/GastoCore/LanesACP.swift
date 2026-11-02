import Foundation

/// Lanes ACP: instâncias de uma conta (PRD lanes-acp). Mesmo formato e mesma validação do
/// Python (`gasto_lanes/catalogo.py`, `validar_instancias`), para o app e o dispatcher
/// verem as mesmas lanes.
///
/// A config só escolhe nome, agente, conta, modelo e se está ligada. Comando, config
/// "perguntar" e privacidade vêm do manifesto assinado do agente.
public struct LaneACP: Equatable, Sendable, Identifiable {
    public var nome: String
    public var agente: String
    public var conta: String
    public var modelo: String
    public var ligada: Bool
    public var id: String { nome }

    public init(nome: String, agente: String, conta: String = "", modelo: String, ligada: Bool = false) {
        self.nome = nome; self.agente = agente
        self.conta = conta.isEmpty ? agente : conta
        let m = modelo.trimmingCharacters(in: .whitespaces)
        self.modelo = m.isEmpty ? LanesACP.modeloAuto : m   // vazio = automático, como no Python
        self.ligada = ligada
    }

    public func dict() -> [String: Any] {
        ["nome": nome, "agente": agente, "conta": conta, "modelo": modelo, "ligada": ligada]
    }
}

public enum LanesACP {
    public static let chave = "acp"
    public static let chaveLimite = "limite_conta"   // PRD lanes-v2 (a chave do piloto, `acp_limite_conta`, não vale mais)
    public static let chavePreco = "acp_preco_conta"
    /// Modelo "auto": segue o peso do card, como as lanes do catálogo.
    public static let modeloAuto = "auto"
    public static let tamanhoMaximo = 40
    private static let reNome = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]{1,39}$")
    private static let reModelo = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$")

    /// Agentes que falam ACP (bloco `acp` no manifesto).
    public static func agentesACP(_ catalogo: [Agentes.Def] = Agentes.todos) -> Set<String> {
        Set(catalogo.filter(\.acp).map(\.nome))
    }

    static func casa(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func lanes(_ dados: [String: Any]) -> Any? {
        if let plano = dados["lanes.\(chave)"] { return plano }
        return (dados["lanes"] as? [String: Any])?[chave]
    }

    /// Motivo para recusar a lane, ou nil. `outras` são as outras lanes ACP já aceitas.
    public static func problema(_ l: LaneACP, outras: [LaneACP] = [],
                                catalogo: [Agentes.Def] = Agentes.todos) -> String? {
        if !casa(reNome, l.nome) {
            return String(localized: "Nome inválido: use a–z, 0–9 e hífen, de 2 a 40 caracteres, começando por letra.")
        }
        if l.nome == "auto" || catalogo.contains(where: { $0.nome == l.nome }) || outras.contains(where: { $0.nome == l.nome }) {
            return String(localized: "Nome já usado por outra lane.")
        }
        guard agentesACP(catalogo).contains(l.agente) else {
            return String(localized: "O agente \(l.agente) não fala ACP neste app.")
        }
        if l.modelo != modeloAuto && !casa(reModelo, l.modelo) {
            return String(localized: "Modelo inválido.")
        }
        return nil
    }

    /// Lanes válidas da config, na ordem da config. Entrada inválida fica de fora.
    public static func ler(_ dados: [String: Any], catalogo: [Agentes.Def] = Agentes.todos) -> [LaneACP] {
        guard let lista = lanes(dados) as? [Any] else { return [] }
        var saida: [LaneACP] = []
        for item in lista {
            guard let d = item as? [String: Any] else { continue }
            let l = LaneACP(nome: (d["nome"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            agente: (d["agente"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            conta: (d["conta"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                            modelo: { let m = (d["modelo"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                                      return m.isEmpty ? modeloAuto : m }(),
                            ligada: JV.ehBool(d["ligada"]) && (d["ligada"] as? Bool) == true)
            if problema(l, outras: saida, catalogo: catalogo) == nil { saida.append(l) }
        }
        return saida
    }

    /// Grava a lista em `lanes.acp` (a chave plana antiga sai), preservando o resto.
    public static func gravar(_ lanes: [LaneACP], em dados: inout [String: Any]) {
        dados.removeValue(forKey: "lanes.\(chave)")
        var bloco = (dados["lanes"] as? [String: Any]) ?? [:]
        bloco[chave] = lanes.map { $0.dict() }
        dados["lanes"] = bloco
    }

    private static func porConta(_ dados: [String: Any], _ sub: String) -> [String: Any] {
        if let plano = dados["lanes.\(sub)"] as? [String: Any] { return plano }
        return ((dados["lanes"] as? [String: Any])?[sub] as? [String: Any]) ?? [:]
    }

    /// Limite opcional de lanes rodando ao mesmo tempo na conta. nil = sem limite (padrão):
    /// quem segura é a medida de cota da conta.
    public static func limite(conta: String, _ dados: [String: Any]) -> Int? {
        let v = porConta(dados, chaveLimite)[conta]
        guard let n = v as? NSNumber, !JV.ehBool(v), n.intValue >= 1 else { return nil }
        return n.intValue
    }

    public static func gravarLimite(_ n: Int?, conta: String, em dados: inout [String: Any]) {
        var mapa = porConta(dados, chaveLimite)
        if let n { mapa[conta] = max(1, n) } else { mapa.removeValue(forKey: conta) }
        var bloco = (dados["lanes"] as? [String: Any]) ?? [:]
        bloco[chaveLimite] = mapa
        dados["lanes"] = bloco
    }

    /// Preço mensal do plano informado pelo dono (US$). nil = não informado.
    public static func preco(conta: String, _ dados: [String: Any]) -> Double? {
        let v = porConta(dados, chavePreco)[conta]
        guard let n = v as? NSNumber, !JV.ehBool(v), n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }

    public static func gravarPreco(_ valor: Double?, conta: String, em dados: inout [String: Any]) {
        var mapa = porConta(dados, chavePreco)
        if let valor, valor >= 0 { mapa[conta] = valor } else { mapa.removeValue(forKey: conta) }
        var bloco = (dados["lanes"] as? [String: Any]) ?? [:]
        bloco[chavePreco] = mapa
        dados["lanes"] = bloco
    }

    /// Nome a partir do agente e do modelo (`opencode` + `opencode/beam-free` → `opencode-beam-free`).
    /// Mesmo algoritmo do `catalogo.nome_sugerido`.
    public static func nomeSugerido(agente: String, modelo: String, usados: Set<String> = [],
                                    catalogo: [Agentes.Def] = Agentes.todos) -> String {
        let base = modelo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        let bruto = "\(agente)-\(base.isEmpty ? "lane" : base)".lowercased()
        var nome = ""
        var hifen = false
        for ch in bruto.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                nome.unicodeScalars.append(ch); hifen = false
            } else if !hifen && !nome.isEmpty {
                nome.append("-"); hifen = true
            }
        }
        while nome.hasSuffix("-") { nome.removeLast() }
        if nome.isEmpty || !(nome.first!.isLetter) { nome = "lane-" + nome }
        nome = String(nome.prefix(tamanhoMaximo))
        while nome.hasSuffix("-") { nome.removeLast() }
        let ocupados = usados.union(catalogo.map(\.nome)).union(["auto"])
        var final = nome
        var i = 2
        while ocupados.contains(final) || final.count < 2 {
            let sufixo = "-\(i)"
            var corte = String(nome.prefix(tamanhoMaximo - sufixo.count))
            while corte.hasSuffix("-") { corte.removeLast() }
            final = corte + sufixo
            i += 1
        }
        return final
    }

    /// Modelo do agente em cada peso (`modelos.<peso>.id` do manifesto): o que "auto" usa.
    public static func modelosPorPeso(agente: String) -> [String: String] {
        guard let m = CatalogoAgentes.carregar().first(where: { $0.nome == agente }) else { return [:] }
        return m.modelos.compactMapValues { $0.id.isEmpty ? nil : $0.id }
    }

    /// Lanes ACP como `Agentes.Def`: rótulo, sigla e cores do agente; nome, conta e modelo da lane.
    public static func defs(_ dados: [String: Any], catalogo: [Agentes.Def] = Agentes.todos) -> [Agentes.Def] {
        let porNome = Dictionary(catalogo.map { ($0.nome, $0) }, uniquingKeysWith: { a, _ in a })
        return ler(dados, catalogo: catalogo).compactMap { l in
            guard var d = porNome[l.agente] else { return nil }
            let curto = l.modelo == modeloAuto ? String(localized: "automático")
                : (l.modelo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? l.modelo)
            d.nome = l.nome
            d.rotulo = curto.isEmpty ? "\(d.rotulo) · \(l.nome)" : "\(d.rotulo) · \(curto)"
            d.painel = true
            d.optIn = false
            d.agente = l.agente
            d.conta = l.conta
            d.modelo = l.modelo
            d.ordem = d.ordem * 100 + 50
            return d
        }
    }

    /// Lanes ACP que a config liga, cuja conta está ativa (`tipo` ou `id` de uma conta ativa).
    public static func habilitadas(_ dados: [String: Any], contasAtivas: Set<String>,
                                   catalogo: [Agentes.Def] = Agentes.todos) -> Set<String> {
        Set(ler(dados, catalogo: catalogo).filter { $0.ligada && contasAtivas.contains($0.conta) }.map(\.nome))
    }
}
