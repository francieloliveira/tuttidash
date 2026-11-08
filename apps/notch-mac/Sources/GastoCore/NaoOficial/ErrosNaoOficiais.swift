
/// Motivos de "sem dado" das fontes não oficiais (Cursor e Gemini), sobre os casos genéricos do GastoCore.
public extension ErroUso {
    /// O `state.vscdb` do Cursor não existe (Cursor nunca abriu/logou neste Mac).
    static var cursorNaoLogado: ErroUso { .motivo("Cursor não logado (state.vscdb não encontrado)") }
    /// O banco existe, mas a chave do token não está lá ou está vazia.
    static func tokenAusente(_ chave: String) -> ErroUso { .motivo("token ausente (\(chave) vazio — faça login no Cursor)") }
    /// O JWT do Cursor já venceu. O app não renova (não grava no state.vscdb).
    static var tokenCursorVencido: ErroUso { .motivo("token do Cursor vencido (abra o Cursor para renovar)") }
    /// O `loadCodeAssist` marca a conta consumer (Google AI Pro/Ultra) como cliente não suportado.
    /// Não há segunda tentativa nesta leitura: espera como depois de um 429.
    static var contaConsumerBarrada: ErroUso {
        .motivoEsperar("conta consumer (Google AI Pro/Ultra) barrada pelo Google; sem nova tentativa nesta leitura")
    }
}
