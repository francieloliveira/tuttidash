import Foundation

/// Scripts do plano de controle dentro do bundle assinado (FRA-613).
/// A execução não lê `~/.transcentia`.
public enum ScriptsDoBundle {
    public static let prefixoAplicacoes = "/Applications/TuttiDash.app/Contents/Resources/controle/"

    public static let relativos = [
        "lanes/dispatcher.py",
        "lanes/lane_view.py",
        "lanes/lanes_window.py",
        "lanes/lanes_ctl.py",
        "lanes/run_lane.sh",
        "bots/watch.py",
        "tools/bots-chave",
    ]

    /// Caminho no bundle deste processo, se o arquivo estiver lá e for legível.
    public static func url(_ relativo: String, bundle: Bundle = .main) -> URL? {
        guard relativos.contains(relativo), !relativo.contains(".."), !relativo.contains(".transcentia") else {
            return nil
        }
        guard let recursos = bundle.resourceURL else { return nil }
        let base = recursos.appendingPathComponent("controle").standardizedFileURL
        let url = base.appendingPathComponent(relativo).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        guard !url.path.contains(".transcentia") else { return nil }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// O app instalado em /Applications. Não aponta para `~/.transcentia`.
    public static func aplicacoes(_ relativo: String) -> URL? {
        guard relativos.contains(relativo), !relativo.contains("..") else { return nil }
        let url = URL(fileURLWithPath: prefixoAplicacoes + relativo)
        guard !url.path.contains(".transcentia") else { return nil }
        return url
    }

    public static func obrigatorio(_ relativo: String, bundle: Bundle = .main) -> URL {
        url(relativo, bundle: bundle) ?? URL(fileURLWithPath: prefixoAplicacoes + relativo)
    }
}
