import Foundation

/// Token do GitHub Copilot no Keychain do app (`app.tuttidash.mac`, conta `copilot`).
/// O mesmo cofre do token do Linear. O valor nunca vai para o config.json.
public struct TokenCopilot: Sendable {
    public static let conta = "copilot"
    public let cofre: Cofre

    public init(cofre: Cofre = Cofre()) { self.cofre = cofre }

    public func ler() -> String? {
        guard let bruto = cofre.ler(conta: Self.conta) else { return nil }
        return CredenciaisCopilot.textoSecreto(bruto)
    }

    public func salvar(_ t: String) throws {
        guard let limpo = CredenciaisCopilot.textoSecreto(t) else { throw ErroTokenCopilot.vazio }
        try cofre.salvar(limpo, conta: Self.conta)
    }

    public func apagar() { cofre.apagar(conta: Self.conta) }
}

public enum ErroTokenCopilot: LocalizedError {
    case vazio

    public var errorDescription: String? {
        switch self {
        case .vazio:
            return String(localized: "O token está vazio.")
        }
    }
}

/// Token que a pessoa aponta num arquivo, ou cola no Keychain. Só leitura do arquivo:
/// o app não grava, não renova e não reescreve o segredo.
public enum CredenciaisCopilot {
    /// Keychain primeiro. Se estiver vazio, o arquivo da conta e depois o caminho global.
    /// Arquivo ausente não é erro de formato: cai no próximo. Arquivo presente e ilegível para.
    public static func resolver(keychain: String?, arquivoConta: String, arquivoGlobal: URL?,
                                ler: (URL) -> Data?,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<TokenConta, ErroUso> {
        if let tok = textoSecreto(keychain) {
            return .success(TokenConta(valor: tok))
        }
        let conta = arquivoConta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conta.isEmpty {
            let url = Configuracao.expandir(conta, ambiente: [:], home: home)
            if let dados = ler(url) { return self.ler(dados, caminho: url.path) }
        }
        if let global = arquivoGlobal, let dados = ler(global) {
            return self.ler(dados, caminho: global.path)
        }
        return .failure(.semTokenCopilot)
    }

    /// Arquivo de texto com o token numa linha, ou JSON `token` / `github_token` /
    /// `access_token` / `pat`. Qualquer outro formato é ilegível — não vira token vazio.
    public static func ler(_ dados: Data, caminho: String) -> Result<TokenConta, ErroUso> {
        if let obj = JV.objeto(dados), !obj.isEmpty {
            let candidatos = ["token", "github_token", "access_token", "pat"].compactMap {
                textoSecreto(JV.texto(obj[$0]))
            }
            if let tok = candidatos.first { return .success(TokenConta(valor: tok)) }
            return .failure(.credencialIlegivel(caminho))
        }
        guard let texto = String(data: dados, encoding: .utf8) else {
            return .failure(.credencialIlegivel(caminho))
        }
        let cru = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if cru.hasPrefix("{") || cru.hasPrefix("[") { return .failure(.credencialIlegivel(caminho)) }
        guard let tok = textoSecreto(cru) else { return .failure(.credencialIlegivel(caminho)) }
        return .success(TokenConta(valor: tok))
    }

    /// Tira espaço e um prefixo `Bearer`. Vazio ou com espaço no meio não é token.
    public static func textoSecreto(_ bruto: String?) -> String? {
        var s = (bruto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("bearer ") {
            s = String(s.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        return s
    }
}
