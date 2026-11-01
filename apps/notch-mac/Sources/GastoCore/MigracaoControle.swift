import Darwin
import Foundation

/// Cópia que o doutor vê em uso. `legado` ganha de `bundle` quando os dois aparecem:
/// um plist ainda apontando para ~/.transcentia não pode ficar escondido.
public enum CopiaEmUso: Equatable, Sendable {
    case bundle(String)
    case legado(String)
    case nenhuma

    public var nome: String {
        switch self {
        case .bundle: return "bundle"
        case .legado: return "legado"
        case .nenhuma: return "nenhuma"
        }
    }

    public var caminho: String {
        switch self {
        case .bundle(let c), .legado(let c): return c
        case .nenhuma: return ""
        }
    }
}

/// O que o doutor mostra: qual cópia o launchd usa e se o hash da âncora confere.
public struct RelatorioDoutor: Equatable, Sendable {
    public var copia: CopiaEmUso
    public var hashConfere: Bool
    public var texto: String

    public init(copia: CopiaEmUso, hashConfere: Bool, texto: String) {
        self.copia = copia
        self.hashConfere = hashConfere
        self.texto = texto
    }
}

public enum DoutorControle {
    /// Mesma lista que `tools/migrar-controle.py`. O teste de migração compara os dois.
    public static let copiasAntigas = [
        ".transcentia/lanes/dispatcher.py",
        ".transcentia/lanes/lane_view.py",
        ".transcentia/lanes/lanes_window.py",
        ".transcentia/lanes/lanes_ctl.py",
        ".transcentia/lanes/run_lane.sh",
        ".transcentia/lanes/catalogo.py",
        ".transcentia/lanes/fila.py",
        ".transcentia/lanes/projetos.py",
        ".transcentia/lanes/privacidade.py",
        ".transcentia/lanes/linear_ids.py",
        ".transcentia/lanes/config.py",
        ".transcentia/lanes/gasto_privado.py",
        ".transcentia/lanes/proxy_linear.py",
        ".transcentia/lanes/permissao.py",
        ".transcentia/bots/watch.py",
        ".transcentia/bots/catalogo.py",
        ".transcentia/bots/fila.py",
        ".transcentia/bots/projetos.py",
        ".transcentia/bots/privacidade.py",
        ".transcentia/bots/linear_ids.py",
        ".transcentia/bots/config.py",
        ".transcentia/bots/gasto_privado.py",
        ".transcentia/bots/proxy_linear.py",
        ".transcentia/tools/bots-chave",
    ]

    public static func avaliar(pistas: [String], veredito: VereditoIntegridade) -> RelatorioDoutor {
        var legado: String?
        var bundle: String?
        for pista in pistas {
            let pedacos = pista.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\"" }).map(String.init) + [pista]
            for pedaco in pedacos {
                if legado == nil, pareceLegado(pedaco) { legado = caminhoDe(pedaco) }
                if bundle == nil, pareceBundle(pedaco) { bundle = caminhoDe(pedaco) }
            }
        }
        let copia: CopiaEmUso
        if let legado { copia = .legado(legado) }
        else if let bundle { copia = .bundle(bundle) }
        else { copia = .nenhuma }
        let hash = veredito.confere ? "confere" : "não confere"
        let linha = copia.caminho.isEmpty
            ? "cópia em uso: \(copia.nome)"
            : "cópia em uso: \(copia.nome) (\(copia.caminho))"
        return RelatorioDoutor(copia: copia, hashConfere: veredito.confere, texto: "\(linha)\nhash: \(hash)")
    }

    /// Plists soltos e, se existir, o texto do lançador que eles chamam.
    public static func pistas(home: URL, bundleAgente: String? = nil) -> [String] {
        var saida: [String] = []
        let labels = [
            "com.transcentia.bots.watch",
            "com.transcentia.bots.chave",
            "com.transcentia.lanes.dispatcher",
        ]
        for label in labels {
            let url = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
            guard let dados = try? Data(contentsOf: url),
                  let obj = try? PropertyListSerialization.propertyList(from: dados, options: [], format: nil) as? [String: Any],
                  let args = obj["ProgramArguments"] as? [String] else { continue }
            saida.append(contentsOf: args)
            if let primeiro = args.first, !primeiro.contains("tuttidash-agente"),
               let texto = lerTextoPequeno(primeiro) {
                saida.append(texto)
            }
        }
        if let bundleAgente, !bundleAgente.isEmpty { saida.append(bundleAgente) }
        return saida
    }

    public static func atual(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             bundle: Bundle = .main) -> RelatorioDoutor {
        let agente = bundle.bundleURL.appendingPathComponent("Contents/MacOS/tuttidash-agente").path
        let extra = FileManager.default.isExecutableFile(atPath: agente) ? agente : nil
        return avaliar(pistas: pistas(home: home, bundleAgente: extra), veredito: IntegridadeControle.atual(bundle: bundle, home: home))
    }

    private static func pareceLegado(_ s: String) -> Bool {
        guard s.contains(".transcentia/") else { return false }
        let marcas = ["dispatcher.py", "watch.py", "bots-chave", "lane_view.py", "run_lane.sh",
                      "lanes_ctl.py", "lanes_window.py", "catalogo.py", "gasto_privado.py"]
        return marcas.contains { s.contains($0) }
    }

    private static func pareceBundle(_ s: String) -> Bool {
        s.contains("tuttidash-agente") || s.contains("/Contents/Resources/controle")
    }

    private static func caminhoDe(_ s: String) -> String {
        for parte in s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\"" }) {
            let t = String(parte)
            if pareceLegado(t) || pareceBundle(t) { return t }
        }
        return s
    }

    private static func lerTextoPequeno(_ caminho: String) -> String? {
        guard caminho.hasPrefix("/"), !caminho.contains(".app/Contents/MacOS/") else { return nil }
        var st = Darwin.stat()
        guard lstat(caminho, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 16_384 else { return nil }
        return try? String(contentsOfFile: caminho, encoding: .utf8)
    }
}

public enum ResultadoAposentadoria: Equatable, Sendable {
    case nada
    case aposentadas([String])
    case rollback(String)
}

private struct ItemRecibo: Codable, Equatable {
    var rel: String
    var modo: UInt16
    var symlink: String?
}

private struct ReciboAposentadoria: Codable, Equatable {
    var stamp: String
    var itens: [ItemRecibo]
}

/// Tira as cópias antigas do caminho vivo. Se a verificação não confere, não move nada
/// e devolve rollback. `restaurar` desfaz a última aposentadoria (o launchd voltou atrás).
public enum AposentadoriaControle {
    public static func aplicar(home: URL, confere: Bool, aviso: String) -> ResultadoAposentadoria {
        if !confere { return .rollback(aviso) }
        let presentes = listar(home)
        if presentes.isEmpty { return .nada }
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(getpid())"
        var avisos: [String] = []
        var itens: [ItemRecibo] = []
        for item in presentes {
            let origem = home.appendingPathComponent(item.rel)
            if let alvo = item.symlink {
                try? FileManager.default.removeItem(at: origem)
                itens.append(ItemRecibo(rel: item.rel, modo: item.modo, symlink: alvo))
            } else {
                let destino = home.appendingPathComponent(".transcentia/aposentados/\(stamp)/\(curto(item.rel))")
                try? FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.moveItem(at: origem, to: destino) } catch { continue }
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: destino.path)
                itens.append(ItemRecibo(rel: item.rel, modo: item.modo, symlink: nil))
            }
            avisos.append("AVISO: cópia antiga aposentada: \(origem.path)")
        }
        guard !itens.isEmpty else { return .nada }
        let avisoTxt = home.appendingPathComponent(".transcentia/aposentados/\(stamp)/AVISO.txt")
        try? FileManager.default.createDirectory(at: avisoTxt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("Cópias antigas do plano de controle. O launchd usa o TuttiDash.app.\n".utf8).write(to: avisoTxt)
        if let dados = try? JSONEncoder().encode(ReciboAposentadoria(stamp: stamp, itens: itens)) {
            try? dados.write(to: reciboURL(home))
        }
        return .aposentadas(avisos)
    }

    /// Devolve os arquivos ao caminho anterior. Não mexe em PAUSE nem em config.
    @discardableResult
    public static func restaurar(home: URL) -> Bool {
        let url = reciboURL(home)
        guard let dados = try? Data(contentsOf: url),
              let recibo = try? JSONDecoder().decode(ReciboAposentadoria.self, from: dados) else { return false }
        for item in recibo.itens {
            let origem = home.appendingPathComponent(item.rel)
            if let alvo = item.symlink {
                if FileManager.default.fileExists(atPath: origem.path) || symlinkExiste(origem) {
                    try? FileManager.default.removeItem(at: origem)
                }
                _ = alvo.withCString { alvoPtr in
                    origem.path.withCString { caminhoPtr in
                        Darwin.symlink(alvoPtr, caminhoPtr)
                    }
                }
                continue
            }
            let destino = home.appendingPathComponent(".transcentia/aposentados/\(recibo.stamp)/\(curto(item.rel))")
            if FileManager.default.fileExists(atPath: origem.path) { try? FileManager.default.removeItem(at: origem) }
            try? FileManager.default.createDirectory(at: origem.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: destino, to: origem)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: item.modo)], ofItemAtPath: origem.path)
        }
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".transcentia/aposentados/\(recibo.stamp)"))
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private static func reciboURL(_ home: URL) -> URL {
        home.appendingPathComponent(".transcentia/aposentados/recibo.json")
    }

    private static func curto(_ rel: String) -> String {
        let prefixo = ".transcentia/"
        return rel.hasPrefix(prefixo) ? String(rel.dropFirst(prefixo.count)) : rel
    }

    private struct Presente {
        var rel: String
        var modo: UInt16
        var symlink: String?
    }

    private static func listar(_ home: URL) -> [Presente] {
        var saida: [Presente] = []
        for rel in DoutorControle.copiasAntigas {
            if rel.contains("..") { continue }
            let url = home.appendingPathComponent(rel)
            var st = Darwin.stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let tipo = st.st_mode & S_IFMT
            if tipo == S_IFLNK {
                let alvo = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                saida.append(Presente(rel: rel, modo: 0, symlink: alvo))
            } else if tipo == S_IFREG {
                saida.append(Presente(rel: rel, modo: UInt16(st.st_mode) & 0o777, symlink: nil))
            }
        }
        return saida
    }

    private static func symlinkExiste(_ url: URL) -> Bool {
        var st = Darwin.stat()
        return lstat(url.path, &st) == 0
    }
}
