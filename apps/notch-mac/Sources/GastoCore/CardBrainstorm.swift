import Foundation

/// Contrato do card que sai do Brainstorm (PRD do norte, fase 2).
///
/// O corpo é o único texto que o agente da lane lê (`.lane/card.md`): objetivo, o trecho do
/// norte que o card serve, a história, aceite observável com a prova, o que fica fora,
/// arquivos prováveis e dependências. Workspace, protocolo e DONE já estão no `lane-prompt.md`.
public enum CardBrainstorm {
    /// Campos que travam o «Aprovar» quando vazios.
    public enum Falta: String, CaseIterable, Sendable {
        case objetivo = "Objetivo"
        case aceite = "Aceite"
        case foraDeEscopo = "Fora de escopo"
    }

    static func limpar(_ xs: [String]) -> [String] {
        xs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func vazio(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// O que falta para o card poder ser aprovado. Vazio = completo.
    public static func faltando(objetivo: String, aceite: [String], foraDeEscopo: [String]) -> [Falta] {
        var f: [Falta] = []
        if vazio(objetivo) { f.append(.objetivo) }
        if limpar(aceite).isEmpty { f.append(.aceite) }
        if limpar(foraDeEscopo).isEmpty { f.append(.foraDeEscopo) }
        return f
    }

    /// Corpo do card no Linear, no formato do PRD.
    public static func corpo(objetivo: String, norteServido: String, historia: String, aceite: [String],
                             prova: String, foraDeEscopo: [String], arquivos: [String], dependencias: [String],
                             esforco: String, lane: String) -> String {
        var l: [String] = []
        func secao(_ titulo: String, _ linhas: [String]) {
            guard !linhas.isEmpty else { return }
            if !l.isEmpty { l.append("") }
            l.append("## \(titulo)")
            l += linhas
        }
        let obj = objetivo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !obj.isEmpty { secao("Objetivo", [obj]) }
        let norte = norteServido.trimmingCharacters(in: .whitespacesAndNewlines)
        if !norte.isEmpty {
            secao("Norte servido", norte.components(separatedBy: "\n").map { $0.hasPrefix(">") ? $0 : "> \($0)" })
        }
        let hist = historia.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hist.isEmpty { secao("História", [hist]) }
        var ac = limpar(aceite).map { "- [ ] \($0)" }
        let p = prova.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { ac.append("- [ ] Prova: \(p)") }
        secao("Aceite", ac)
        secao("Fora de escopo", limpar(foraDeEscopo).map { "- \($0)" })
        secao("Arquivos / módulos prováveis", limpar(arquivos).map { "- \($0)" })
        let deps = limpar(dependencias).filter { !["nenhuma", "nenhum", "-"].contains($0.lowercased()) }
        secao("Dependências", deps.isEmpty ? ["- nenhuma"] : deps.map { "- \($0)" })
        l += ["", "_Etiquetas do processo: \(esforco) · \(lane)_"]
        return l.joined(separator: "\n")
    }

    // MARK: - Contexto do projeto para o prompt

    public static let tetoNorte = 4_000
    public static let tetoMapa = 3_000

    /// §1–§4 do norte (o glossário fica de fora) e o mapa, lidos do repositório do projeto,
    /// cada um com teto. nil quando o arquivo não existe ou o caminho não serve.
    public static func contexto(repo: URL, norte: String) -> (norte: String?, mapa: String?) {
        func ler(_ rel: String, teto: Int) -> String? {
            guard !rel.isEmpty, !rel.contains(".."), !rel.hasPrefix("/") else { return nil }
            let url = repo.appendingPathComponent(rel)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
            guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let limpo = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpo.isEmpty else { return nil }
            return NorteRascunho.cortar(limpo, teto: teto)
        }
        let caminho = norte.isEmpty ? NorteRascunho.caminhoPadrao : norte
        var n = ler(caminho, teto: tetoNorte * 2)
        if let t = n, let g = t.range(of: "## §5") { n = String(t[..<g.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        n = n.map { NorteRascunho.cortar($0, teto: tetoNorte) }
        return (n, ler("docs/produto/mapa.md", teto: tetoMapa))
    }
}
