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
        "tools/instalar-prova-remota",
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

    /// Pasta única dos módulos Python. O dispatcher, o vigia e a ListaModelos
    /// leem daqui (`controle/gasto_lanes`). `gasto_privado.py` é opcional.
    public static let relativoModulos = "gasto_lanes"

    public static func modulosAssinados(bundle: Bundle = .main) -> URL? {
        if let achado = urlModulos(recursos: bundle.resourceURL) { return achado }
        return urlModulos(recursos: URL(fileURLWithPath: "/Applications/TuttiDash.app/Contents/Resources"))
    }

    private static func urlModulos(recursos: URL?) -> URL? {
        guard let recursos else { return nil }
        let base = recursos.appendingPathComponent("controle").standardizedFileURL
        let url = base.appendingPathComponent(relativoModulos).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        guard !url.path.contains(".transcentia"), !url.path.contains("..") else { return nil }
        let catalogo = url.appendingPathComponent("catalogo.py").path
        let privacidade = url.appendingPathComponent("privacidade.py").path
        guard FileManager.default.isReadableFile(atPath: catalogo),
              FileManager.default.isReadableFile(atPath: privacidade) else { return nil }
        return url
    }
}
