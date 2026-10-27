import Foundation

/// CONSTANTES DE MIGRAÇÃO/COMPATIBILIDADE (FRA-299). Únicos nomes antigos permitidos no app:
/// caminhos e variáveis que os scripts e a ferramenta `gasto` já usam, o bundle antigo e o
/// arquivo de config antigo. Nada de produto novo deve depender daqui.
public enum Legado {
    // MIGRAÇÃO: bundle antigo (UserDefaults `usarTelaPrincipal`).
    public static let bundleAntigo = "app.transcentia.tools.notch-gasto"
    // Pasta do app (FRA-523).
    public static let pastaApp = "Library/Application Support/TuttiDash"
    // MIGRAÇÃO: pasta e serviço do Keychain de antes do FRA-523 (lidos como reserva).
    public static let pastaLanekeeper = "Library/Application Support/Lanekeeper"
    public static let servicoCofreAntigo = "app.lanekeeper.mac"
    // MIGRAÇÃO: configs anteriores ao TuttiDash.
    public static let configLegada = ".transcentia/tools/config.json"
    public static let configProvisoria = "Library/Application Support/TranscentIA Gasto/config.json"
    // COMPAT: pastas padrão da ferramenta `gasto` e das lanes (quando a config não diz nada).
    public static let logsLanes = "Library/Logs/TranscentIA/lanes"
    public static let estadoLanes = ".transcentia/lanes"
    public static let ledger = ".transcentia/tools/ledger.jsonl"
    // COMPAT: lançador do painel de logs quando `painel.comando` não está na config.
    public static let painelComando = "~/.transcentia/tools/painel.command"
    // COMPAT: lançador da janela das lanes quando `painel.lanes_comando` não está na config.
    public static let lanesComando = "~/.transcentia/tools/lanes.command"
    // COMPAT: variáveis de ambiente aceitas pela ferramenta `gasto`.
    public static let envConfig = "TRANSCENTIA_GASTO_CONFIG"
    public static let env: [String: String] = [
        "logs_dir": "TRANSCENTIA_LANES_LOGS",
        "state_dir": "TRANSCENTIA_LANES_STATE",
        "ledger": "TRANSCENTIA_GASTO_LEDGER",
        "teto_semanal_usd": "TRANSCENTIA_GASTO_TETO",
        "aviso_pct": "TRANSCENTIA_GASTO_AVISO_PCT",
        "opencode_db": "TRANSCENTIA_OPENCODE_DB",
        "copilot_token": "TRANSCENTIA_COPILOT_TOKEN",
        "uso_contas": "TRANSCENTIA_GASTO_USO_CONTAS",
    ]
}
