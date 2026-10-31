import CryptoKit
import Darwin
import Foundation

/// Veredito da âncora de integridade (FRA-616). `aviso` só existe quando não confere.
public struct VereditoIntegridade: Equatable, Sendable {
    public var confere: Bool
    public var aviso: String?
    public static let ok = VereditoIntegridade(confere: true, aviso: nil)

    public init(confere: Bool, aviso: String?) {
        self.confere = confere
        self.aviso = aviso
    }
}

/// Leitura já feita da âncora. Os testes montam isto sem root.
public struct AncoraLida: Equatable, Sendable {
    public var caminho: String
    public var texto: String?
    public var uid: uid_t
    public var regular: Bool
    public var gravavelPeloGrupo: Bool
    public var diretorioConfiavel: Bool

    public init(caminho: String, texto: String?, uid: uid_t, regular: Bool,
                gravavelPeloGrupo: Bool, diretorioConfiavel: Bool) {
        self.caminho = caminho
        self.texto = texto
        self.uid = uid
        self.regular = regular
        self.gravavelPeloGrupo = gravavelPeloGrupo
        self.diretorioConfiavel = diretorioConfiavel
    }
}

public enum ErroIntegridade: Error, LocalizedError, Equatable {
    case divergencia(String)

    public var errorDescription: String? {
        switch self {
        case .divergencia(let mensagem):
            return mensagem
        }
    }
}

/// Quem responde se o plano de controle pode ser registrado. O app usa a âncora real.
public protocol FonteIntegridade: AnyObject {
    func veredito() -> VereditoIntegridade
}

public final class IntegridadeAoVivo: FonteIntegridade {
    public init() {}
    public func veredito() -> VereditoIntegridade { IntegridadeControle.atual() }
}

/// Hash e dono fora do alcance do agente (FRA-616).
///
/// A fonte não é o bundle. É o arquivo de sistema, dono root:
/// `/private/var/db/tuttidash/controle.sha256`.
/// A assinatura tem de cumprir o designated requirement Apple Development
/// da equipe `3QA76CY27W`. CDHash sozinho não passa.
public enum IntegridadeControle {
    public static let caminhoAncora = "/private/var/db/tuttidash/controle.sha256"
    public static let equipe = "3QA76CY27W"
    public static let magia = "tuttidash-controle-v1"
    public static let requisito =
        "anchor apple generic and certificate leaf[subject.OU] = \"3QA76CY27W\" "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.12]"

    public static func atual(bundle: Bundle = .main,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> VereditoIntegridade {
        let controleURL = (bundle.resourceURL ?? URL(fileURLWithPath: "/nao-existe")).appendingPathComponent("controle")
        let controleExiste = diretorioRegular(controleURL.path)
        let leitura = controleExiste ? lerArquivos(controle: controleURL) : [:]
        let ancora = lerAncora()
        return avaliar(ancora: ancora, arquivos: leitura ?? [:], home: home.path, controle: controleURL.path,
                       assinaturaAceita: assinaturaAceita(alvo: bundle.bundleURL),
                       controleExiste: controleExiste, leituraOk: leitura != nil)
    }

    public static func avaliar(ancora: AncoraLida, arquivos: [String: Data], home: String, controle: String,
                               assinaturaAceita: Bool, controleExiste: Bool = true,
                               leituraOk: Bool = true) -> VereditoIntegridade {
        if !controleExiste { return falha("arvore") }
        if !caminhoForaDoAgente(ancora.caminho, home: home, controle: controle) { return falha("alcance") }
        if !ancora.regular || ancora.uid != 0 || ancora.gravavelPeloGrupo || !ancora.diretorioConfiavel || ancora.texto == nil {
            return falha("ancora", caminhoAncora)
        }
        guard let esperado = parse(ancora.texto ?? "") else { return falha("manifesto") }
        if !leituraOk { return falha("hash") }
        let presentes = arquivos.filter { !ignorar($0.key) }
        if Set(presentes.keys) != Set(esperado.keys) {
            let extra = Set(presentes.keys).subtracting(esperado.keys).sorted().first
            let falta = Set(esperado.keys).subtracting(presentes.keys).sorted().first
            return falha("hash", extra ?? falta ?? "")
        }
        for rel in esperado.keys.sorted() {
            guard let dados = presentes[rel] else { return falha("hash", rel) }
            if sha256Hex(dados) != esperado[rel] { return falha("hash", rel) }
        }
        if !assinaturaAceita { return falha("assinatura", equipe) }
        return .ok
    }

    /// Confere o designated requirement da equipe. Ad-hoc e CDHash sozinho não passam.
    public static func assinaturaAceita(alvo: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else { return false }
        guard let detalhe = executarCodesign(["-d", "-r-", alvo.path]), detalhe.codigo == 0 else { return false }
        guard let linha = detalhe.texto.split(separator: "\n").first(where: { $0.contains("designated =>") }) else {
            return false
        }
        let texto = String(linha)
        if !texto.contains(equipe) || !texto.contains("anchor apple generic") || !texto.contains("certificate leaf") {
            return false
        }
        if texto.contains("cdhash"), !texto.contains("certificate leaf") { return false }
        guard let verify = executarCodesign(["--verify", "--strict", "-R", requisito, alvo.path]) else { return false }
        return verify.codigo == 0
    }

    public static func textoManifesto(_ arquivos: [String: Data]) -> String {
        var linhas = [magia, "team \(equipe)"]
        for rel in arquivos.keys.sorted() {
            linhas.append("\(sha256Hex(arquivos[rel] ?? Data())) \(rel)")
        }
        return linhas.joined(separator: "\n") + "\n"
    }

    public static func sha256Hex(_ dados: Data) -> String {
        SHA256.hash(data: dados).map { String(format: "%02x", Int($0)) }.joined()
    }

    public static func caminhoForaDoAgente(_ caminho: String, home: String, controle: String) -> Bool {
        if caminho.contains("..") || caminho.contains(".transcentia") || caminho.contains("/Contents/") { return false }
        if !caminho.hasPrefix("/") { return false }
        if sob(caminho, home) || sob(caminho, controle) { return false }
        return caminho == caminhoAncora
    }

    private static func falha(_ codigo: String, _ detalhe: String = "") -> VereditoIntegridade {
        let aviso = detalhe.isEmpty
            ? "integridade: divergencia: \(codigo)"
            : "integridade: divergencia: \(codigo) \(detalhe)"
        return VereditoIntegridade(confere: false, aviso: aviso)
    }

    private static func sob(_ caminho: String, _ raiz: String) -> Bool {
        guard !raiz.isEmpty, caminho.hasPrefix(raiz) else { return false }
        if caminho.count == raiz.count { return true }
        let indice = caminho.index(caminho.startIndex, offsetBy: raiz.count)
        return caminho[indice] == "/"
    }

    private static func ignorar(_ rel: String) -> Bool {
        let partes = rel.split(separator: "/")
        if partes.contains(where: { $0 == "__pycache__" || $0.hasPrefix(".") }) { return true }
        return rel.hasSuffix(".pyc")
    }

    private static func parse(_ texto: String) -> [String: String]? {
        let linhas = texto.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard linhas.count >= 3 else { return nil }
        guard linhas[0] == magia, linhas[1] == "team \(equipe)" else { return nil }
        var mapa: [String: String] = [:]
        var ordem: [String] = []
        for linha in linhas.dropFirst(2) {
            if linha.isEmpty { continue }
            let pedacos = linha.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard pedacos.count == 2 else { return nil }
            let hex = String(pedacos[0])
            let rel = String(pedacos[1])
            guard hex.count == 64, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            guard relOk(rel), mapa[rel] == nil else { return nil }
            if let ultimo = ordem.last, ultimo >= rel { return nil }
            mapa[rel] = hex
            ordem.append(rel)
        }
        return mapa.isEmpty ? nil : mapa
    }

    private static func relOk(_ rel: String) -> Bool {
        if rel.isEmpty || rel.hasPrefix("/") || rel.contains("..") || rel.contains("//") || rel.contains(".transcentia") {
            return false
        }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        return rel.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    private static func lerAncora() -> AncoraLida {
        let caminho = caminhoAncora
        guard let st = lstatDe(caminho), (st.modo & S_IFMT) == S_IFREG else {
            return AncoraLida(caminho: caminho, texto: nil, uid: 1, regular: false,
                              gravavelPeloGrupo: false, diretorioConfiavel: false)
        }
        let gravavel = (st.modo & S_IWGRP) != 0 || (st.modo & S_IWOTH) != 0
        let texto: String?
        if let dados = try? Data(contentsOf: URL(fileURLWithPath: caminho)), dados.count < 32 * 1024,
           !dados.contains(0), let s = String(data: dados, encoding: .utf8), !s.contains("\r") {
            texto = s
        } else {
            texto = nil
        }
        return AncoraLida(caminho: caminho, texto: texto, uid: st.uid, regular: true,
                          gravavelPeloGrupo: gravavel, diretorioConfiavel: diretorioAncoraConfiavel())
    }

    private static func diretorioAncoraConfiavel() -> Bool {
        for parte in ["/private", "/private/var", "/private/var/db", "/private/var/db/tuttidash"] {
            guard let st = lstatDe(parte), (st.modo & S_IFMT) == S_IFDIR, st.uid == 0 else { return false }
            if (st.modo & S_IWGRP) != 0 || (st.modo & S_IWOTH) != 0 { return false }
        }
        return true
    }

    private static func diretorioRegular(_ caminho: String) -> Bool {
        guard let st = lstatDe(caminho) else { return false }
        return (st.modo & S_IFMT) == S_IFDIR
    }

    private static func lerArquivos(controle: URL) -> [String: Data]? {
        let base = controle.standardizedFileURL.path
        guard let enumerador = FileManager.default.enumerator(
            at: controle, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var saida: [String: Data] = [:]
        while let url = enumerador.nextObject() as? URL {
            let nome = url.lastPathComponent
            if nome == "__pycache__" {
                enumerador.skipDescendants()
                continue
            }
            guard let st = lstatDe(url.path) else { return nil }
            let tipo = st.modo & S_IFMT
            if tipo == S_IFLNK { return nil }
            if tipo == S_IFDIR { continue }
            if tipo != S_IFREG { return nil }
            let cheio = url.standardizedFileURL.path
            guard cheio.hasPrefix(base + "/") else { return nil }
            let rel = String(cheio.dropFirst(base.count + 1))
            if ignorar(rel) { continue }
            guard let dados = try? Data(contentsOf: url), dados.count <= 8 * 1024 * 1024 else { return nil }
            saida[rel] = dados
        }
        return saida
    }

    private static func lstatDe(_ caminho: String) -> (uid: uid_t, modo: mode_t)? {
        var st = Darwin.stat()
        guard lstat(caminho, &st) == 0 else { return nil }
        return (st.st_uid, st.st_mode)
    }

    private struct SaidaProc {
        var codigo: Int32
        var texto: String
    }

    /// Junta stdout e stderr. `codesign -d` escreve o designated requirement no stderr.
    private static func executarCodesign(_ argumentos: [String]) -> SaidaProc? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = argumentos
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = tubo
        p.standardInput = FileHandle.nullDevice
        let fim = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in fim.signal() }
        do { try p.run() } catch { return nil }
        tubo.fileHandleForWriting.closeFile()
        let dados = tubo.fileHandleForReading.readDataToEndOfFile()
        fim.wait()
        return SaidaProc(codigo: p.terminationStatus, texto: String(data: dados, encoding: .utf8) ?? "")
    }
}
