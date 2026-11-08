import Foundation

/// Listas de modelos pelo login das ferramentas, sem chave de API (não oficial: só com `nao_oficial`).
/// O TuttiDash aberto lista o Claude só com `ANTHROPIC_API_KEY` e o Codex pela cache do CLI ou
/// `OPENAI_API_KEY`. Só leitura: nenhuma credencial é renovada ou regravada.
public enum ModelosNaoOficiais {
    public static func registrar(tipos: Set<String>) {
        if tipos.contains("claude") { ListasExtras.registrar(lane: "claude") { home in modelosClaude(home: home) } }
        if tipos.contains("codex") { ListasExtras.registrar(lane: "codex") { home in modelosCodex(home: home) } }
    }

    /// Credenciais do Claude Code (arquivo e Keychain), a que vence mais tarde primeiro; sem validade
    /// vem antes. O `claude auth login` grava só no Keychain e o arquivo fica vencido (FRA-268, FRA-564).
    public static func candidatosClaude(arquivo: Data?, keychain: Data?) -> [TokenConta] {
        var todos: [TokenConta] = []
        for dados in [arquivo, keychain] {
            guard let dados, case .success(let conta) = CredenciaisClaude.ler(dados),
                  !todos.contains(where: { $0.valor == conta.valor }) else { continue }
            todos.append(conta)
        }
        return todos.enumerated().sorted { a, b in
            switch (a.element.expiraEm, b.element.expiraEm) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): return x == y ? a.offset < b.offset : x > y
            }
        }.map(\.element)
    }

    static func modelosClaude(home: URL, keychain: () -> Data? = { KeychainClaude.ler() }) -> ResultadoLista {
        let vencido = String(localized: "O login do Claude Code venceu. Abra o Claude Code para renovar e reabra os Ajustes.")
        let arquivo = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
        let candidatos = candidatosClaude(arquivo: arquivo, keychain: keychain())
        guard !candidatos.isEmpty else {
            return .falha(String(localized: "Sem login do Claude Code neste Mac. Entre no Claude Code e reabra os Ajustes."))
        }
        var ultimo = ResultadoLista.falha(vencido)
        for conta in candidatos {
            var req = ListaModelos.pedidoClaude()
            req.setValue("Bearer \(conta.valor)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let resposta = ListaModelos.sincrono(req)
            ultimo = ListaModelos.resultado(resposta, ferramenta: "Claude", vencido: vencido)
            // Só um login recusado passa para a próxima credencial.
            guard resposta.status == 401 || resposta.status == 403 else { return ultimo }
        }
        return ultimo
    }

    /// `~/.codex/auth.json`: a chave de API guardada pelo CLI, senão o login do ChatGPT.
    static func modelosCodex(home: URL) -> ResultadoLista {
        let vencido = String(localized: "O login do Codex venceu. Rode o codex no Terminal para renovar e reabra os Ajustes.")
        guard let dados = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
              let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
            return .falha(String(localized: "Sem login do Codex neste Mac. Rode o codex uma vez e reabra os Ajustes."))
        }
        for chave in ["OPENAI_API_KEY", "api_key", "key"] {
            if let tok = obj[chave] as? String, !tok.isEmpty {
                return ListaModelos.resultado(ListaModelos.sincrono(ListaModelos.pedidoOpenAI(tok)),
                                              ferramenta: "OpenAI", vencido: vencido)
            }
        }
        guard let toks = obj["tokens"] as? [String: Any],
              let tok = toks["access_token"] as? String, !tok.isEmpty else {
            return .falha(String(localized: "Sem login do Codex neste Mac. Rode o codex uma vez e reabra os Ajustes."))
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/models")!)
        req.timeoutInterval = 8
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        if let conta = toks["account_id"] as? String, !conta.isEmpty {
            req.setValue(conta, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return ListaModelos.resultado(ListaModelos.sincrono(req), ferramenta: "Codex", vencido: vencido)
    }
}
