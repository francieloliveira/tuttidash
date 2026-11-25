import Foundation

/// O contexto de uma conversa do Brainstorm: o projeto do Linear e, quando ele tem mais
/// de um repositório (FRA-711), o repositório escolhido.
///
/// O projeto dá o norte e o destino dos cards no Linear. O repositório escolhido dá a
/// pasta que o agente lê e o slug que vira a etiqueta `repo:<slug>` do card — é por ela
/// que o dispatcher sabe em qual repositório trabalhar. Sem escolha (ou projeto de um
/// repositório só), vale o principal, e o card sai sem etiqueta, como sempre saiu.
///
/// A escolha é da tela: não mexe na config nem no projeto que o dispatcher trabalha.
public struct ContextoBrainstorm: Equatable, Sendable {
    public var projeto: ProjetoCadastro?
    public var repositorio: RepositorioCadastro?

    public init(projeto: ProjetoCadastro?, repositorio: RepositorioCadastro? = nil) {
        self.projeto = projeto
        // Repositório de outro projeto (slug reaproveitado) não vale: fica o principal.
        if let repositorio, let projeto, projeto.repos.contains(repositorio) {
            self.repositorio = repositorio
        } else {
            self.repositorio = nil
        }
    }

    /// Pasta que o agente lê e onde o norte mora.
    public var repo: String { repositorio?.repo ?? projeto?.repo ?? "" }

    /// Nome do projeto, para a tela.
    public var nome: String { projeto?.nome ?? "" }

    /// Arquivo de norte, relativo ao repositório.
    public var norte: String { projeto?.norte ?? "" }

    /// Slug da etiqueta; vazio = repositório principal do projeto.
    public var slug: String { repositorio?.slug ?? "" }

    /// Etiqueta a pôr no card; vazia = a principal (o dispatcher não precisa dela).
    public var etiquetaDeRepo: String { repositorio?.nomeDaEtiqueta ?? "" }

    /// Repositórios do projeto que podem virar etiqueta `repo:<slug>`.
    public var repositoriosDoProjeto: [RepositorioCadastro] {
        (projeto?.repos ?? []).filter { RepositorioCadastro.slugValido($0.slug) }
    }

    /// O projeto tem de 2 repositórios utilizáveis para cima: só aí há o que escolher.
    public var temEscolhaDeRepositorio: Bool { repositoriosDoProjeto.count > 1 }
}
