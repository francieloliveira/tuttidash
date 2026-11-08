import Foundation

/// Caminhos das credenciais lidas pelas fontes não oficiais: variável de ambiente > config > padrão.
/// Gravar troca o valor da config (`extras`), como uma chave do arquivo.
public extension Configuracao {
    var credClaude: URL {
        get { caminho("claude_cred", "~/.claude/.credentials.json") }
        set { extras["claude_cred"] = newValue.path }
    }
    var claudeKeychain: Bool {
        get { booleanoExtra("claude_keychain", env: FontesNaoOficiais.env["claude_keychain"], padrao: true) }
        set { extras["claude_keychain"] = newValue ? "true" : "false" }
    }
    /// O grok CLI aceita GROK_HOME em vez de ~/.grok.
    var authGrok: URL {
        get {
            let grokHome = ambiente["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.grok"
            return caminho("grok_auth", grokHome + "/auth.json")
        }
        set { extras["grok_auth"] = newValue.path }
    }
    var cursorDB: URL {
        get { caminho("cursor_db", "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb") }
        set { extras["cursor_db"] = newValue.path }
    }
    var authCodex: URL {
        get { caminho("codex_auth", "~/.codex/auth.json") }
        set { extras["codex_auth"] = newValue.path }
    }
    var authGemini: URL {
        get { caminho("gemini_auth", "~/.gemini/oauth_creds.json") }
        set { extras["gemini_auth"] = newValue.path }
    }
    var authOpenCode: URL {
        get { caminho("opencode_auth", "~/.local/share/opencode/auth.json") }
        set { extras["opencode_auth"] = newValue.path }
    }

    var credDeepSeek: URL {
        get { caminho("deepseek_cred", "~/.dsh/.credentials.yaml") }
        set { extras["deepseek_cred"] = newValue.path }
    }

    private func caminho(_ chave: String, _ padrao: String) -> URL {
        caminhoExtra(chave, env: FontesNaoOficiais.env[chave], padrao: padrao)
    }
}
