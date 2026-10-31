import Darwin
import Foundation

/// Login da conta no Terminal, por argv (FRA-604). O `cli` do manifesto não entra cru no script:
/// tem de casar com `^[a-z0-9][a-z0-9-]*$` e existir num caminho que `Ferramentas.achar` acha.
public enum LoginConta {
    public enum Erro: Error { case arquivo }

    /// Subcomandos fixos. O OpenCode entra com `auth login`; os outros CLIs, só o binário.
    public static func subcomandos(tipo: String, cli: String) -> [String] {
        if tipo == "opencode" || cli == "opencode" { return ["auth", "login"] }
        return []
    }

    /// Argv do login, ou nil se o cli é inválido ou o binário não está instalado.
    public static func argv(tipo: String, cli: String?,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String]? {
        guard let cli, CatalogoAgentes.cliValido(cli),
              let bin = Ferramentas.achar(cli, home: home, existe: existe), caminhoDeBinario(bin) else { return nil }
        return [bin] + subcomandos(tipo: tipo, cli: cli)
    }

    /// Só letras, números, hífen e sublinhado. `../../x` vira `x`.
    public static func sanitizarConta(_ conta: String) -> String {
        let limpo = conta.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let curto = String(limpo.prefix(32))
        return curto.isEmpty ? "conta" : curto
    }

    /// Grava um `.command` com nome aleatório (`mkstemps`) e modo 0700. A conta só entra sanitizada no prefixo.
    public static func gravar(argv: [String], conta: String, em pasta: URL) throws -> URL {
        guard let bin = argv.first, caminhoDeBinario(bin), argv.dropFirst().allSatisfy(argumentoSeguro) else {
            throw Erro.arquivo
        }
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let prefixo = "tuttidash-login-\(sanitizarConta(conta))-"
        let modelo = pasta.appendingPathComponent("\(prefixo)XXXXXX.command").path
        var bytes = Array(modelo.utf8CString)
        let fd = bytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return mkstemps(base, 8)
        }
        guard fd >= 0 else { throw Erro.arquivo }
        defer { close(fd) }
        let caminho = bytes.withUnsafeBufferPointer { buf -> String in
            guard let base = buf.baseAddress else { return "" }
            return String(cString: base)
        }
        guard !caminho.isEmpty, fchmod(fd, S_IRWXU) == 0 else {
            if !caminho.isEmpty { unlink(caminho) }
            throw Erro.arquivo
        }
        let script = "#!/bin/bash\nexec " + argv.map(Ferramentas.aspas).joined(separator: " ") + "\n"
        guard escreverTudo(fd: fd, dados: Data(script.utf8)) else {
            unlink(caminho)
            throw Erro.arquivo
        }
        return URL(fileURLWithPath: caminho)
    }

    /// Caminho absoluto, sem meta de shell. O primeiro elemento do argv é o binário resolvido.
    static func caminhoDeBinario(_ caminho: String) -> Bool {
        caminho.hasPrefix("/") && !caminho.contains("..") && !Ferramentas.temMetaShell(caminho) && !caminho.contains("|")
    }

    private static func argumentoSeguro(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("..") && !s.contains("/") && !Ferramentas.temMetaShell(s)
            && !s.contains("|") && !s.contains("'")
            && s.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    private static func escreverTudo(fd: Int32, dados: Data) -> Bool {
        var off = 0
        let bytes = [UInt8](dados)
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: off), bytes.count - off)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            off += n
        }
        return true
    }
}
