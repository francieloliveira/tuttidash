import Foundation
import SQLite3

/// `~/.claude/.credentials.json` do Claude Code: `{ "claudeAiOauth": { "accessToken", "expiresAt" } }`
/// (`expiresAt` em milissegundos desde a época).
public enum CredenciaisClaude {
    public static let cli = "claude"

    public static func ler(_ dados: Data, caminho: String = "~/.claude/.credentials.json") -> Result<TokenConta, ErroUso> {
        guard let obj = JV.objeto(dados), let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = JV.texto(oauth["accessToken"]) else {
            return .failure(.credencialIlegivel(caminho))
        }
        let expira = JV.numero(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .success(TokenConta(valor: token, expiraEm: expira))
    }

    /// Arquivo e Keychain: vale a credencial legível que vence mais tarde (sem validade ganha).
    /// O `claude auth login` grava só no Keychain e o arquivo fica vencido (FRA-268).
    /// Nenhuma legível: o erro do arquivo, que é o que o README explica.
    public static func escolher(arquivo: Result<TokenConta, ErroUso>,
                                keychain: Result<TokenConta, ErroUso>?) -> Result<TokenConta, ErroUso> {
        switch (arquivo, keychain) {
        case (.success(let a), .success(let k)?):
            switch (a.expiraEm, k.expiraEm) {
            case (nil, _): return .success(a)
            case (_, nil): return .success(k)
            case (let ea?, let ek?): return .success(ek > ea ? k : a)
            }
        case (.success, _): return arquivo
        case (.failure, .success(let k)?): return .success(k)
        default: return arquivo
        }
    }

    /// Versão do Claude Code, do `.last-update-result.json` que fica ao lado da credencial.
    /// Serve para o `User-Agent: claude-code/<versão>` que o endpoint de uso exige.
    public static let versaoPadrao = "2.1.278"

    public static func versao(_ dados: Data?) -> String {
        guard let dados, let obj = JV.objeto(dados) else { return versaoPadrao }
        return JV.texto(obj["version_to"]) ?? JV.texto(obj["version_from"]) ?? versaoPadrao
    }
}

/// Credencial do Claude Code no Keychain do macOS (item genérico `Claude Code-credentials`, conta =
/// usuário), com o mesmo JSON do `.credentials.json`. Lida pelo `security` do sistema, só leitura:
/// o item foi gravado pelo Claude Code e a ACL dele já libera essa ferramenta, então não abre aviso
/// de permissão (conferido em 06/10/2026). Nunca grava nem renova.
public enum KeychainClaude {
    public static let servico = "Claude Code-credentials"
    public static let rotulo = "Keychain (\(servico))"

    /// Bytes do segredo, ou nil (sem item, sem acesso ou passou de `limite` segundos).
    public static func ler(servico: String = servico, conta: String = NSUserName(),
                           limite: TimeInterval = 5) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", servico, "-a", conta, "-w"]
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        let fim = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in fim.signal() }
        do { try p.run() } catch { return nil }
        if fim.wait(timeout: .now() + limite) == .timedOut {
            p.terminate()
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        return dados.isEmpty ? nil : dados
    }
}

/// `~/.grok/auth.json` do grok CLI: um objeto por `<issuer>::<client_id>`, com o bearer em `key`
/// e a validade em `expires_at` (ISO 8601). Com mais de uma entrada, vale a que vence mais tarde.
public enum CredenciaisGrok {
    public static let cli = "grok"

    public static func ler(_ dados: Data, caminho: String = "~/.grok/auth.json") -> Result<TokenConta, ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.credencialIlegivel(caminho)) }
        var melhor: TokenConta?
        for chave in obj.keys.sorted() {
            guard let entrada = obj[chave] as? [String: Any], let token = JV.texto(entrada["key"]) else { continue }
            let expira = JV.texto(entrada["expires_at"]).flatMap { Datas.lerISO8601($0) }
            let cand = TokenConta(valor: token, expiraEm: expira)
            guard let atual = melhor else { melhor = cand; continue }
            // sem validade conta como "vale para sempre" e ganha de qualquer data
            switch (atual.expiraEm, cand.expiraEm) {
            case (_, nil): melhor = cand
            case (nil, _): break
            case (let a?, let b?): if b > a { melhor = cand }
            }
        }
        guard let melhor else { return .failure(.credencialIlegivel(caminho)) }
        return .success(melhor)
    }
}

/// Sessão do Cursor, de onde sai o token do **Grok Bot** (não confundir com o grok CLI):
/// `state.vscdb` é um SQLite com a tabela `ItemTable(key, value)`, e o JWT fica na chave
/// `cursorAuth/accessToken`. O banco é aberto com `SQLITE_OPEN_READONLY` e só faz um `SELECT`.
public enum CredenciaisCursor {
    public static let chave = "cursorAuth/accessToken"

    /// Lê o valor cru da chave. `nil` dentro do sucesso = chave ausente ou vazia.
    public static func lerChave(_ banco: URL, chave: String = chave) -> Result<String?, ErroUso> {
        guard FileManager.default.fileExists(atPath: banco.path) else { return .failure(.cursorNaoLogado) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(banco.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failure(.credencialIlegivel(banco.path))
        }
        // o Cursor aberto pode estar escrevendo: espera um pouco em vez de falhar de cara
        sqlite3_busy_timeout(db, 1500)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        else { return .failure(.credencialIlegivel(banco.path)) }
        let transitorio = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, chave, -1, transitorio)
        switch sqlite3_step(stmt) {
        case SQLITE_DONE:
            return .success(nil)
        case SQLITE_ROW:
            // o valor pode vir como TEXT ou BLOB; os dois são bytes UTF-8
            let n = Int(sqlite3_column_bytes(stmt, 0))
            guard n > 0, let p = sqlite3_column_blob(stmt, 0) else { return .success(nil) }
            return .success(String(data: Data(bytes: p, count: n), encoding: .utf8))
        default:
            return .failure(.credencialIlegivel(banco.path))
        }
    }

    /// Valor da chave -> token. Aceita o JWT puro ou entre aspas (valor gravado como JSON).
    /// A validade sai do `exp` do JWT, quando dá para ler; senão o servidor é quem decide.
    public static func token(_ bruto: String?) -> Result<TokenConta, ErroUso> {
        var t = (bruto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty, t != "null" else { return .failure(.tokenAusente(chave)) }
        return .success(TokenConta(valor: t, expiraEm: expiracaoJWT(t)))
    }

    public static func ler(_ banco: URL) -> Result<TokenConta, ErroUso> {
        lerChave(banco).flatMap(token)
    }

    /// `exp` (segundos) do payload de um JWT `cabeçalho.payload.assinatura`. Sem assinatura conferida:
    /// só serve para não gastar chamada com token vencido.
    public static func expiracaoJWT(_ jwt: String) -> Date? {
        let partes = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard partes.count == 3 else { return nil }
        var b64 = partes[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let dados = Data(base64Encoded: b64), let obj = JV.objeto(dados),
              let exp = JV.numero(obj["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Credencial genérica de CLIs novos: aceita `{ "key" | "token" |
/// "accessToken" | "api_key" }` ou `{ "auth": { ... } }`. Sem endpoint de uso mapeado,
/// o coletor mostra "sem dado" até o endpoint ser definido.
public enum CredenciaisGenericas {
    public static func ler(_ dados: Data, cli: String, caminho: String) -> Result<TokenConta, ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.credencialIlegivel(caminho)) }
        let candidatos: [String?] = [
            JV.texto(obj["key"]), JV.texto(obj["token"]), JV.texto(obj["accessToken"]),
            JV.texto(obj["api_key"]), JV.texto((obj["auth"] as? [String: Any])?["token"]),
            JV.texto((obj["auth"] as? [String: Any])?["accessToken"]),
        ]
        guard let t = candidatos.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return .failure(.credencialIlegivel(caminho))
        }
        let exp = JV.texto(obj["expires_at"]).flatMap { Datas.lerISO8601($0) }
        return .success(TokenConta(valor: t, expiraEm: exp))
    }
}

public enum CredenciaisCodex {
    public static let cli = "codex"

    /// `~/.codex/auth.json` do Codex CLI: `{ "tokens": { "access_token", "account_id", ... } }`
    /// (login ChatGPT) ou `{ "key" | "token" | "api_key" }` (API key). O `account_id`
    /// vai no cabeçalho `ChatGPT-Account-Id` (via `TokenConta.orgID`).
    public static func ler(_ dados: Data, caminho: String = "~/.codex/auth.json") -> Result<TokenConta, ErroUso> {
        guard let obj = JV.objeto(dados) else { return .failure(.credencialIlegivel(caminho)) }
        if let toks = obj["tokens"] as? [String: Any],
           let t = JV.texto(toks["access_token"]), !t.isEmpty {
            return .success(TokenConta(valor: t, orgID: JV.texto(toks["account_id"])))
        }
        return CredenciaisGenericas.ler(dados, cli: cli, caminho: caminho)
    }
}

public enum CredenciaisOpenCode {
    public static let cli = "opencode"

    /// Sessão do OpenCode Console, de onde sai o token de uso: `opencode.db` é um SQLite
    /// com a tabela `credential(id, integration_id, label, value, ...)`, e o OAuth do Console
    /// fica na linha ativa com `integration_id = 'opencode'`. O `value` é um JSON com
    /// `access`, `expires` (ms) e `metadata` (`server`, `orgID`, `email`...).
    /// Banco aberto com `SQLITE_OPEN_READONLY` e só um `SELECT` — nunca renova nem regrava
    /// (o próprio `opencode` renova sozinho no próximo uso).
    public static func lerBanco(_ banco: URL) -> Result<TokenConta, ErroUso> {
        guard FileManager.default.fileExists(atPath: banco.path) else { return .failure(.semCredencial(cli)) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(banco.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failure(.credencialIlegivel(banco.path))
        }
        sqlite3_busy_timeout(db, 1500)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM credential WHERE active = 1 AND integration_id = 'opencode' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.credencialIlegivel(banco.path))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .failure(.semCredencial(cli)) }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        guard n > 0, let p = sqlite3_column_blob(stmt, 0),
              let obj = JV.objeto(Data(bytes: p, count: n)) else { return .failure(.semCredencial(cli)) }
        return token(obj)
    }

    static func token(_ obj: [String: Any]) -> Result<TokenConta, ErroUso> {
        guard let t = JV.texto(obj["access"]), !t.isEmpty else {
            // OAuth feito, mas sem access: o CLI renova sozinho no próximo uso
            if JV.texto(obj["refresh"]) != nil { return .failure(.tokenExpirado(cli)) }
            return .failure(.semCredencial(cli))
        }
        let expira = JV.numero(obj["expires"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        var org: String?
        if let meta = obj["metadata"] as? [String: Any] { org = JV.texto(meta["orgID"]) }
        return .success(TokenConta(valor: t, expiraEm: expira, orgID: org ?? JV.texto(obj["orgID"])))
    }

    /// Banco primeiro; arquivo `auth.json` como alternativa quando o banco não existe.
    public static func ler(banco: URL, arquivo: URL,
                           lerArquivo: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Result<TokenConta, ErroUso> {
        if FileManager.default.fileExists(atPath: banco.path) { return lerBanco(banco) }
        guard let dados = lerArquivo(arquivo) else { return .failure(.semCredencial(cli)) }
        return ler(dados, caminho: arquivo.path)
    }

    public static func ler(_ dados: Data, caminho: String = "~/.local/share/opencode/auth.json") -> Result<TokenConta, ErroUso> {
        CredenciaisGenericas.ler(dados, cli: cli, caminho: caminho)
    }
}

/// `~/.gemini/oauth_creds.json` do Gemini CLI: `{ "access_token", "expiry_date" }`.
/// `expiry_date` é milissegundos desde a época (o mesmo relógio do `google-auth-library`).
/// O app só lê. Não usa `refresh_token` e não grava o arquivo: token vencido ou 401
/// fica «sem dado» e o próprio `gemini` renova no próximo uso.
public enum CredenciaisGemini {
    public static let cli = "gemini"

    public static func ler(_ dados: Data, caminho: String = "~/.gemini/oauth_creds.json") -> Result<TokenConta, ErroUso> {
        guard let obj = JV.objeto(dados),
              let token = JV.texto(obj["access_token"]), !token.isEmpty else {
            return .failure(.credencialIlegivel(caminho))
        }
        return .success(TokenConta(valor: token, expiraEm: expiracao(obj)))
    }

    /// `expiry_date` em ms. `expiry` numérico grande também é ms; texto é ISO 8601.
    static func expiracao(_ obj: [String: Any]) -> Date? {
        if let ms = JV.numero(obj["expiry_date"]), ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = JV.numero(obj["expiry"]), ms > 1e11 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return JV.texto(obj["expiry"]).flatMap { Datas.lerISO8601($0) }
    }
}

/// Grant da conta DeepSeek guardado pelo DeepSeek Harness em `~/.dsh/.credentials.yaml`
/// (registro `deepseek-account-platform/default`, campo `payload.token`). Leitura de texto
/// simples, sem dependência de YAML: só esse registro, só esse campo. Nunca grava.
public enum CredenciaisDeepSeek {
    public static let cli = "dsh"
    static let registro = "deepseek-account-platform/default:"

    public static func ler(_ dados: Data, caminho: String = "~/.dsh/.credentials.yaml") -> Result<TokenConta, ErroUso> {
        guard let texto = String(data: dados, encoding: .utf8) else { return .failure(.credencialIlegivel(caminho)) }
        var dentro = false
        var recuo = -1
        for linha in texto.components(separatedBy: .newlines) {
            let semEspaco = linha.trimmingCharacters(in: .whitespaces)
            let nivel = linha.prefix { $0 == " " }.count
            if semEspaco == registro { dentro = true; recuo = nivel; continue }
            guard dentro else { continue }
            if !semEspaco.isEmpty && nivel <= recuo { break }   // próximo registro
            if semEspaco.hasPrefix("token:") {
                var v = String(semEspaco.dropFirst("token:".count)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let p = v.first, (p == "\"" || p == "'"), v.last == p { v = String(v.dropFirst().dropLast()) }
                return v.isEmpty ? .failure(.semCredencial(cli)) : .success(TokenConta(valor: v))
            }
        }
        return .failure(.semCredencial(cli))
    }
}
