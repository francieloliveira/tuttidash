import Foundation

/// Escolhas do Linear guardadas na config (FRA-299): id para os scripts e nome para a tela.
/// A tela nunca mostra um id cru.
public struct CampoLinear: Identifiable, Equatable, Sendable {
    public var id: String { chave }
    public enum Fonte: Sendable { case estados, rotulos }
    /// Chave do id na config (`linear.state_in_progress_id`); no rótulo, guarda o próprio nome.
    public let chave: String
    /// Chave do nome na config (`linear.state_in_progress_name`).
    public let chaveNome: String
    public let fonte: Fonte
    public let titulo: String
    public let ajuda: String
    /// true quando o valor guardado é o nome (etiqueta), não um id.
    public var porNome: Bool { fonte == .rotulos }

    /// Sem time nem projeto globais (FRA-567): cada projeto do cadastro diz o seu.
    public static func todos() -> [CampoLinear] { colunas() + [etiqueta()] }

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
        case .estados: return opcoes.estados
        case .rotulos: return opcoes.rotulos
        }
    }

    /// Valores a gravar ao escolher um item: id e nome (ou só o nome, na etiqueta).
    public static func valores(_ c: CampoLinear, _ item: ItemLinear) -> [(String, String)] {
        c.porNome ? [(c.chave, item.nome)] : [(c.chave, item.id), (c.chaveNome, item.nome)]
    }

    /// Time de onde vêm as colunas: o do projeto padrão do cadastro (FRA-567).
    public static func timeDasColunas(projetos: [ProjetoLinear], cadastro: [ProjetoCadastro]) -> String? {
        guard let padrao = ProjetosConfig.padrao(cadastro) else { return nil }
        return projetos.first { $0.id == padrao.projetoID }?.timeID
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
