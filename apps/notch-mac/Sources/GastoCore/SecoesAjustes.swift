import Foundation

/// FRA-531: Ajustes em 6 seções pensadas para quem usa o app (antes eram 8, por tema técnico).
/// Cada seção começa pelo que importa; o que é técnico (tempos, intervalos, caminhos, manifestos)
/// fica em «Avançado», em grupos recolhidos. Só muda a disposição: os campos (chave, tipo, padrão)
/// são os mesmos de `abas()` e `camposNovos()`. Leitura e escrita seguem pelo `ModeloAjustes`.
public enum IdSecaoAjustes: String, CaseIterable, Identifiable, Sendable {
    case geral, lanes, contas, revisao, automacao, avancado
    public var id: String { rawValue }
}

/// Blocos prontos (telas próprias que já existiam) que entram num grupo.
public enum BlocoAjustes: Sendable, Equatable {
    case lanesHabilitadas, modeloLanes, projetos, contas, quemCuida, agentesSegundoPlano,
         jobsAgendados, linear, linearLeitura, manifestos, ferramentas, revisaoAtual

    /// Chaves do config que o bloco edita com controle próprio (contam como alcançáveis).
    public var chaves: [String] {
        switch self {
        case .quemCuida: return [ModoForcado.chave]
        default: return []
        }
    }
}

public struct GrupoAjustes: Identifiable, Sendable {
    public var id: String { nome }
    public let nome: String
    public let ajuda: String?
    public let blocos: [BlocoAjustes]
    public let campos: [CampoAjuste]
    /// Em «Avançado» o grupo começa recolhido.
    public let recolhido: Bool
    public init(_ nome: String, ajuda: String? = nil, blocos: [BlocoAjustes] = [], campos: [CampoAjuste] = [],
                recolhido: Bool = false) {
        self.nome = nome; self.ajuda = ajuda; self.blocos = blocos; self.campos = campos; self.recolhido = recolhido
    }
}

public struct SecaoAjustes: Identifiable, Sendable {
    public var id: IdSecaoAjustes
    public let nome: String
    public let simbolo: String
    public let subtitulo: String
    public let grupos: [GrupoAjustes]
    public var campos: [CampoAjuste] { grupos.flatMap(\.campos) }
    public var blocos: [BlocoAjustes] { grupos.flatMap(\.blocos) }
    /// Só em «Avançado» a chave técnica aparece embaixo do campo.
    public var mostraChaves: Bool { id == .avancado }
}

/// Um resultado da busca nos Ajustes.
public struct ResultadoBuscaAjuste: Identifiable, Sendable {
    public var id: String { campo.chave }
    public let secao: IdSecaoAjustes
    public let grupo: String
    public let campo: CampoAjuste
}

extension CatalogoAjustes {
    public static let nomesEsforco: [String: String] = [
        "baixo": "Baixo", "medio": "Médio", "alto": "Alto",
        "low": "Baixo", "medium": "Médio", "high": "Alto", "xhigh": "Máximo",
        "minimal": "Mínimo", "none": "Nenhum",
    ]

    /// Opções que até o FRA-524 só existiam no config.json (padrões iguais aos do `tools/cfg`).
    public static func camposNovos() -> [CampoAjuste] {
        let n = { (a: Double, b: Double) in TipoCampo.numero(min: a, max: b, inteiro: true) }
        let d = { (a: Double, b: Double) in TipoCampo.numero(min: a, max: b, inteiro: false) }
        return [
            CampoAjuste("watch.max_runs_per_tick", String(localized: "Tarefas novas por ciclo do vigia"), n(1, 10), "1",
                        ajuda: String(localized: "Quantas tarefas o vigia começa a cada ciclo.")),
            CampoAjuste("watch.max_tarefas_por_lane", String(localized: "Tarefas por lane ativa"), n(1, 10), "2",
                        ajuda: String(localized: "Uma rodando e o resto esperando.")),
            CampoAjuste("watch.claude_budget_usd", String(localized: "Teto por tarefa do Claude no vigia (US$)"), d(0.5, 100), "4",
                        ajuda: String(localized: "O Claude para quando passa deste valor.")),
            CampoAjuste("watch.claude_timeout_s", String(localized: "Tempo máximo da tarefa do Claude (s)"), n(60, 7200), "1200"),
            CampoAjuste("watch.card_pedidos_triagem", String(localized: "Card de pedidos da triagem"), .textoOpcional, "",
                        ajuda: String(localized: "Onde o vigia deixa os pedidos de cards novos.")),
            CampoAjuste("watch.pedido_triagem_intervalo_s", String(localized: "Pedir cards à triagem no máximo a cada (s)"), n(600, 604_800), "14400"),
            CampoAjuste("bots_chave.intervalo_s", String(localized: "A chave confere a cada (s)"), n(60, 86_400), "600"),
            CampoAjuste("bots_chave.modo_forcado", String(localized: "Quem cuida dos bots"), .escolha(["auto", "vigia", "grokbot"]), "auto",
                        ajuda: String(localized: "Automático decide pela % de uso da conta."),
                        rotulos: ["auto": String(localized: "Automático (pela % da conta)"), "vigia": String(localized: "Sempre o vigia"),
                                  "grokbot": String(localized: "Sempre o Grok Bot")]),
            CampoAjuste("agendas.env.dispatcher.SKIP_PREFLIGHT", String(localized: "Dispatcher pula a checagem da máquina"), .escolha(["0", "1"]), "0",
                        ajuda: String(localized: "Vale no próximo ciclo do dispatcher."),
                        rotulos: ["0": String(localized: "Não, sempre checar"), "1": String(localized: "Sim, pular")]),
            CampoAjuste("painel.sessao", String(localized: "Sessão do tmux"), .texto, "painel"),
            CampoAjuste("painel.linhas_lane", String(localized: "Linhas por lane"), n(5, 500), "40"),
            CampoAjuste("painel.linhas_log", String(localized: "Linhas do log"), n(5, 500), "30"),
            CampoAjuste("painel.linhas_gestor", String(localized: "Linhas dos testes manuais"), n(5, 500), "20"),
            CampoAjuste("estresse.saida", String(localized: "Arquivo da medição de estresse"), .caminho(deveExistir: false, opcional: true),
                        "~/Library/Logs/TranscentIA/estresse.tsv"),
        ]
    }

    /// Campo do catálogo pela chave, com ajuda e nomes de valores em pt-BR.
    static func campo(_ k: String, rotulo: String = "", ajuda: String = "", rotulos: [String: String] = [:]) -> CampoAjuste {
        let todos = abas().flatMap(\.campos) + camposNovos()
        guard let c = todos.first(where: { $0.chave == k }) else { preconditionFailure("campo sem catálogo: \(k)") }
        return CampoAjuste(c.chave, rotulo.isEmpty ? c.rotulo : rotulo, c.tipo, c.padrao,
                           ajuda: ajuda.isEmpty ? c.ajuda : ajuda, rotulos: rotulos.isEmpty ? c.rotulos : rotulos)
    }

    public static func secoes() -> [SecaoAjustes] {
        let c = { (k: String) in campo(k) }
        let esf = nomesEsforco
        return [
            SecaoAjustes(id: .geral, nome: String(localized: "Geral"), simbolo: "gearshape",
                         subtitulo: String(localized: "Quando o TuttiDash abre e o que cada lane mostra"), grupos: [
                GrupoAjustes(String(localized: "Ferramentas e logins"),
                             ajuda: String(localized: "O que precisa estar instalado e conectado para as lanes funcionarem."),
                             blocos: [.ferramentas]),
                GrupoAjustes(String(localized: "Abertura"), campos: [
                    campo("geral.abrir_no_login", ajuda: String(localized: "O TuttiDash abre sozinho quando você entra no Mac.")),
                ]),
                GrupoAjustes(String(localized: "Janela de cada lane"), ajuda: String(localized: "Vale na próxima tarefa que a lane pegar."), campos: [
                    campo("lane_view.pensamento", ajuda: String(localized: "Mostra o que o agente está pensando enquanto trabalha.")),
                    campo("lane_view.diff", ajuda: String(localized: "Mostra as linhas que o agente mudou em cada arquivo.")),
                ]),
            ]),
            SecaoAjustes(id: .lanes, nome: String(localized: "Lanes"), simbolo: "arrow.triangle.branch",
                         subtitulo: String(localized: "Projetos, quais lanes pegam card, com que modelo e quanto cada card pode gastar"), grupos: [
                GrupoAjustes(String(localized: "Projetos"),
                             ajuda: String(localized: "Cada projeto do Linear ligado ao repositório do GitHub em que as lanes trabalham."),
                             blocos: [.projetos]),
                GrupoAjustes(String(localized: "Lanes ligadas"), ajuda: ClarezaCota.ajudaLanesLigadas,
                             blocos: [.lanesHabilitadas]),
                GrupoAjustes(String(localized: "Modelo de cada lane"),
                             ajuda: String(localized: "No automático, cada peso de card usa um modelo e um esforço. No fixo, a lane usa sempre o mesmo modelo e o mesmo esforço. Modelos e esforços vêm das ferramentas e atualizam ao abrir os Ajustes. Mudanças valem no próximo card; a lane em andamento não muda."),
                             blocos: [.modeloLanes]),
                GrupoAjustes(String(localized: "Quanto cada card pode gastar"), ajuda: String(localized: "Teto em dólar por card, pelo esforço do card."), campos: [
                    campo("lanes.budget_usd.baixo", rotulo: String(localized: "Card de esforço baixo (US$)")),
                    campo("lanes.budget_usd.medio", rotulo: String(localized: "Card de esforço médio (US$)")),
                    campo("lanes.budget_usd.alto", rotulo: String(localized: "Card de esforço alto (US$)")),
                    campo("lanes.effort_default", ajuda: String(localized: "Usado quando o card não diz o esforço."), rotulos: esf),
                ]),
            ]),
            SecaoAjustes(id: .contas, nome: String(localized: "Contas"), simbolo: "person.crop.circle",
                         subtitulo: String(localized: "Teto de gasto, limites das contas e o Linear"), grupos: [
                GrupoAjustes(String(localized: "Teto de gasto"), campos: [
                    campo("teto_semanal_usd", ajuda: String(localized: "Quanto você aceita gastar por semana. 0 desliga o teto.")),
                    campo("aviso_pct", ajuda: String(localized: "O app avisa quando o gasto chega nesta % do teto.")),
                ]),
                GrupoAjustes(String(localized: "Contas das lanes"), ajuda: String(localized: "Quanto de cada conta já foi usado. SuperGrok (via Cursor) e Grok CLI são cotas separadas."),
                             blocos: [.contas], campos: [campo("uso_contas", ajuda: String(localized: "Lê a % de uso de cada conta para equilibrar as lanes."))]),
                GrupoAjustes(String(localized: "Linear"), ajuda: String(localized: "O token fica só no Chaveiro, nunca no arquivo."), blocos: [.linear]),
            ]),
            SecaoAjustes(id: .revisao, nome: String(localized: "Revisão"), simbolo: "checkmark.seal",
                         subtitulo: String(localized: "Quem revisa os PRs antes do merge"), grupos: [
                GrupoAjustes(String(localized: "Revisor dos PRs"),
                             ajuda: String(localized: "Escolha a lane que revisará os PRs. Modelo e esforço vêm dela automaticamente."),
                             campos: [c("revisores.pr.lane"), c("revisores.pr.independente"), c("revisores.pr.reserva")]),
                GrupoAjustes(String(localized: "Modelo e esforço da lane revisora"),
                             ajuda: String(localized: "Lidos da lane selecionada. Não é preciso configurar à mão."),
                             blocos: [.revisaoAtual]),
            ]),
            SecaoAjustes(id: .automacao, nome: String(localized: "Automação"), simbolo: "bolt.horizontal.circle",
                         subtitulo: String(localized: "Quem cuida das lanes e os agentes que rodam sozinhos"), grupos: [
                GrupoAjustes(String(localized: "Quem cuida das lanes"), blocos: [.quemCuida]),
                GrupoAjustes(String(localized: "Agentes em segundo plano"),
                             ajuda: String(localized: "Rodam de dentro do TuttiDash, mesmo com a janela fechada."), blocos: [.agentesSegundoPlano]),
            ]),
            SecaoAjustes(id: .avancado, nome: String(localized: "Avançado"), simbolo: "slider.horizontal.3",
                         subtitulo: String(localized: "Tempos, intervalos, caminhos e arquivos. Raramente precisa mexer"), grupos: [
                GrupoAjustes(String(localized: "Lanes: tempos e turnos"), campos: [
                    c("lanes.grok_max_turns.baixo"), c("lanes.grok_max_turns.medio"), c("lanes.grok_max_turns.alto"),
                    c("lanes.lane_timeout_min"), c("lanes.proof_timeout_min"),
                    campo("lanes.proof_default_suites", ajuda: String(localized: "Separe as suítes por vírgula.")),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Ferramentas (agents.d)"),
                             ajuda: String(localized: "Cada ferramenta tem um manifesto próprio. Só leitura aqui."), blocos: [.manifestos], recolhido: true),
                GrupoAjustes(String(localized: "Privacidade dos modelos"), ajuda: String(localized: "Desde 23/10/2026, modelo free que registra ou treina com o uso pode receber código nas lanes e na revisão."), campos: [
                    c("privacidade.exigir_sem_treino"), c("privacidade.max_retencao_dias"), c("privacidade.max_idade_dias"), c("privacidade.intervalo_h"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "TuttiChave"), ajuda: String(localized: "Quando o uso do Grok Bot passa do limite, o vigia assume."), campos: [
                    campo("bots_chave.limite_pct", ajuda: String(localized: "Acima disto a chave passa as lanes para o vigia.")),
                    c("bots_chave.intervalo_s"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Vigia"), campos: [
                    campo("watch.reconferir_needs_max_s", ajuda: String(localized: "0 reconfere só quando o card muda.")),
                    c("watch.max_runs_per_tick"), c("watch.max_tarefas_por_lane"), c("watch.claude_budget_usd"),
                    c("watch.claude_timeout_s"), c("watch.card_pedidos_triagem"), c("watch.pedido_triagem_intervalo_s"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Ordem dos modelos do vigia"), ajuda: String(localized: "Local primeiro (Ollama), depois opencode free, Claude por último. Quem fez cada análise aparece no log do painel."), campos: [
                    c("watch.ordem_needs"), c("watch.ordem_paradas"), c("watch.ordem_revisao"), c("watch.adaptador_fallback"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Agendamentos"), ajuda: String(localized: "Mudar um intervalo recarrega só aquele serviço."),
                             blocos: [.jobsAgendados], campos: [
                    c("agendas.dispatcher_s"), c("agendas.watch_s"), c("agendas.chave_s"), c("agendas.env.dispatcher.SKIP_PREFLIGHT"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Antes de cada build"), ajuda: String(localized: "O app confere disco e carga antes de rodar a prova."), campos: [
                    c("preflight.min_free_gb"), c("preflight.warn_free_gb"), c("preflight.max_load"), c("preflight.skip_preflight_first"),
                    c("preflight.jobs"), c("preflight.scheme"), c("preflight.external_nvme"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Credenciais"),
                             ajuda: String(localized: "Onde o app acha o login de cada ferramenta. Vazio usa o padrão."),
                             campos: credenciaisContas(), recolhido: true),
                GrupoAjustes(String(localized: "Detalhes do Linear"),
                             ajuda: String(localized: "Preenchidos pela conexão em Contas. Só leitura."), blocos: [.linearLeitura], recolhido: true),
                GrupoAjustes(String(localized: "Pastas do app"), campos: [c("logs_dir"), c("state_dir"), c("ledger")], recolhido: true),
                GrupoAjustes(String(localized: "Janela de cada lane: linhas"), campos: [
                    c("lane_view.pensamento_linhas"), c("lane_view.diff_linhas"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Painel de logs"), campos: [
                    c("painel.comando"), c("painel.lanes_comando"), c("painel.tmux"), c("painel.sessao"),
                    c("painel.proof_log_glob"), c("painel.gestor_log_glob"), c("painel.filtro"),
                    c("painel.linhas_lane"), c("painel.linhas_log"), c("painel.linhas_gestor"), c("painel.intervalo_s"),
                ], recolhido: true),
                GrupoAjustes(String(localized: "Medição de estresse"), campos: [c("estresse.intervalo_s"), c("estresse.saida")], recolhido: true),
            ]),
        ]
    }

    /// Chaves que saíram dos Ajustes e não voltam. Continuam no `tools/cfg` e no config.json
    /// por compatibilidade, mas o app as ignora com o padrão do cfg (a pílula vive na barra
    /// de menus e segue o menu; a pílula antiga do notch, se ligada, usa a tela do notch).
    public static let chavesAposentadas: Set<String> = ["geral.tela"]

    /// Todas as chaves que a tela nova alcança: campos e as chaves editadas por blocos próprios.
    public static func chavesAlcancaveis(_ secoes: [SecaoAjustes] = secoes()) -> Set<String> {
        Set(secoes.flatMap(\.campos).map(\.chave) + secoes.flatMap(\.blocos).flatMap(\.chaves))
    }

    /// Seção antiga (FRA-524, 8 seções) -> seção nova. Para o PR e para quem abre um atalho antigo.
    public static let secaoNovaDaAntiga: [String: IdSecaoAjustes] = [
        "lanes": .lanes, "contas": .contas, "revisao": .revisao, "agentes": .automacao,
        "agendas": .avancado, "maquinas": .avancado, "integracoes": .contas, "painel": .geral,
    ]

    /// Busca por nome, explicação, grupo ou chave, sem diferenciar acento e maiúscula.
    public static func buscar(_ termo: String, em secoes: [SecaoAjustes] = secoes()) -> [ResultadoBuscaAjuste] {
        let normal = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")) }
        let t = normal(termo.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !t.isEmpty else { return [] }
        var r: [ResultadoBuscaAjuste] = []
        for s in secoes {
            for g in s.grupos {
                for c in g.campos where [c.rotulo, c.ajuda, g.nome, c.chave].contains(where: { normal($0).contains(t) }) {
                    r.append(ResultadoBuscaAjuste(secao: s.id, grupo: g.nome, campo: c))
                }
            }
        }
        return r
    }

    /// Chaves do Linear mostradas só para leitura.
    public static let chavesLinearLeitura = [
        "linear.workspace_url", "linear.state_in_progress_name",
        "linear.state_in_review_name", "linear.owner_label", "linear.alert_labels", "linear.blocking_labels",
        "linear.diary_doc_id", "linear.keychain_service",
    ]
}
