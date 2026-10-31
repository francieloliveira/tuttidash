import Foundation
import Security

/// Atributos do item de segredo. Com proteção de dados o `security` da linha de
/// comando não lista o item (FRA-607). O access group limita quem assina o app.
public enum AtributosChaveiro {
    /// Sufixo do access group. O entitlement é `$(AppIdentifierPrefix)` + este texto.
    /// No binário assinado os dois ficam iguais: ad-hoc sem prefixo, com time `TEAMID.`.
    public static let sufixoGrupo = "app.tuttidash.mac"
    /// Sem entitlement legível (teste sem assinatura) vale o sufixo, que é o grupo do ad-hoc.
    public static let grupoLinear = sufixoGrupo

    /// Grupo igual ao entitlement já expandido no processo, quando a assinatura o traz.
    public static func grupoDoProcesso() -> String {
        var codigo: SecCode?
        guard SecCodeCopySelf([], &codigo) == errSecSuccess, let codigo else { return grupoLinear }
        var estatico: SecStaticCode?
        guard SecCodeCopyStaticCode(codigo, [], &estatico) == errSecSuccess, let estatico else { return grupoLinear }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(estatico, [], &infoRef) == errSecSuccess, let infoRef else {
            return grupoLinear
        }
        return grupo(em: infoRef as NSDictionary)
    }

    /// Prefere o grupo escrito no entitlement; senão monta com o `teamid`; senão o sufixo.
    static func grupo(em info: NSDictionary) -> String {
        if let ent = info["entitlements-dict"] as? NSDictionary {
            let grupos = textos(ent["keychain-access-groups"])
            if let grupo = grupos.first(where: { $0 == sufixoGrupo || $0.hasSuffix(".\(sufixoGrupo)") }) {
                return grupo
            }
        }
        if let team = info["teamid"] as? String {
            let limpo = team.trimmingCharacters(in: .whitespacesAndNewlines)
            if !limpo.isEmpty { return "\(limpo).\(sufixoGrupo)" }
        }
        return grupoLinear
    }

    private static func textos(_ bruto: Any?) -> [String] {
        if let lista = bruto as? [String] { return lista }
        if let lista = bruto as? [NSString] { return lista.map { $0 as String } }
        if let lista = bruto as? NSArray {
            var saida: [String] = []
            for item in lista {
                if let texto = item as? String { saida.append(texto) }
            }
            return saida
        }
        return []
    }

    public static func item(servico: String, conta: String, grupo: String? = nil,
                            protecaoDeDados: Bool = false) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: conta,
        ]
        if protecaoDeDados {
            q[kSecUseDataProtectionKeychain as String] = true
            if let grupo { q[kSecAttrAccessGroup as String] = grupo }
        }
        return q
    }
}

/// Segredos (tokens, chaves de API) ficam só no Keychain, nunca no config.json (FRA-296).
public struct Cofre: Sendable {
    public static let servicoPadrao = "app.tuttidash.mac"
    public let servico: String
    /// Serviço antigo lido como reserva; o que for achado lá é copiado para o novo (FRA-523).
    public let servicoAntigo: String?
    /// Item na data protection keychain: o `security` não o enxerga (FRA-607).
    public let protecaoDeDados: Bool
    /// Access group quando `protecaoDeDados`. Sem entitlement, a gravação tenta de novo sem o grupo.
    public let grupo: String?

    public init(servico: String = Cofre.servicoPadrao, servicoAntigo: String? = nil,
                migrarLegado: Bool = true, protecaoDeDados: Bool = false, grupo: String? = nil) {
        self.servico = servico
        self.protecaoDeDados = protecaoDeDados
        self.grupo = protecaoDeDados ? grupo : nil
        if let servicoAntigo, !servicoAntigo.isEmpty {
            self.servicoAntigo = servicoAntigo
        } else if migrarLegado && servico == Cofre.servicoPadrao {
            self.servicoAntigo = Legado.servicoCofreAntigo
        } else {
            self.servicoAntigo = nil
        }
    }

    private func consulta(_ conta: String, grupo: String?) -> [String: Any] {
        AtributosChaveiro.item(servico: servico, conta: conta,
                               grupo: protecaoDeDados ? grupo : nil,
                               protecaoDeDados: protecaoDeDados)
    }

    public func salvar(_ segredo: String, conta: String) throws {
        apagar(conta: conta)
        do {
            try acrescentar(segredo, conta: conta, grupo: grupo)
        } catch let erro as NSError where grupo != nil && erro.code == Int(errSecMissingEntitlement) {
            try acrescentar(segredo, conta: conta, grupo: nil)
        }
    }

    private func acrescentar(_ segredo: String, conta: String, grupo: String?) throws {
        var q = consulta(conta, grupo: grupo)
        q[kSecValueData as String] = Data(segredo.utf8)
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    public func ler(conta: String) -> String? {
        if let v = lerSo(conta: conta) { return v }
        guard let antigo = servicoAntigo, antigo != servico,
              let v = Cofre(servico: antigo, migrarLegado: false).lerSo(conta: conta) else { return nil }
        try? salvar(v, conta: conta)  // migra; o item antigo fica intacto
        return v
    }

    private func lerSo(conta: String) -> String? {
        if let v = copiar(conta, grupo: grupo) { return v }
        if protecaoDeDados, grupo != nil, let v = copiar(conta, grupo: nil) { return v }
        return nil
    }

    private func copiar(_ conta: String, grupo: String?) -> String? {
        var q = consulta(conta, grupo: grupo)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Lê o primeiro item do serviço, qualquer conta (item antigo dos scripts).
    public func lerQualquer() -> String? {
        var q = consulta("", grupo: grupo)
        q.removeValue(forKey: kSecAttrAccount as String)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public func apagar(conta: String) -> Bool {
        let comGrupo = apagarItem(conta, grupo: grupo)
        let semGrupo = (protecaoDeDados && grupo != nil) ? apagarItem(conta, grupo: nil) : false
        return comGrupo || semGrupo
    }

    private func apagarItem(_ conta: String, grupo: String?) -> Bool {
        SecItemDelete(consulta(conta, grupo: grupo) as CFDictionary) == errSecSuccess
    }
}
