import Foundation
import SQLite3

/// Uso do contexto da sessão OpenCode, lido diretamente do `opencode.db` (SQLite local,
/// tabela `session_v2`). Não chama a rede — é uma leitura local do histórico da sessão.
///
/// A tabela `session_v2` armazena, por sessão:
///   - `tokens_input`, `tokens_output`, `tokens_reasoning`,
///     `tokens_cache_read`, `tokens_cache_write` (contagem cumulativa da sessão)
///   - `model` (ex.: "nemotron-3.5-super-vl-free")
///   - `time_updated` (época em ms, última atualização)
///
/// O % de uso do contexto = total de tokens / limite do modelo.
public enum ParserUsoOpenCodeSession {
    /// Limite de contexto (tokens) por modelo. Valores aproximados dos modelos conhecidos;
    /// modelos não mapeados caem no padrão de 128k.
    private static let limitesContexto: [String: Int] = [
        "nemotron-3.5-super-vl-free": 1_048_576,
        "claude-opus-4-1": 200_000,
        "claude-sonnet-4": 200_000,
        "claude-haiku-3-5": 200_000,
        "claude-3-5-sonnet": 200_000,
        "claude-3-haiku": 200_000,
        "gpt-5": 1_048_576,
        "gpt-5-mini": 1_048_576,
        "gpt-4o": 128_000,
        "gpt-4o-mini": 128_000,
        "grok-4-7": 256_000,
        "grok-4": 256_000,
        "grok-3": 131_072,
        "o1": 200_000,
        "o1-mini": 128_000,
        "o3-mini": 128_000,
    ]

    /// Limite padrão (conservador) para modelos não mapeados.
    private static let limitePadrao: Int = 128_000

    /// Lê a sessão mais recente do `opencode.db` e devolve o % de uso do contexto.
    ///
    /// - Parameter banco: caminho para o `opencode.db`. Se ausente, devolve `.semCredencial`.
    /// - Returns: janela única com `pct` = % usado, `resetEm` = nil (não há reset definido),
    ///   ou `.semJanelas` se não houver sessão com tokens.
    public static func ler(banco: URL) -> Result<[JanelaUso], ErroUso> {
        guard FileManager.default.fileExists(atPath: banco.path) else {
            return .failure(.semCredencial("opencode"))
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(banco.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failure(.credencialIlegivel(banco.path))
        }
        sqlite3_busy_timeout(db, 1500)

        // Busca a sessão mais recente com tokens > 0
        let sql = """
            SELECT tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write, model, time_updated
            FROM session_v2
            WHERE (tokens_input + tokens_output + tokens_reasoning +
                   tokens_cache_read + tokens_cache_write) > 0
            ORDER BY time_updated DESC
            LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.credencialIlegivel(banco.path))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return .failure(.semJanelas)
        }

        let input = Int(sqlite3_column_int64(stmt, 0))
        let output = Int(sqlite3_column_int64(stmt, 1))
        let reasoning = Int(sqlite3_column_int64(stmt, 2))
        let cacheRead = Int(sqlite3_column_int64(stmt, 3))
        let cacheWrite = Int(sqlite3_column_int64(stmt, 4))
        let modelo = String(cString: sqlite3_column_text(stmt, 5))

        let total = input + output + reasoning + cacheRead + cacheWrite
        guard total > 0 else {
            return .failure(.semJanelas)
        }

        let limite = limitesContexto[modelo] ?? limitePadrao
        let pct = Double(total) / Double(limite) * 100

        return .success([JanelaUso(chave: "contexto_sessao", rotulo: "contexto sessão", pct: pct, resetEm: nil)])
    }
}
