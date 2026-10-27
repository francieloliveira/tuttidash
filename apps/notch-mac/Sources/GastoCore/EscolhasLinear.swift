import Foundation

/// Escolhas do Linear guardadas na config (FRA-299): id para os scripts e nome para a tela.
/// A tela nunca mostra um id cru.
public struct CampoLinear: Identifiable, Equatable, Sendable {
    public var id: String { chave }
    public enum Fonte: Sendable { case times, projetos, estados, rotulos }
    /// Chave do id na config (`linear.project_ios_id`); no rótulo, guarda o próprio nome.
    public let chave: String
    /// Chave do nome na config (`linear.project_name`).
    public let chaveNome: String
    public let fonte: Fonte
    public let titulo: String
    public let ajuda: String
    /// true quando o valor guardado é o nome (etiqueta), não um id.
    public var porNome: Bool { fonte == .rotulos }

    public static func todos() -> [CampoLinear] { ondeTrabalha() + colunas() + [etiqueta()] }

    public static func ondeTrabalha() -> [CampoLinear] {
        [CampoLinear(chave: "linear.team_id", chaveNome: "linear.team_name", fonte: .times,
                     titulo: String(localized: "Time"), ajuda: String(localized: "O time do Linear onde ficam os cards.")),
         CampoLinear(chave: "linear.project_ios_id", chaveNome: "linear.project_name", fonte: .projetos,
                     titulo: String(localized: "Projeto"), ajuda: String(localized: "Só os cards deste projeto entram nas lanes."))]
    }

    public static func colunas() -> [CampoLinear] {
        [CampoLinear(chave: "linear.state_in_progress_id", chaveNome: "linear.state_in_progress_name", fonte: .estados,
                     titulo: String(localized: "Coluna que dispara a lane"),
                     ajuda: String(localized: "Ao mover um card para esta coluna, uma lane começa a trabalhar nele.")),
         CampoLinear(chave: "linear.state_in_review_id", chaveNome: "linear.state_in_review_name", fonte: .estados,
                     titulo: String(localized: "Coluna de revisão"),
                     ajuda: String(localized: "Para onde o card vai quando a lane termina e abre o PR."))]
    }

    public static func etiqueta() -> CampoLinear {
        CampoLinear(chave: "linear.owner_label", chaveNome: "linear.owner_label", fonte: .rotulos,
                    titulo: String(localized: "Etiqueta de \"precisa de você\""),
                    ajuda: String(localized: "A lane põe esta etiqueta quando para e precisa de uma decisão sua."))
    }
}

public enum EscolhasLinear {
    /// Texto a mostrar para o valor guardado: o nome, nunca o id. nil = nada escolhido.
    public static func nomeExibido(_ c: CampoLinear, em dados: [String: Any]) -> String? {
        let txt = { (k: String) in Configuracao.valor(k, em: dados).map { "\($0)" } }
        guard let v = txt(c.chave), !v.isEmpty else { return nil }
        if c.porNome { return v }
        return txt(c.chaveNome) ?? String(localized: "(escolhido antes; conecte para ver o nome)")
    }

    public static func itens(_ c: CampoLinear, times: [ItemLinear], opcoes: OpcoesTime) -> [ItemLinear] {
        switch c.fonte {
        case .times: return times
        case .projetos: return opcoes.projetos
        case .estados: return opcoes.estados
        case .rotulos: return opcoes.rotulos
        }
    }

    /// Valores a gravar ao escolher um item: id e nome (ou só o nome, na etiqueta).
    public static func valores(_ c: CampoLinear, _ item: ItemLinear) -> [(String, String)] {
        c.porNome ? [(c.chave, item.nome)] : [(c.chave, item.id), (c.chaveNome, item.nome)]
    }

    /// Depois de conectar: o time a escolher sozinho (só quando há exatamente um e nenhum escolhido).
    public static func timeAutomatico(times: [ItemLinear], escolhido: String?) -> ItemLinear? {
        guard escolhido?.isEmpty ?? true, times.count == 1 else { return nil }
        return times[0]
    }

    /// Nomes atualizados vindos da API para ids já guardados (ex.: alguém renomeou a coluna).
    public static func nomesResolvidos(dados: [String: Any], times: [ItemLinear], opcoes: OpcoesTime) -> [(String, String)] {
        CampoLinear.todos().filter { !$0.porNome }.compactMap { c in
            guard let id = Configuracao.valor(c.chave, em: dados).map({ "\($0)" }),
                  let item = itens(c, times: times, opcoes: opcoes).first(where: { $0.id == id }),
                  Configuracao.valor(c.chaveNome, em: dados).map({ "\($0)" }) != item.nome else { return nil }
            return (c.chaveNome, item.nome)
        }
    }
}
