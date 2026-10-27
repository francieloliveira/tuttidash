import Foundation

/// Nome e versão que o app manda no `User-Agent`. A versão é a de
/// `CFBundleShortVersionString` em `Resources/Info.plist`.
public enum Produto {
    public static let nome = "TuttiDash"
    public static let versao = "0.2.0"
    public static var userAgent: String { "\(nome)/\(versao)" }
}
