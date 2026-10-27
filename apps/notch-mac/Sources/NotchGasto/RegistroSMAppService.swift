import Foundation
import ServiceManagement
import GastoCore

/// Implementação real: agentes em Contents/Library/LaunchAgents do TuttiDash.app.
final class RegistroSMAppService: RegistroAgentes {
    func status(_ plist: String) -> StatusRegistro {
        switch SMAppService.agent(plistName: plist).status {
        case .enabled: return .ativo
        case .requiresApproval: return .precisaAprovacao
        case .notFound: return .naoEncontrado
        default: return .naoRegistrado
        }
    }
    func registrar(_ plist: String) throws { try SMAppService.agent(plistName: plist).register() }
    func desregistrar(_ plist: String) throws { try SMAppService.agent(plistName: plist).unregister() }
    static func abrirItensDeLogin() { SMAppService.openSystemSettingsLoginItems() }
}
