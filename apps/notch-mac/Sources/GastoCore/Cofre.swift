import Foundation
import Security

/// Segredos (tokens, chaves de API) ficam só no Keychain, nunca no config.json (FRA-296).
public struct Cofre: Sendable {
    public static let servicoPadrao = "app.tuttidash.mac"
    public let servico: String
    /// Serviço antigo lido como reserva; o que for achado lá é copiado para o novo (FRA-523).
    public let servicoAntigo: String?
    public init(servico: String = Cofre.servicoPadrao, servicoAntigo: String? = nil) {
        self.servico = servico
        self.servicoAntigo = servicoAntigo ?? (servico == Cofre.servicoPadrao ? Legado.servicoCofreAntigo : nil)
    }

    private func consulta(_ conta: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: servico, kSecAttrAccount as String: conta]
    }

    public func salvar(_ segredo: String, conta: String) throws {
        apagar(conta: conta)
        var q = consulta(conta)
        q[kSecValueData as String] = Data(segredo.utf8)
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    public func ler(conta: String) -> String? {
        if let v = lerSo(conta: conta) { return v }
        guard let antigo = servicoAntigo, antigo != servico,
              let v = Cofre(servico: antigo, servicoAntigo: antigo).lerSo(conta: conta) else { return nil }
        try? salvar(v, conta: conta)  // migra; o item antigo fica intacto
        return v
    }

    private func lerSo(conta: String) -> String? {
        var q = consulta(conta)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Lê o primeiro item do serviço, qualquer conta (item antigo dos scripts).
    public func lerQualquer() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public func apagar(conta: String) -> Bool {
        SecItemDelete(consulta(conta) as CFDictionary) == errSecSuccess
    }
}
