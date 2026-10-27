import Foundation

/// Uma linha do cadastro de contas acompanhadas.
///
/// O `id` é a chave (o coletor guarda a leitura por id). O `tipo` diz como medir
/// e tem que ser um tipo que o app já conhece (`ContaUso.tipos`, ou o nome de um
/// agente já gravado, como `opencode-go`). `nova` só existe na tela: o rascunho
/// não vai para o arquivo até o Salvar, e é nele que o tipo ainda pode mudar.
public struct ContaCadastro: Identifiable, Equatable, Sendable {
    public var id: String
    public var tipo: String
    public var rotulo: String
    public var nome: String
    public var sigla: String
    /// false deixa a conta na lista sem entrar em limites, gasto e retomadas.
    public var ativo: Bool
    /// true até gravar. Não vai para o JSON.
    public var nova: Bool
    /// Usuário do GitHub, só na conta Copilot. Não é segredo.
    public var githubUsuario: String
    /// Texto da cota mensal (requisições). Vazio = não informada.
    public var cotaTexto: String
    /// Caminho do arquivo do token. O token em si não fica neste campo.
    public var arquivoToken: String

    public init(id: String, tipo: String, rotulo: String, nome: String, sigla: String,
                ativo: Bool = true, nova: Bool = false, githubUsuario: String = "",
                cotaTexto: String = "", arquivoToken: String = "") {
        self.id = id
        self.tipo = tipo
        self.rotulo = rotulo
        self.nome = nome
        self.sigla = sigla
        self.ativo = ativo
        self.nova = nova
        self.githubUsuario = githubUsuario
        self.cotaTexto = cotaTexto
        self.arquivoToken = arquivoToken
    }

    public init(conta: ContaUso, nova: Bool = false) {
        self.init(id: conta.id, tipo: conta.tipo, rotulo: conta.rotulo, nome: conta.nome,
                  sigla: conta.sigla, ativo: conta.ativo, nova: nova,
                  githubUsuario: conta.githubUsuario,
                  cotaTexto: conta.cotaPremiumMes.map(String.init) ?? "",
                  arquivoToken: conta.arquivoToken)
    }

    /// Nome da linha. Apelido gravado fica; cursor e grok crus viram os nomes claros.
    public var titulo: String {
        let salvo = rotulo.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = salvo.isEmpty ? nome.trimmingCharacters(in: .whitespacesAndNewlines) : salvo
        if base.isEmpty { return String(localized: "(sem nome)") }
        return ClarezaCota.rotuloConta(tipo: tipo, rotuloSalvo: base)
    }

    /// Tipo embaixo do nome. Se o nome já é o tipo, mostra o detalhe (Grok CLI, SuperGrok).
    public var subtitulo: String {
        let tipoNome = ContasConfig.rotuloDoTipo(tipo)
        if titulo.caseInsensitiveCompare(tipoNome) != .orderedSame { return tipoNome }
        return ClarezaCota.detalhe(nome: tipo) ?? tipoNome
    }

    public var mostraSubtitulo: Bool {
        subtitulo.caseInsensitiveCompare(titulo) != .orderedSame
    }

    /// Formato da chave `contas`. `ativo` só entra quando é false: arquivo antigo
    /// sem a chave continua significando ligada.
    public func dict(mesclando base: [String: Any]? = nil) -> [String: Any] {
        var item = base ?? [:]
        item["id"] = id
        item["tipo"] = tipo
        item["rotulo"] = rotulo
        item["nome"] = nome
        item["sigla"] = sigla
        if ativo { item.removeValue(forKey: "ativo") } else { item["ativo"] = false }
        if tipo == "copilot" {
            let usuario = githubUsuario.trimmingCharacters(in: .whitespacesAndNewlines)
            if usuario.isEmpty { item.removeValue(forKey: "githubUsuario") } else { item["githubUsuario"] = usuario }
            if let cota = ContasConfig.cota(cotaTexto) { item["cotaPremiumMes"] = cota }
            else { item.removeValue(forKey: "cotaPremiumMes") }
            let arquivo = arquivoToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if arquivo.isEmpty { item.removeValue(forKey: "arquivoToken") } else { item["arquivoToken"] = arquivo }
        }
        for segredo in Self.chavesSegredo { item.removeValue(forKey: segredo) }
        return item
    }

    /// Nomes que não podem ir para o config.json. O token mora no Keychain ou no arquivo.
    static let chavesSegredo = ["token", "github_token", "access_token", "pat", "authorization"]

    public var dict: [String: Any] { dict(mesclando: nil) }
}

/// Leitura e escrita da chave `contas` no config.json.
///
/// Sem a chave, ou com a lista vazia / ilegível, devolve `ContaUso.padrao` para a
/// tela não abrir em branco. Uma lista gravada com contas válidas volta como está,
/// inclusive `opencode-go` (habilita a lane, mesmo sem medidor próprio).
public enum ContasConfig {
    public static let chave = "contas"

    /// Tipos que uma conta nova pode usar. Sai do catálogo, não de um nome livre.
    public static var tiposNovos: [String] { ContaUso.tipos }

    public static func ler(_ dados: [String: Any]) -> [ContaCadastro] {
        guard let bruto = dados[chave] as? [[String: Any]] else { return semear() }
        var vistos = Set<String>()
        let saida = bruto.compactMap { item -> ContaCadastro? in
            guard let id = texto(item["id"]), vistos.insert(id).inserted else { return nil }
            guard let tipo = texto(item["tipo"]), tipoAceito(tipo) else { return nil }
            return ContaCadastro(id: id, tipo: tipo,
                                 rotulo: texto(item["rotulo"]) ?? id,
                                 nome: texto(item["nome"]) ?? id,
                                 sigla: texto(item["sigla"]) ?? String(id.prefix(1)).uppercased(),
                                 ativo: ativo(item["ativo"]), nova: false,
                                 githubUsuario: texto(item["githubUsuario"]) ?? "",
                                 cotaTexto: cota(item["cotaPremiumMes"]).map(String.init) ?? "",
                                 arquivoToken: texto(item["arquivoToken"]) ?? "")
        }
        return saida.isEmpty ? semear() : saida
    }

    /// Grava as contas já salvas. Rascunho (`nova`) e tipo que o app não mede ficam
    /// de fora. Sem nenhuma conta ativa, desliga `uso_contas`. Não liga de volta:
    /// o interruptor «Consultar limites das contas» continua mandando nisso.
    public static func gravar(_ contas: [ContaCadastro], em dados: inout [String: Any]) {
        let anteriores = (dados[chave] as? [[String: Any]]) ?? []
        var porId: [String: [String: Any]] = [:]
        for item in anteriores {
            if let id = item["id"] as? String, porId[id] == nil { porId[id] = item }
        }
        var vistos = Set<String>()
        let persistir: [ContaCadastro] = contas.compactMap { c in
            guard !c.nova else { return nil }
            let n = normalizar(c)
            guard !n.id.isEmpty, tipoAceito(n.tipo), vistos.insert(n.id).inserted else { return nil }
            return n
        }
        dados[chave] = persistir.map { $0.dict(mesclando: porId[$0.id]) }
        if !persistir.contains(where: \.ativo) {
            dados["uso_contas"] = false
        }
    }

    /// Tipo de medição, ou nome de agente já usado na chave (migração do formato atual).
    public static func tipoAceito(_ tipo: String) -> Bool {
        ContaUso.tipos.contains(tipo) || Agentes.ordem.contains(tipo)
    }

    /// Rótulo do tipo para o picker e o subtítulo. Vem do catálogo de agentes.
    public static func rotuloDoTipo(_ tipo: String) -> String {
        if let a = agente(do: tipo) {
            return ClarezaCota.rotuloConta(tipo: a.nome, rotuloSalvo: a.rotulo)
        }
        return tipo
    }

    public static func agente(do tipo: String) -> Agentes.Def? {
        if let a = Agentes.def(tipo) { return a }
        return Agentes.todos.first { $0.tipoUso == tipo }
    }

    /// Primeiro tipo do catálogo que ainda não está na lista. Se todos já estão,
    /// o primeiro do catálogo: o coletor guarda cada leitura pelo id, então uma
    /// segunda conta do mesmo tipo pode existir, com outro id e a mesma credencial.
    public static func primeiroTipoLivre(nas atuais: [ContaCadastro]) -> String {
        let usados = Set(atuais.map(\.tipo))
        if let livre = ContaUso.tipos.first(where: { !usados.contains($0) }) { return livre }
        return ContaUso.tipos.first ?? ""
    }

    public static func idLivre(tipo: String, nas atuais: [ContaCadastro]) -> String {
        let usados = Set(atuais.map(\.id))
        if !usados.contains(tipo) { return tipo }
        var n = 2
        while usados.contains("\(tipo)-\(n)") { n += 1 }
        return "\(tipo)-\(n)"
    }

    public static func rascunho(nas atuais: [ContaCadastro]) -> ContaCadastro {
        let tipo = primeiroTipoLivre(nas: atuais)
        let id = idLivre(tipo: tipo, nas: atuais)
        return ContaCadastro(id: id, tipo: tipo, rotulo: rotuloDoTipo(tipo), nome: id,
                             sigla: agente(do: tipo)?.sigla ?? String(id.prefix(1)).uppercased(),
                             ativo: true, nova: true)
    }

    /// Troca o tipo de uma conta nova e acompanha id, rótulo e sigla se ainda eram os
    /// gerados. Conta já gravada não muda de tipo: o coletor e as lanes já a conhecem.
    public static func aplicarTipo(_ conta: ContaCadastro, tipo: String, nas todas: [ContaCadastro]) -> ContaCadastro {
        guard conta.nova, ContaUso.tipos.contains(tipo), tipo != conta.tipo else { return conta }
        var c = conta
        let antigo = c.tipo
        let outras = todas.filter { $0.id != c.id }
        let idAutomatico = c.id == antigo || c.id.hasPrefix(antigo + "-")
        let rotuloAutomatico = c.rotulo.isEmpty || c.rotulo == rotuloDoTipo(antigo)
        let nomeAutomatico = c.nome.isEmpty || c.nome == antigo || c.nome == c.id
        let siglaAntiga = agente(do: antigo)?.sigla
        let siglaAutomatica = c.sigla.isEmpty || c.sigla == siglaAntiga
        c.tipo = tipo
        if idAutomatico { c.id = idLivre(tipo: tipo, nas: outras) }
        if rotuloAutomatico { c.rotulo = rotuloDoTipo(tipo) }
        if nomeAutomatico { c.nome = c.id }
        if siglaAutomatica {
            c.sigla = agente(do: tipo)?.sigla ?? String(c.id.prefix(1)).uppercased()
        }
        return c
    }

    public static func normalizar(_ c: ContaCadastro) -> ContaCadastro {
        var c = c
        c.id = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
        c.tipo = c.tipo.trimmingCharacters(in: .whitespacesAndNewlines)
        c.rotulo = c.rotulo.trimmingCharacters(in: .whitespacesAndNewlines)
        c.nome = c.nome.trimmingCharacters(in: .whitespacesAndNewlines)
        c.sigla = c.sigla.trimmingCharacters(in: .whitespacesAndNewlines)
        c.githubUsuario = c.githubUsuario.trimmingCharacters(in: .whitespacesAndNewlines)
        c.cotaTexto = c.cotaTexto.trimmingCharacters(in: .whitespacesAndNewlines)
        c.arquivoToken = c.arquivoToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.rotulo.isEmpty { c.rotulo = rotuloDoTipo(c.tipo) }
        if c.nome.isEmpty { c.nome = c.id }
        if c.sigla.isEmpty {
            c.sigla = agente(do: c.tipo)?.sigla ?? String(c.id.prefix(1)).uppercased()
        }
        return c
    }

    /// nil = pode gravar. A lista `todas` inclui a própria conta.
    public static func problema(_ conta: ContaCadastro, nas todas: [ContaCadastro]) -> String? {
        let id = conta.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return String(localized: "A conta precisa de um id.") }
        if todas.filter({ $0.id == id }).count > 1 {
            return String(localized: "Já existe uma conta com este id.")
        }
        let aceito = conta.nova ? ContaUso.tipos.contains(conta.tipo) : tipoAceito(conta.tipo)
        if !aceito { return String(localized: "Escolha um tipo que o app já mede.") }
        if conta.tipo == "copilot", !conta.cotaTexto.isEmpty, cota(conta.cotaTexto) == nil {
            return String(localized: "A cota do Copilot é um número inteiro de requisições por mês.")
        }
        return nil
    }

    /// Cota mensal. nil = ausente ou ilegível. 0 fica 0 (o coletor trata como sem cota, sem %).
    public static func cota(_ v: Any?) -> Int? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            if t.isEmpty { return nil }
            guard let d = Double(t), d.isFinite, d >= 0, d == d.rounded(), d <= Double(Int.max) else { return nil }
            return Int(d)
        }
        guard let d = JV.numero(v), d.isFinite, d >= 0, d == d.rounded(), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    /// Aviso, não trava o Salvar. A segunda conta do mesmo tipo lê a mesma credencial.
    public static func avisoTipo(_ conta: ContaCadastro, nas todas: [ContaCadastro]) -> String? {
        guard todas.contains(where: { $0.id != conta.id && $0.tipo == conta.tipo }) else { return nil }
        return String(localized: "Já existe uma conta deste tipo. As duas leem a mesma credencial.")
    }

    /// A última conta gravada fica. Rascunho pode sair mesmo sozinho.
    public static func podeRemover(_ contas: [ContaCadastro], _ alvo: ContaCadastro) -> Bool {
        if alvo.nova { return true }
        return contas.filter { !$0.nova }.count > 1
    }

    public static func remover(_ alvo: ContaCadastro, de contas: [ContaCadastro]) -> [ContaCadastro]? {
        guard podeRemover(contas, alvo) else { return nil }
        return contas.filter { $0.id != alvo.id }
    }

    /// Ausente = ligada. Aceita o bool do JSON e o texto "false".
    public static func ativo(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return true }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        switch "\(v)".trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "nao", "não", "n", "no", "off": return false
        default: return true
        }
    }

    public static func entradaAtiva(_ item: [String: Any]) -> Bool {
        ativo(item["ativo"])
    }

    private static func semear() -> [ContaCadastro] {
        ContaUso.padrao.map { ContaCadastro(conta: $0) }
    }

    private static func texto(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
