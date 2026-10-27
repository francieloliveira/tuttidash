import Foundation

/// FRA-522: o que a pílula da barra de menus (NSStatusItem) mostra. Só dados, sem AppKit.
public struct ItemBarra: Equatable, Sendable {
    public var lane: String
    /// Nome claro («Grok CLI»), não o id cru.
    public var titulo: String
    public var pct: Double?
    public var rodando: Bool
}

/// Uma lane ligada na lista do menu da barra. Desligada não entra.
public struct LinhaMenuBarra: Equatable, Sendable {
    public var lane: String
    public var titulo: String
    /// Ligada: o item leva o ponto aceso. A pílula da barra usa o mesmo critério.
    public var acesa: Bool
    public var rodando: Bool
    public var texto: String
}

public struct ResumoBarra: Equatable, Sendable {
    /// Lanes ligadas, na ordem do painel.
    public var itens: [ItemBarra]
    public var rodando: Int
    /// Modo curto: só o número de lanes rodando (quando os itens passam do limite).
    public var compacto: Bool
    /// Texto do modo curto e do leitor de tela.
    public var texto: String

    public static let limiteItens = 5
    /// Teto da pílula da barra, em pontos. Cabe as 5 lanes com % e a seta aberta.
    /// 260 cortava a última — o Grok CLI — quando as cinco estavam ligadas e a pílula
    /// não entrava no modo curto (o curto só começa acima de `limiteItens`).
    public static let larguraMaximaBarra = 360.0

    public static func montar(_ snap: SnapshotPainel?, limite: Int = limiteItens) -> ResumoBarra {
        guard let snap else { return ResumoBarra(itens: [], rodando: 0, compacto: true, texto: "…") }
        let itens = snap.notch.linhas.filter { $0.estado != .desligada }.map {
            ItemBarra(lane: $0.lane, titulo: titulo($0.lane), pct: $0.pct, rodando: $0.estado == .rodando)
        }
        let rodando = itens.filter(\.rodando).count
        let texto = rodando == 1 ? "1 rodando" : "\(rodando) rodando"
        return ResumoBarra(itens: itens, rodando: rodando, compacto: itens.isEmpty || itens.count > limite, texto: texto)
    }

    /// Lanes ligadas, na ordem do painel, para o menu da barra. O notch antigo fica
    /// desligado por padrão (`PreferenciaNotch`); esta lista é a superfície que o app mostra.
    public static func linhasMenu(_ snap: SnapshotPainel?) -> [LinhaMenuBarra] {
        guard let snap else { return [] }
        return snap.notch.linhas.filter { $0.estado != .desligada }.map { linha in
            let nome = titulo(linha.lane)
            return LinhaMenuBarra(
                lane: linha.lane, titulo: nome, acesa: true, rodando: linha.estado == .rodando,
                texto: "\(nome) · \(linha.estado.rotulo) · \(textoPct(linha.pct))")
        }
    }

    /// Leitor de tela da pílula: no modo curto ainda cita cada lane ligada pelo nome.
    public static func rotuloAcessivel(_ r: ResumoBarra) -> String {
        let partes = r.itens.map { "\($0.titulo) \(textoPct($0.pct))" }
        guard !partes.isEmpty else { return "TuttiDash: \(r.texto)" }
        return "TuttiDash: \(r.texto). " + partes.joined(separator: ", ")
    }

    public static func titulo(_ lane: String) -> String {
        ClarezaCota.titulo(nome: lane, rotulo: Agentes.def(lane)?.rotulo ?? lane)
    }

    /// «37%» ou «–» sem dado.
    public static func textoPct(_ pct: Double?) -> String {
        guard let pct else { return "–" }
        return "\(Int(pct.rounded()))%"
    }

    /// Última linha não vazia do log do dispatcher (o «Bulls personal foul.» do placar).
    public static func ultimaLinha(_ log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Preferência do app: a pílula antiga sobre o notch. Desligada por padrão (FRA-522).
/// Com ela desligada, a única pílula é a da barra de menus (`PilulaBarra` + este resumo).
public enum PreferenciaNotch {
    public static let chave = "mostrarPilulaNotch"
    public static func mostrar(_ d: UserDefaults = .standard, argumentos: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        d.bool(forKey: chave) || argumentos.contains("--expandido") || argumentos.contains("--foto")
    }
}
