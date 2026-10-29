import Foundation

/// Versão do build (29/10), gravada no `Info.plist` pelo `build.sh` (`TDCanal`, `TDVersao`):
/// `main-<sha>` para a main do GitHub sem mudança; `branch-<nome>-<sha>` (alpha) no resto.
public struct VersaoApp: Equatable, Sendable {
    public var texto: String
    public var alpha: Bool

    public init(texto: String, alpha: Bool) { self.texto = texto; self.alpha = alpha }

    /// Sem as chaves (swift run, build antigo) o app se diz alpha: nunca passa por main sem prova.
    public static func ler(_ info: [String: Any]?) -> VersaoApp {
        let texto = (info?["TDVersao"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let canal = (info?["TDCanal"] as? String) ?? ""
        let main = canal == "main" && texto.hasPrefix("main-")
        return VersaoApp(texto: texto.isEmpty ? "dev" : texto, alpha: !main)
    }

    public static let atual = VersaoApp.ler(Bundle.main.infoDictionary)
}
