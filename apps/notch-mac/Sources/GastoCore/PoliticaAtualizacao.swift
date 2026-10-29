import Foundation

/// Quando o TuttiDash relê dados e confere o mouse (FRA-339).
/// Um só lugar para os intervalos: `AppDelegate` e `ControladorNotch` leem daqui.
public struct PoliticaAtualizacao: Equatable, Sendable {
    /// Menor intervalo aceito para qualquer timer (evita polling agressivo).
    public static let intervaloMinimo: TimeInterval = 1

    public var intervaloDados: TimeInterval
    public var intervaloUso: TimeInterval
    public var intervaloReservaMouse: TimeInterval
    /// Idade máxima de uma leitura do disco reaproveitada (FRA-580): mesmo sem arquivo
    /// mudado, o ciclo relê tudo depois disso (janela de dias das retomadas, relógio torto).
    public var idadeMaximaLeitura: TimeInterval

    public init(intervaloDados: TimeInterval = 30, intervaloUso: TimeInterval = 120,
                intervaloReservaMouse: TimeInterval = 1, idadeMaximaLeitura: TimeInterval = 300) {
        self.intervaloDados = max(intervaloDados, Self.intervaloMinimo)
        self.intervaloUso = max(intervaloUso, Self.intervaloMinimo)
        self.intervaloReservaMouse = max(intervaloReservaMouse, Self.intervaloMinimo)
        self.idadeMaximaLeitura = max(idadeMaximaLeitura, Self.intervaloMinimo)
    }

    public static let padrao = PoliticaAtualizacao()

    /// Timer de reserva do mouse: só com o painel expandido (pega saídas rápidas).
    /// Recolhido, os monitores de `mouseMoved` bastam: nil = sem timer.
    public func reservaMouse(expandido: Bool) -> TimeInterval? {
        expandido ? intervaloReservaMouse : nil
    }

    /// A animação do ponto pulsando só roda com o painel expandido e visível.
    public func animarPonto(expandido: Bool) -> Bool { expandido }
}
