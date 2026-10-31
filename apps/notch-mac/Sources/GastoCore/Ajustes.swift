import Foundation

/// Campos da janela de Ajustes (FRA-296). Chaves pontuadas iguais às do `cfg`.
public enum TipoCampo: Equatable, Sendable {
    case numero(min: Double, max: Double, inteiro: Bool)
    case texto
    /// Texto que pode ficar vazio (vazio = desligado).
    case textoOpcional
    case caminho(deveExistir: Bool, opcional: Bool)
    case booleano
    case lista
    case escolha([String])
}

public struct CampoAjuste: Identifiable, Sendable {
    public var id: String { chave }
    public let chave: String
    public let rotulo: String
    public let tipo: TipoCampo
    public let padrao: String
    /// Texto curto de ajuda mostrado abaixo do campo (FRA-524).
    public let ajuda: String
    /// Nome em pt-BR de cada valor de uma escolha (ex.: "auto" → "Automático"). Sem nome, mostra o valor.
    public let rotulos: [String: String]
    public init(_ chave: String, _ rotulo: String, _ tipo: TipoCampo, _ padrao: String,
                ajuda: String = "", rotulos: [String: String] = [:]) {
        self.chave = chave; self.rotulo = rotulo; self.tipo = tipo; self.padrao = padrao
        self.ajuda = ajuda; self.rotulos = rotulos
    }
    public func nomeValor(_ v: String) -> String { rotulos[v] ?? v }
    /// "Entre 1 e 100" para números; nil nos outros tipos.
    public var faixa: String? {
        if case let .numero(mn, mx, _) = tipo { return String(localized: "Entre \(Formatar.n(mn)) e \(Formatar.n(mx))") }
        return nil
    }
}

public struct AbaAjustes: Identifiable, Sendable {
    public var id: String { nome }
    public let nome: String
    public let simbolo: String
    public let campos: [CampoAjuste]
    public let nota: String?
    /// true na aba Integrações, que tem a tela própria do Linear.
    public var linear: Bool = false
    /// true na aba Agendas, que mostra o estado e os botões dos jobs.
    public var agendas: Bool = false
    /// true na aba Contas e gasto, que mostra "Quem gerencia as lanes".
    public var gestaoLanes: Bool = false
    /// true na aba Contas, que mostra o cadastro de contas acompanhadas.
    public var contas: Bool = false
    /// true na aba Lanes, que mostra os toggles de enable das lanes.
    public var lanesHabilitadas: Bool = false
    /// true na aba Lanes, que mostra o cadastro de projetos que o dispatcher enxerga.
    public var projetos: Bool = false
    /// true na aba Lanes, que mostra o modelo automático por peso (ou fixo).
    public var modelosLane: Bool = false
}

public enum CatalogoAjustes {
    /// Campos das fontes de uso registradas (FRA-565): cada fonte diz o que lê.
    static func credenciaisContas() -> [CampoAjuste] {
        var vistos = Set<String>()
        return FontesUso.todas.flatMap(\.camposAjuste).filter { vistos.insert($0.chave).inserted }
    }

    /// Revisor dos PRs: a lista de lanes candidatas sai do catálogo de agentes
    /// (quem tem `revisao` no manifesto). Modelo e esforço são herdados da lane
    /// escolhida, não configurados à mão.
    static func camposRevisao(agentes: [CatalogoAgentes.ModeloAgente] = CatalogoAgentes.carregar()) -> [CampoAjuste] {
        let revisores = agentes.filter { $0.revisao != nil && $0.cli != nil }
        let nomes = revisores.isEmpty ? ["claude"] : revisores.map(\.nome)
        let rotulos = Dictionary(uniqueKeysWithValues: revisores.map { ($0.nome, $0.rotulo) })
        return [
            CampoAjuste("revisores.pr.lane", String(localized: "Lane revisora de PR"), .escolha(nomes),
                        nomes.contains("claude") ? "claude" : nomes[0],
                        ajuda: String(localized: "Modelo e esforço vêm desta lane."),
                        rotulos: rotulos),
            CampoAjuste("revisores.pr.independente", String(localized: "Nunca revisar com o mesmo fornecedor que escreveu o PR"), .booleano, "true"),
            CampoAjuste("revisores.pr.reserva", String(localized: "Revisor reserva"), .escolha(["auto"] + nomes), "auto",
                        ajuda: String(localized: "Automático escolhe outra lane com mesmo esforço, ou esforço padrão ou acima."),
                        rotulos: Dictionary(uniqueKeysWithValues: [("auto", String(localized: "Automático (mesmo esforço, ou acima)"))] +
                                                                  revisores.map { ($0.nome, $0.rotulo) })),
        ]
    }

    public static func abas() -> [AbaAjustes] {
        let n = { (a: Double, b: Double) in TipoCampo.numero(min: a, max: b, inteiro: true) }
        let d = { (a: Double, b: Double) in TipoCampo.numero(min: a, max: b, inteiro: false) }
        let esforcos = ["baixo", "medio", "alto"]
        return [
            AbaAjustes(nome: String(localized: "Geral"), simbolo: "gearshape", campos: [
                CampoAjuste("logs_dir", String(localized: "Pasta de logs das lanes"), .caminho(deveExistir: true, opcional: true), "~/" + Legado.logsLanes),
                CampoAjuste("state_dir", String(localized: "Pasta de estado das lanes"), .caminho(deveExistir: true, opcional: true), "~/" + Legado.estadoLanes),
                CampoAjuste("ledger", String(localized: "Arquivo do ledger"), .caminho(deveExistir: false, opcional: true), "~/" + Legado.ledger),
                CampoAjuste("geral.abrir_no_login", String(localized: "Abrir ao iniciar sessão"), .booleano, "false"),
                // geral.tela saiu (FRA-534): a pílula é NSStatusItem e fica onde está a barra de menus.
            ], nota: nil),
            AbaAjustes(nome: String(localized: "Contas e gasto"), simbolo: "dollarsign.circle", campos: [
                CampoAjuste("teto_semanal_usd", String(localized: "Teto semanal (US$, 0 = sem teto)"), d(0, 100_000), "0"),
                CampoAjuste("aviso_pct", String(localized: "Aviso em (% do teto)"), d(1, 100), "80"),
                CampoAjuste("bots_chave.limite_pct", String(localized: "Limite da chave dos bots (%)"), d(1, 100), "90"),
                CampoAjuste("uso_contas", String(localized: "Consultar limites das contas"), .booleano, "true"),
            ] + credenciaisContas(), nota: nil, gestaoLanes: true, contas: true),
            AbaAjustes(nome: String(localized: "Lanes"), simbolo: "arrow.triangle.branch", campos: [
                CampoAjuste("lanes.budget_usd.baixo", String(localized: "Orçamento esforço baixo (US$)"), d(0.5, 500), "3"),
                CampoAjuste("lanes.budget_usd.medio", String(localized: "Orçamento esforço médio (US$)"), d(0.5, 500), "8"),
                CampoAjuste("lanes.budget_usd.alto", String(localized: "Orçamento esforço alto (US$)"), d(0.5, 500), "20"),
                CampoAjuste("lanes.grok_max_turns.baixo", String(localized: "Turnos do grok, baixo"), n(1, 1000), "30"),
                CampoAjuste("lanes.grok_max_turns.medio", String(localized: "Turnos do grok, médio"), n(1, 1000), "60"),
                CampoAjuste("lanes.grok_max_turns.alto", String(localized: "Turnos do grok, alto"), n(1, 1000), "100"),
                CampoAjuste("lanes.lane_timeout_min", String(localized: "Tempo máximo da lane (min)"), n(5, 1440), "90"),
                CampoAjuste("lanes.proof_timeout_min", String(localized: "Tempo máximo da prova (min)"), n(5, 1440), "150"),
                CampoAjuste("lanes.proof_default_suites", String(localized: "Suítes padrão da prova (vírgula)"), .lista, ""),
                CampoAjuste("lanes.effort_default", String(localized: "Esforço padrão"), .escolha(esforcos), "medio"),
            ], nota: String(localized: "O repositório de onde a lane trabalha, a pasta de worktrees, a prova e o freio de caminho protegido saem do cadastro de projetos, abaixo. O modelo de cada lane fica no bloco acima: automático pelo peso do card, ou um modelo fixo."), lanesHabilitadas: true, projetos: true, modelosLane: true),
            AbaAjustes(nome: String(localized: "Bots e revisão"), simbolo: "checkmark.seal", campos: camposRevisao() + [
                CampoAjuste("watch.ordem_needs", String(localized: "Vigia: ordem na conferência da etiqueta do dono (vírgulas)"), .texto, "ollama, opencode, claude"),
                CampoAjuste("watch.ordem_paradas", String(localized: "Vigia: ordem na análise de parada (vírgulas)"), .texto, "local, opencode, claude"),
                CampoAjuste("watch.ordem_revisao", String(localized: "Vigia: ordem na revisão de PR (vírgulas)"), .texto, "escolhido, fallback, opencode-go, claude"),
                CampoAjuste("watch.adaptador_fallback", String(localized: "Vigia: revisor reserva quando o escolhido falha"), .texto, "opencode"),
                CampoAjuste("watch.reconferir_needs_max_s", String(localized: "Reconferir needs sem mudança a cada (s, 0 = só quando o card muda)"), n(0, 2_592_000), "86400"),
                CampoAjuste("privacidade.exigir_sem_treino", String(localized: "OpenCode: só modelo que não treina com o uso (regra de 21/10)"), .booleano, "false"),
                CampoAjuste("privacidade.max_retencao_dias", String(localized: "OpenCode: com a regra de 21/10, aceitar retenção de até (dias; 0 = só retenção zero)"), n(0, 365), "30"),
                CampoAjuste("privacidade.max_idade_dias", String(localized: "OpenCode: bloquear se a conferência de privacidade tiver mais de (dias)"), n(1, 60), "7"),
                CampoAjuste("privacidade.intervalo_h", String(localized: "OpenCode: conferir a privacidade a cada (h)"), n(1, 168), "24"),
            ], nota: String(localized: "O revisor não é uma lane: o dispatcher não o enxerga e o painel não o lista. Estes ajustes valem para qualquer projeto do cadastro.")),
            AbaAjustes(nome: String(localized: "Máquina e testes"), simbolo: "cpu", campos: [
                CampoAjuste("preflight.external_nvme", String(localized: "Disco NVMe externo (opcional)"), .caminho(deveExistir: true, opcional: true), ""),
                CampoAjuste("preflight.jobs", String(localized: "Jobs de build"), n(1, 64), "2"),
                CampoAjuste("preflight.scheme", String(localized: "Scheme do Xcode"), .texto, ""),
                CampoAjuste("preflight.min_free_gb", String(localized: "Mínimo livre em disco (GB)"), d(1, 2000), "10"),
                CampoAjuste("preflight.warn_free_gb", String(localized: "Aviso de disco livre (GB)"), d(1, 2000), "40"),
                CampoAjuste("preflight.max_load", String(localized: "Carga máxima"), d(1, 256), "16"),
                CampoAjuste("preflight.skip_preflight_first", String(localized: "Primeira tentativa sem checagem"), .booleano, "true"),
            ], nota: nil),
            AbaAjustes(nome: String(localized: "Integrações"), simbolo: "link", campos: [],
                       nota: String(localized: "A chave do Linear fica no Keychain do app (proteção de dados), nunca no arquivo. O dispatcher e o vigia usam o proxy local."), linear: true),
            AbaAjustes(nome: String(localized: "Agendas"), simbolo: "clock", campos: [
                CampoAjuste("agendas.dispatcher_s", String(localized: "Dispatcher das lanes (s)"), n(15, 86_400), "60"),
                CampoAjuste("agendas.watch_s", String(localized: "Vigia dos bots (s)"), n(15, 86_400), "180"),
                CampoAjuste("agendas.chave_s", String(localized: "Chave dos bots (s)"), n(15, 86_400), "600"),
            ], nota: String(localized: "Mudar um intervalo recarrega só aquele job, e só se ele foi instalado por aqui."), agendas: true),
            AbaAjustes(nome: String(localized: "Painel"), simbolo: "terminal", campos: [
                CampoAjuste("painel.comando", String(localized: "Comando do painel de logs"), .caminho(deveExistir: true, opcional: true), Legado.painelComando),
                CampoAjuste("painel.lanes_comando", String(localized: "Comando da janela das lanes"), .caminho(deveExistir: true, opcional: true), Legado.lanesComando),
                CampoAjuste("painel.tmux", String(localized: "Caminho do tmux"), .caminho(deveExistir: true, opcional: false), "/opt/homebrew/bin/tmux"),
                CampoAjuste("painel.proof_log_glob", String(localized: "Logs das provas (padrão)"), .texto, ""),
                CampoAjuste("painel.gestor_log_glob", String(localized: "Logs dos testes manuais (padrão)"), .texto, "/tmp/fra*-*.log"),
                CampoAjuste("painel.filtro", String(localized: "Filtro das linhas (regex)"), .texto, "Test Case|error:|Executed|BLOCK|TEST (SUCCEEDED|FAILED)|abortado"),
                CampoAjuste("painel.intervalo_s", String(localized: "Intervalo de troca (s)"), n(1, 3600), "10"),
                CampoAjuste("estresse.intervalo_s", String(localized: "Intervalo da medição de estresse (s)"), n(1, 3600), "15"),
                CampoAjuste("lane_view.pensamento", String(localized: "Mostrar o raciocínio do agente"), .booleano, "true"),
                CampoAjuste("lane_view.pensamento_linhas", String(localized: "Linhas de raciocínio por bloco"), n(0, 200), "14"),
                CampoAjuste("lane_view.diff", String(localized: "Mostrar o diff de cada edição"), .booleano, "true"),
                CampoAjuste("lane_view.diff_linhas", String(localized: "Linhas de diff por edição"), n(0, 200), "14"),
            ], nota: String(localized: "O raciocínio e o diff valem para a janela de cada lane, na próxima tarefa que ela pegar.")),
        ]
    }
}

/// Lê e grava o config.json pelo GastoCore. Sempre grava no arquivo novo (TuttiDash),
/// partindo do conteúdo em uso (novo > provisório > legado), com "version".
public final class ModeloAjustes {
    public let home: URL
    public private(set) var dados: [String: Any]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        dados = Configuracao.lerArquivo(ambiente: [:], home: home)
    }

    public var arquivo: URL { Configuracao.arquivoNovo(home: home) }

    public func texto(_ c: CampoAjuste) -> String {
        guard let v = Configuracao.valor(c.chave, em: dados) else { return c.padrao }
        if let l = v as? [Any] { return l.map { "\($0)" }.joined(separator: ", ") }
        if JV.ehBool(v) { return (v as? NSNumber)?.boolValue == true ? "true" : "false" }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return "\(v)"
    }

    /// nil = válido; senão a mensagem de erro (localizada).
    public func validar(_ c: CampoAjuste, _ t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespaces)
        switch c.tipo {
        case let .numero(mn, mx, inteiro):
            guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v.isFinite else {
                return String(localized: "Digite um número.")
            }
            if inteiro && v != v.rounded() { return String(localized: "Digite um número inteiro.") }
            if v < mn || v > mx {
                return String(localized: "Use um valor entre \(Formatar.n(mn)) e \(Formatar.n(mx)).")
            }
        case let .caminho(existir, opcional):
            if s.isEmpty { return opcional ? nil : String(localized: "Informe um caminho.") }
            if existir {
                let u = Configuracao.expandir(s, ambiente: [:], home: home)
                if !FileManager.default.fileExists(atPath: u.path) { return String(localized: "Caminho não existe.") }
            }
        case .booleano:
            if s != "true" && s != "false" { return String(localized: "Valor inválido.") }
        case let .escolha(ops):
            if !ops.contains(s) { return String(localized: "Escolha uma das opções.") }
        case .texto:
            if s.isEmpty { return String(localized: "Não pode ficar vazio.") }
        case .textoOpcional:
            break
        case .lista:
            if s.split(separator: ",").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return String(localized: "Informe ao menos um item.")
            }
        }
        return nil
    }

    public enum Erro: Error, Equatable { case invalido(String) }

    /// Valida, põe no dicionário e grava o arquivo.
    public func definir(_ c: CampoAjuste, _ t: String) throws {
        if let e = validar(c, t) { throw Erro.invalido(e) }
        let s = t.trimmingCharacters(in: .whitespaces)
        let v: Any
        switch c.tipo {
        case let .numero(_, _, inteiro):
            let d = Double(s.replacingOccurrences(of: ",", with: "."))!
            v = inteiro ? NSNumber(value: Int(d)) : NSNumber(value: d)
        case .booleano: v = NSNumber(value: s == "true")
        case .lista: v = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: v = s
        }
        dados = Self.colocar(v, em: dados, caminho: c.chave.split(separator: ".").map(String.init))
        try salvar()
    }

    /// Grava `lanes.modelo.<lane>` no formato novo e apaga a chave plana antiga, senão
    /// o dispatcher continuaria lendo a string fixa e ignoraria o automático.
    public func definirModelo(_ lane: String, _ cfg: ConfigModelo) throws {
        var d = dados
        d.removeValue(forKey: "lanes.modelo.\(lane)")
        d = Self.colocar(ModeloLane.paraGravar(cfg), em: d, caminho: ["lanes", "modelo", lane])
        dados = d
        try salvar()
    }

    /// Grava um valor já escolhido (ex.: id vindo do Linear) sem passar pelo catálogo.
    public func definirValor(_ chave: String, _ v: Any) throws {
        dados = Self.colocar(v, em: dados, caminho: chave.split(separator: ".").map(String.init))
        try salvar()
    }

    /// Grava o cadastro de projetos na chave `projetos`, preservando as outras
    /// chaves do arquivo. Passa por `ProjetosConfig.gravar` para que nunca saiam
    /// dois projetos marcados como padrão — o Python cairia no primeiro da lista e
    /// o app mostraria outro, e o cadastro ficaria mentindo dos dois jeitos.
    public func definirProjetos(_ projetos: [ProjetoCadastro]) throws {
        var copia = dados
        ProjetosConfig.gravar(projetos, em: &copia)
        dados = copia
        try salvar()
    }

    /// Grava o cadastro na chave `contas`, preservando as outras chaves do arquivo.
    /// Sem nenhuma conta ativa, desliga `uso_contas`. Não mexe em `enabled` nem em PAUSE.
    public func definirContas(_ contas: [ContaCadastro]) throws {
        var copia = dados
        ContasConfig.gravar(contas, em: &copia)
        dados = copia
        try salvar()
    }

    /// "Restaurar padrão" (FRA-524): tira as chaves do arquivo, para valer o padrão do `cfg`.
    /// As outras chaves do arquivo ficam como estão.
    public func restaurar(_ campos: [CampoAjuste]) throws {
        for c in campos { dados = Self.remover(em: dados, caminho: c.chave.split(separator: ".").map(String.init)) }
        try salvar()
    }

    static func remover(em d: [String: Any], caminho: [String]) -> [String: Any] {
        var d = d
        guard let k = caminho.first else { return d }
        if caminho.count == 1 { d.removeValue(forKey: k); return d }
        guard let filho = d[k] as? [String: Any] else { return d }
        d[k] = remover(em: filho, caminho: Array(caminho.dropFirst()))
        return d
    }

    public func valorTexto(_ chave: String) -> String? {
        Configuracao.valor(chave, em: dados).map { "\($0)" }
    }

    static func colocar(_ v: Any, em d: [String: Any], caminho: [String]) -> [String: Any] {
        var d = d
        guard let k = caminho.first else { return d }
        if caminho.count == 1 { d[k] = v; return d }
        d[k] = colocar(v, em: (d[k] as? [String: Any]) ?? [:], caminho: Array(caminho.dropFirst()))
        return d
    }

    public func salvar() throws {
        dados["version"] = Configuracao.versaoAtual
        try FileManager.default.createDirectory(at: arquivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saida = try JSONSerialization.data(withJSONObject: dados, options: [.prettyPrinted, .sortedKeys])
        try saida.write(to: arquivo, options: .atomic)
    }
}

enum Formatar {
    static func n(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}
