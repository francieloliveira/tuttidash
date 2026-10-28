import Foundation

/// As lanes do notch (FRA-412), derivadas de `agents.d/` via `Agentes`.
/// Só entram as com `"painel": true` no manifesto — cursor é conta de uso, não lane.
public enum LanesPainel {
    public static let ordem = Agentes.ordemPainel

    /// Folga do dispatcher (`HEADROOM_PCT`): abaixo disto a conta ainda aceita o esforço.
    public static let folgaBaixo = 90.0
    public static let folgaMedio = 80.0
    public static let folgaAlto = 60.0
    /// Prova acima disto vira alerta. O texto do card pede «passa de 10 min».
    public static let alertaProvaSegundos = 10 * 60
    /// Sem batimento novo por este tempo, o dispatcher conta como parado.
    public static let batimentoParadoSegundos = 10 * 60

    public static let regrasRisco = [
        "baixo: entra abaixo de 90%",
        "médio: entra abaixo de 80%",
        "alto: entra abaixo de 60%",
    ]
}

public enum EstadoGeral: String, Equatable, Sendable {
    case tudoOk
    case atencao
    case parado

    public var rotulo: String {
        switch self {
        case .tudoOk: return "Tudo ok"
        case .atencao: return "Atenção"
        case .parado: return "Parado"
        }
    }
}

public enum EstadoLanePainel: String, Equatable, Sendable {
    case rodando
    case esperando
    case semFolga
    case desligada
    case livre

    public var rotulo: String {
        switch self {
        case .rodando: return "rodando"
        case .esperando: return "esperando"
        case .semFolga: return "sem folga"
        case .desligada: return "desligada"
        case .livre: return "livre"
        }
    }
}

public enum PlanoLane: String, Equatable, Sendable {
    case pago
    case free

    public var rotulo: String {
        switch self {
        case .pago: return "pago"
        case .free: return "free"
        }
    }
}

public struct MedidaConta: Equatable, Sendable {
    public var lane: String
    public var pct: Double?
    public var janela: String?
}

public struct StrikesOpencode: Equatable, Sendable {
    public var atual: Int
    public var limite: Int?
    public var motivos: [String]

    public var texto: String {
        if let limite { return "\(atual)/\(limite)" }
        return "\(atual)"
    }
}

public struct DecisaoDispatcher: Equatable, Sendable {
    public var quando: String?
    public var fila: [String]
    public var proxima: String?
    public var modo: String?
    public var pausaNoLog: Bool

    public static let vazia = DecisaoDispatcher(quando: nil, fila: [], proxima: nil, modo: nil, pausaNoLog: false)
}

public struct ProvaBruta: Equatable, Sendable {
    public var lane: String
    public var card: String
    public var descricao: String?
    public var pedidoEm: Date?
    public var log: String
    public var saida: Int?
    public var esperandoLock: Bool
    public var historico: Bool
}

public enum EstadoSuite: String, Equatable, Sendable {
    case ok
    case falha
    case pendente
}

public struct SuiteProva: Equatable, Sendable {
    public var nome: String
    public var segundos: Int?
    public var estado: EstadoSuite
}

public enum FaseProva: String, Equatable, Sendable, CaseIterable {
    case compilar
    case rodarSuites
    case reexecutar
    case veredito

    public var rotulo: String {
        switch self {
        case .compilar: return "Compilar"
        case .rodarSuites: return "Rodar suítes"
        case .reexecutar: return "Reexecutar falhas"
        case .veredito: return "Veredito"
        }
    }
}

public enum MarcaFase: String, Equatable, Sendable {
    case feita
    case atual
    case aguardando
    case falha
}

public struct FaseMarcada: Equatable, Sendable {
    public var fase: FaseProva
    public var marca: MarcaFase
    public var detalhe: String
}

public struct CartaoProva: Equatable, Sendable {
    public var lane: String
    public var card: String
    public var descricao: String
    public var segundos: Int
    public var tentativa: Int
    public var tentativas: Int
    public var fases: [FaseMarcada]
    public var suites: [SuiteProva]
    public var motivo: String?
    public var proximaAcao: String
    public var zeroTestes: Bool
    public var falha: Bool
    public var emCurso: Bool
    public var seguraLock: Bool
    public var posicaoFila: Int?
    public var esperaSegundos: Int?
}

public struct ResumoProvaHistorico: Equatable, Sendable {
    public var card: String
    public var titulo: String?
    public var lane: String
    public var selo: String
    public var segundos: Int
    public var zeroTestes: Bool
    public var falha: Bool
    public var emCurso: Bool
}

public struct PontoNotch: Equatable, Sendable {
    public var lane: String
    public var aceso: Bool
    public var atencao: Bool

    public init(lane: String, aceso: Bool, atencao: Bool) {
        self.lane = lane
        self.aceso = aceso
        self.atencao = atencao
    }
}

public struct LinhaLane: Equatable, Sendable {
    public var lane: String
    public var estado: EstadoLanePainel
    public var card: String?
    public var descricao: String
    public var detalhe: String
    public var pct: Double?
    public var janela: String?
    public var plano: PlanoLane?
    public var segundosNoCard: Int?
    /// Desligada explicitamente pelo usuário (via `lanes_ctl.py disable` ou toggle do notch).
    /// Quando false, o estado .desligada vem de outro motivo (fora da lista, etc.).
    public var desligadaPeloUsuario: Bool = false
    /// Branch do card em curso (lida do estado da lane). Sem card, nil.
    public var branch: String? = nil
    /// Número (`#N`) e início da última execução desta lane no histórico.
    public var ultimaBuild: Int? = nil
    public var ultimaBuildInicio: Date? = nil
    /// «lane · modelo (peso)» do card em curso. nil sem card.
    public var textoModelo: String? = nil
    /// «modelo fixo» ou o aviso de que o modelo saiu da lista.
    public var avisoModelo: String? = nil
}

public struct EstadoNotch: Equatable, Sendable {
    public var geral: EstadoGeral
    public var rotulo: String
    public var pontos: [PontoNotch]
    public var contaCritica: String
    public var contaPct: Double?
    public var linhas: [LinhaLane]
    public var testes: String
    public var build: String
    public var custoHoje: String
    /// Valor conhecido do custo de hoje (nil quando só há "custo desconhecido" ou "sem dado").
    public var custoHojeValor: Double?
}

public struct CardCaro: Equatable, Sendable {
    public var card: String
    public var lane: String
    public var descricao: String?
    public var custoUSD: Double?
    public var duracaoMs: Int
    public var tentativas: Int
    public var motivo: String?
    public var destaque: Bool
    /// Início da execução mais nova do card.
    public var ultimoInicio: Date? = nil
}

public struct GastoDiaPainel: Equatable, Sendable {
    public var rotulo: String
    public var total: Double
    public var ehHoje: Bool
}

public struct GastoLanePainel: Equatable, Sendable {
    public var lane: String
    public var custoUSD: Double?
    public var desconhecidas: Int
    public var plano: PlanoLane?
}

/// US$ se não houver taxa. Com `usd_brl` ou `cambio.usd_brl` na config, os custos saem em R$.
public enum MoedaPainel: Equatable, Sendable {
    case usd
    case brl(taxa: Double)

    public static func escolher(taxaUsdBrl: Double?) -> MoedaPainel {
        guard let taxa = taxaUsdBrl, taxa > 0 else { return .usd }
        return .brl(taxa: taxa)
    }

    public func texto(_ usd: Double) -> String {
        switch self {
        case .usd: return Formato.usd(usd)
        case .brl(let taxa): return Formato.brl(usd * taxa)
        }
    }

    public var rotulo: String {
        switch self {
        case .usd: return "US$"
        case .brl: return "R$"
        }
    }

    public var detalhe: String {
        switch self {
        case .usd: return "gasto conhecido, US$"
        case .brl(let taxa): return "gasto conhecido, R$, taxa \(Formato.valor(taxa))"
        }
    }
}

public struct CustosPainel: Equatable, Sendable {
    public var porLane: [GastoLanePainel]
    public var hoje: Double?
    public var semana: Double?
    public var desconhecidasHoje: Int
    public var desconhecidasSemana: Int
    public var dias: [GastoDiaPainel]
    public var uso: [MedidaConta]
    public var top: [CardCaro]
    public var moeda: MoedaPainel
    /// Recortes do bloco de custos (semana, mês, ano).
    public var periodos: [PeriodoCustos: CustosPeriodo] = [:]
}

public struct EntregaPainel: Equatable, Sendable {
    public var card: String
    public var titulo: String?
    public var lane: String
    public var quando: String
    public var segundos: Int?
    public var pr: String?
    /// `https://github.com/<dono>/<repo>/pull/<n>` quando o fechamento trouxe a URL.
    /// Sem isso a célula do PR não vira link.
    public var urlPR: String? = nil
    /// `quando` lido no relógio local, para o «há X».
    public var quandoData: Date? = nil
}

public struct InstalacoesPainel: Equatable, Sendable {
    public var leu: Bool
    public var iphone: String?
    public var relogio: String?
}

public enum BlocoPainel: String, Equatable, Sendable, CaseIterable {
    case alertas
    case lanes
    case testes
    case builds
    case dispatcher
    case entregas
    case custos
    case log
}

public struct SnapshotPainel: Equatable, Sendable {
    public var geral: EstadoGeral
    public var rotuloGeral: String
    public var notch: EstadoNotch
    public var alertas: [String]
    public var lanes: [LinhaLane]
    public var provas: [CartaoProva]
    public var historico: [ResumoProvaHistorico]
    public var lockTexto: String
    public var lockSegundos: Int?
    public var lockLane: String?
    public var lockCard: String?
    public var filaLock: [String]
    public var simulador: String
    public var batimentoTexto: String
    public var dispatcherVivo: Bool
    public var pausa: Bool
    public var filaPronta: [String]
    public var proximaDecisao: String
    public var strikesTexto: String
    public var regrasRisco: [String]
    public var entregas: [EntregaPainel]
    public var iphone: String
    public var relogio: String
    public var custos: CustosPainel
    public var logTexto: String
    public var logAberto: Bool
    public var laneSugerida: String?
    /// Números dos cartões do topo do painel (FRA painel v2).
    public var indicadores: IndicadoresPainel = .vazio
    /// Alertas da faixa do painel: os do notch mais os que só o painel mostra.
    public var alertasPainel: [String] = []
    /// Execuções de hoje com o `#N`, a mais nova primeiro.
    public var buildsHoje: [BuildPainel] = []
    /// Cards esperando o dono (último desfecho `needs:...` no log do dispatcher).
    public var esperandoVoce: Int = 0

    /// As últimas `n` linhas do log do dispatcher (só leitura).
    public func ultimasLinhasLog(_ n: Int = 10) -> [String] {
        Array(logTexto.split(whereSeparator: \.isNewline).map(String.init).suffix(n))
    }

    public var blocos: [BlocoPainel] {
        var lista = BlocoPainel.allCases.filter { $0 != .log }
        if logAberto { lista.append(.log) }
        return lista
    }

    public func abrindoLog() -> SnapshotPainel {
        var copia = self
        copia.logAberto = true
        return copia
    }
}

/// Tudo o que os leitores conseguem tirar do disco, sem calcular alerta nem fila.
public struct EntradaPainel: Equatable, Sendable {
    public var heartbeat: EstadoLanes.Heartbeat?
    public var rodando: [EstadoLanes.LaneRodando]
    public var titulos: [String: String]
    public var habilitadas: Set<String>?
    public var desligadasPeloUsuario: Set<String>
    public var pausa: Bool
    public var medidas: [MedidaConta]
    public var planos: [String: PlanoLane]
    public var strikes: StrikesOpencode?
    public var decisao: DecisaoDispatcher
    public var provas: [ProvaBruta]
    public var simulador: String?
    public var instalacoes: InstalacoesPainel
    public var limitesAte: [String: Date]
    public var logTexto: String
    public var fechamentos: [FechamentoLog]
    /// «lane · modelo (peso)» por lane, só quando há card em curso.
    public var textoModelo: [String: String] = [:]
    /// Aviso de modelo fixo ou de modelo que saiu da lista.
    public var avisoModelo: [String: String] = [:]
    /// FRA-580: indica se a leitura do disco foi pulada.
    public var pulouLeitura: Bool = false
    public var leituraPulada: Bool = false
    public var pulou: Bool = false
    public var skipRead: Bool = false
    public var skipped: Bool = false
    public var leuDoDisco: Bool = true
    public var ultimaModificacao: Date? = nil

    public static let vazia = EntradaPainel(
        heartbeat: nil, rodando: [], titulos: [:], habilitadas: nil, desligadasPeloUsuario: [],
        pausa: false, medidas: [], planos: [:], strikes: nil, decisao: .vazia, provas: [],
        simulador: nil, instalacoes: InstalacoesPainel(leu: false, iphone: nil, relogio: nil),
        limitesAte: [:], logTexto: "", fechamentos: [])
}

public struct FechamentoLog: Equatable, Sendable {
    public var quando: String
    public var lane: String
    public var card: String
    public var resto: String
}

public struct PedidoDesativar: Equatable, Sendable {
    public var executavel: String
    public var argumentos: [String]
}

public struct ResultadoCtl: Equatable, Sendable {
    public var pedido: PedidoDesativar
    public var codigo: Int32
    public var executou: Bool
}
