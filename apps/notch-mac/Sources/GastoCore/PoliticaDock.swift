import Foundation

/// FRA-553: presença do TuttiDash.
/// `accessory` = só a pílula (NSApplication.ActivationPolicy.accessory).
/// `regular` = painel aberto, ícone no Dock e no Cmd-Tab (.regular).
/// `LSUIElement` continua true no Info.plist para o arranque não piscar no Dock;
/// esta política é aplicada por cima, em tempo de execução.
public enum PoliticaAtivacao: Equatable, Sendable {
    case accessory
    case regular
}

/// O que fazer com o processo depois de um gesto (fechar a janela ou «Sair»).
public enum DestinoProcesso: Equatable, Sendable {
    case permanecer
    case encerrar
}

/// Resultado de fechar a janela do painel: volta à pílula e o app continua.
public struct EfeitoFecharPainel: Equatable, Sendable {
    public let politica: PoliticaAtivacao
    public let destino: DestinoProcesso

    public init(politica: PoliticaAtivacao, destino: DestinoProcesso) {
        self.politica = politica
        self.destino = destino
    }
}

/// Decide Dock versus pílula. Não fala com o AppKit: o app só aplica o que sai daqui.
public enum PoliticaDock {
    /// Arranque e painel fechado.
    public static let arranque = PoliticaAtivacao.accessory

    /// Painel (JanelaPainel) visível.
    public static func aoMostrarPainel() -> PoliticaAtivacao { .regular }

    /// Fechar a janela não é sair. A pílula permanece e o processo continua.
    public static func aoFecharPainel() -> EfeitoFecharPainel {
        EfeitoFecharPainel(politica: .accessory, destino: .permanecer)
    }

    /// Menu «Sair» da pílula (e o botão equivalente no painel).
    public static func aoSair() -> DestinoProcesso { .encerrar }
}
