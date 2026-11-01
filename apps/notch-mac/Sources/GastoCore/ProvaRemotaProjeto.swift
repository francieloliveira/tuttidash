import Foundation

/// Se o repositório de um projeto tem o check `prova-remota` (FRA-620).
///
/// Desde o FRA-611 o card só vai para In Review com esse check verde no PR, e o vigia só
/// mergeia com ele. Projeto sem a prova trava as lanes: o app mostra e oferece instalar.
public enum ProvaRemotaProjeto {
    public static let workflow = ".github/workflows/prova-remota.yml"

    public enum Estado: Equatable, Sendable {
        case instalada, falta, semPasta, desconhecido(String)

        public var rotulo: String {
            switch self {
            case .instalada: return String(localized: "instalada")
            case .falta: return String(localized: "falta: as lanes deste projeto não chegam a In Review")
            case .semPasta: return String(localized: "escolha a pasta do projeto")
            case .desconhecido(let motivo): return String(localized: "não deu para conferir (\(motivo))")
            }
        }
    }

    /// Confere o arquivo do workflow na `origin/main` da pasta (sem rede: vale o último fetch).
    public static func estado(repo: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              git: (String, [String]) -> Subprocesso.Resultado = { Subprocesso.rodar($0, $1) })
        -> Estado {
        let limpo = repo.trimmingCharacters(in: .whitespaces)
        guard !limpo.isEmpty else { return .semPasta }
        let pasta = limpo.hasPrefix("~/") ? home.appendingPathComponent(String(limpo.dropFirst(2))).path : limpo
        guard FileManager.default.fileExists(atPath: pasta + "/.git") else { return .desconhecido(String(localized: "a pasta não é um repositório git")) }
        let r = git("/usr/bin/git", ["-C", pasta, "cat-file", "-e", "origin/main:\(workflow)"])
        return r.codigo == 0 ? .instalada : .falta
    }

    /// Comando que instala a prova no projeto e abre o PR no repositório dele.
    /// O instalador fica no bundle assinado, ao lado do controle.
    public static func comandoInstalar(projetoID: String, bundle: Bundle = .main) -> [String]? {
        guard let script = ScriptsDoBundle.url("tools/instalar-prova-remota", bundle: bundle),
              !projetoID.isEmpty, !projetoID.hasPrefix("-") else { return nil }
        return ["/usr/bin/python3", script.path, projetoID, "--pr"]
    }

    /// PATH para o instalador achar `git` e `gh` fora do terminal.
    public static let ambiente: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }()
}
