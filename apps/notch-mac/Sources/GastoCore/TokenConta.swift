import Foundation

/// Token de acesso lido do disco. O app **só lê**: nunca renova nem regrava a credencial,
/// porque o refresh rotaciona o token e quebraria o CLI (regra 4 do GOAL).
public struct TokenConta: Equatable, Sendable {
    public var valor: String
    /// nil = o arquivo não informou validade.
    public var expiraEm: Date?
    /// Workspace da credencial (ex.: `orgID` do OpenCode Console). nil = o endpoint não exige.
    public var orgID: String?

    public init(valor: String, expiraEm: Date? = nil, orgID: String? = nil) {
        self.valor = valor; self.expiraEm = expiraEm; self.orgID = orgID
    }

    /// `folga` evita gastar uma chamada com um token que vence em segundos.
    public func expirado(agora: Date, folga: TimeInterval = 30) -> Bool {
        guard let e = expiraEm else { return false }
        return e.timeIntervalSince(agora) <= folga
    }
}
