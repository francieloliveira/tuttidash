import Foundation

/// Status de uma execução, igual ao `parser.py` da ferramenta `gasto`.
public enum StatusExecucao: String, Sendable {
    case ok
    case erro
    /// Processo sumiu sem terminar (sem linha final no log e sem estar rodando).
    case morta
    case emAndamento = "em_andamento"
    /// Parada pedida (cancelled / aborted), não é falha do agente.
    case cancelada

    /// Rótulo da tela Builds (FRA-528).
    public var rotulo: String {
        switch self {
        case .ok: return "concluída"
        case .erro: return "falhou"
        case .morta: return "morta"
        case .emAndamento: return "rodando"
        case .cancelada: return "cancelada"
        }
    }
}

/// Tipo de custo, igual ao `parser.py`. Desconhecido nunca vira zero.
public enum TipoCusto: String, Sendable {
    case estimado       // claude: calculado pelo cliente a preço de tabela
    case informado      // grok com API key: informado pelo servidor
    case desconhecido   // sem result, custo 0/ausente ou parcial
    case gratis         // modelo grátis (opencode free): custo zero de verdade
    case plano          // assinatura com preço fixo (codex, opencode-go): sem custo por execução

    /// Texto curto para a coluna Custo. nil = mostra o valor (ou traço).
    public var rotuloFixo: String? {
        switch self {
        case .gratis: return "grátis"
        case .plano: return "no plano"
        default: return nil
        }
    }
}

/// Uma execução de lane (um log `<CARD>-<lane>-<AAAAMMDD-HHMMSS>.jsonl`).
public struct Execucao: Equatable, Sendable {
    public var id: String
    public var card: String
    public var lane: String
    /// Início pelo nome do arquivo (relógio local do Mac, sem fuso), `AAAA-MM-DDTHH:MM:SS`.
    public var inicio: String
    /// `AAAA-MM-DD`
    public var dia: String
    /// Semana ISO, ex. `2026-W41`.
    public var semana: String
    public var status: StatusExecucao
    public var subtipo: String?
    public var erros: [String]
    /// nil quando o custo é desconhecido.
    public var custoUSD: Double?
    public var custo: TipoCusto
    public var turnos: Int?
    public var duracaoMs: Int?
    public var duracaoEstimadaMs: Int?
    /// Respostas do modelo contadas até onde o log foi (só morta/em andamento).
    public var respostasParciais: Int?
    public var tokensTotal: Int?
    public var fonte: Fonte?

    public init(id: String, card: String, lane: String, inicio: String, dia: String, semana: String,
                status: StatusExecucao, subtipo: String? = nil, erros: [String] = [],
                custoUSD: Double? = nil, custo: TipoCusto = .desconhecido, turnos: Int? = nil,
                duracaoMs: Int? = nil, duracaoEstimadaMs: Int? = nil, respostasParciais: Int? = nil,
                tokensTotal: Int? = nil, fonte: Fonte? = nil) {
        self.id = id; self.card = card; self.lane = lane; self.inicio = inicio; self.dia = dia
        self.semana = semana; self.status = status; self.subtipo = subtipo; self.erros = erros
        self.custoUSD = custoUSD; self.custo = custo; self.turnos = turnos; self.duracaoMs = duracaoMs
        self.duracaoEstimadaMs = duracaoEstimadaMs; self.respostasParciais = respostasParciais
        self.tokensTotal = tokensTotal; self.fonte = fonte
    }

    /// Custo conhecido (nil = desconhecido). Mesmo critério do `report._soma`.
    public var custoConhecido: Double? {
        if custo == .desconhecido { return nil }
        if custo == .gratis || custo == .plano { return 0 }
        return custoUSD
    }
}

/// Tamanho e mtime do log (o ledger guarda `fonte` com mtime arredondado a 3 casas).
public struct Fonte: Equatable, Sendable {
    public var tamanho: Int
    public var mtime: Double
    public init(tamanho: Int, mtime: Double) { self.tamanho = tamanho; self.mtime = mtime }

    public func igual(_ outra: Fonte) -> Bool {
        tamanho == outra.tamanho && abs(mtime - outra.mtime) < 0.002
    }
}
