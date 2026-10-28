import Foundation

/// Quando o TuttiDash relê dados e confere o mouse (FRA-339).
/// Um só lugar para os intervalos: `AppDelegate` e `ControladorNotch` leem daqui.
public struct PoliticaAtualizacao: Equatable, Sendable {
    /// Menor intervalo aceito para qualquer timer (evita polling agressivo).
    public static let intervaloMinimo: TimeInterval = 1

    /// Polling dos dados quando o FSEvents não sobe; com ele, a espera mínima entre leituras
    /// puxadas por logs e ledger (crescem a cada linha: não relê mais que o polling antigo).
    public var intervaloDados: TimeInterval
    public var intervaloUso: TimeInterval
    public var intervaloReservaMouse: TimeInterval
    /// Espera mínima entre leituras puxadas por mudança no estado das lanes (FRA-581).
    public var intervaloEstado: TimeInterval
    /// Releitura com o observador ativo: virada de dia e semana, limites que vencem, evento perdido.
    public var intervaloReserva: TimeInterval

    public init(intervaloDados: TimeInterval = 30, intervaloUso: TimeInterval = 120,
                intervaloReservaMouse: TimeInterval = 1, intervaloEstado: TimeInterval = 2,
                intervaloReserva: TimeInterval = 300) {
        self.intervaloDados = max(intervaloDados, Self.intervaloMinimo)
        self.intervaloUso = max(intervaloUso, Self.intervaloMinimo)
        self.intervaloReservaMouse = max(intervaloReservaMouse, Self.intervaloMinimo)
        self.intervaloEstado = max(intervaloEstado, Self.intervaloMinimo)
        self.intervaloReserva = max(intervaloReserva, Self.intervaloMinimo)
    }

    public static let padrao = PoliticaAtualizacao()

    /// O que o `ObservadorArquivos` vigia (FRA-581): o estado das lanes reage em segundos;
    /// logs, log do dispatcher e ledger, no máximo uma vez por `intervaloDados`.
    public func caminhosObservados(_ cfg: Configuracao) -> [CaminhoObservado] {
        [CaminhoObservado(pasta: cfg.stateDir, intervaloMinimo: intervaloEstado),
         CaminhoObservado(pasta: cfg.logsDir, intervaloMinimo: intervaloDados),
         CaminhoObservado(arquivo: cfg.logDispatcher, intervaloMinimo: intervaloDados),
         CaminhoObservado(arquivo: cfg.ledger, intervaloMinimo: intervaloDados)]
    }

    /// Timer de reserva do mouse: só com o painel expandido (pega saídas rápidas).
    /// Recolhido, os monitores de `mouseMoved` bastam: nil = sem timer.
    public func reservaMouse(expandido: Bool) -> TimeInterval? {
        expandido ? intervaloReservaMouse : nil
    }

    /// A animação do ponto pulsando só roda com o painel expandido e visível.
    public func animarPonto(expandido: Bool) -> Bool { expandido }
}
