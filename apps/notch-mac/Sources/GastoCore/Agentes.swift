import Foundation

/// Registry de agentes (FRA-373/410). Deriva de `agents.d/*.json` (fonte única).
///
/// Adicionar um agente novo = 1 arquivo JSON em `agents.d/`. O código abaixo só
/// consulta o catálogo — não conhece nenhum agente específico. Se o diretório não
/// estiver disponível (dev sem instalar, teste isolado), cai no registry embutido,
/// que é uma cópia dos mesmos manifests.
public enum Agentes {
    public struct Def: Sendable, Equatable {
        public var nome: String
        /// Rótulo exibido no painel e nos Ajustes.
        public var rotulo: String
        /// Sigla de 2 letras usada na UI (ex.: "CL", "GR").
        public var sigla: String
        /// Custo > 0 é estimativa a preço de tabela (senão, informado pelo servidor).
        public var custoEstimado: Bool
        /// CLI do `<cli> --resume <id>`. nil = sem resume conhecido (cai em `claude`).
        public var resumeCLI: String?
        /// Fontes de peso do dispatcher, em ordem (FRA-371): quota, gasto do ledger, manual.
        public var pesoFontes: [String]
        /// Executável do CLI. nil = conta de uso sem execução real (cursor).
        public var cli: String?
        /// Entra na lista de lanes do painel/notch.
        public var painel: Bool
        /// Ordem de exibição (menor primeiro).
        public var ordem: Int
        /// Cores em hex (`#RRGGBB`). Vazia quando o agente não define cor própria.
        public var corBase: String
        public var corGradiente: String
        public var corClaro: String
        public var corPainel: String
        /// Tipo da conta no `ColetorUso` (pode repetir entre agentes).
        public var tipoUso: String
        public var fonteUso: String
        public var credencialUso: String
        /// true = não entra na lista padrão de contas. A pessoa liga em Ajustes › Contas.
        public var optIn: Bool

        init(nome: String, rotulo: String, sigla: String, custoEstimado: Bool,
             resumeCLI: String?, pesoFontes: [String], cli: String?, painel: Bool,
             ordem: Int, corBase: String, corGradiente: String, corClaro: String,
             corPainel: String, tipoUso: String, fonteUso: String, credencialUso: String,
             optIn: Bool = false) {
            self.nome = nome; self.rotulo = rotulo; self.sigla = sigla
            self.custoEstimado = custoEstimado; self.resumeCLI = resumeCLI
            self.pesoFontes = pesoFontes; self.cli = cli; self.painel = painel
            self.ordem = ordem; self.corBase = corBase; self.corGradiente = corGradiente
            self.corClaro = corClaro; self.corPainel = corPainel; self.tipoUso = tipoUso
            self.fonteUso = fonteUso; self.credencialUso = credencialUso
            self.optIn = optIn
        }

        init(_ m: CatalogoAgentes.ModeloAgente) {
            self.init(nome: m.nome, rotulo: m.rotulo, sigla: m.sigla,
                      custoEstimado: m.custoEstimado, resumeCLI: m.resumeCLI,
                      pesoFontes: m.pesoFontes, cli: m.cli, painel: m.painel,
                      ordem: m.ordem, corBase: m.cor.base, corGradiente: m.cor.gradiente,
                      corClaro: m.cor.claro, corPainel: m.corPainel, tipoUso: m.uso.tipo,
                      fonteUso: m.uso.fonte, credencialUso: m.uso.credencial,
                      optIn: m.optIn)
        }
    }

    // MARK: - Catálogo

    /// Todos os agentes lidos de `agents.d/` (cai nos embutidos se o diretório faltar).
    /// Uma conta `optIn` que o binário já conhece entra mesmo se a cópia instalada
    /// (`~/.transcentia/agents.d`) ainda for antiga: senão Ajustes não deixa adicionar.
    public static var todos: [Def] {
        let lidos = CatalogoAgentes.carregar().map(Def.init).ifVazio(embutidos)
        let nomes = Set(lidos.map(\.nome))
        let extras = embutidos.filter { $0.optIn && !nomes.contains($0.nome) }
        guard !extras.isEmpty else { return lidos }
        return (lidos + extras).sorted { ($0.ordem, $0.nome) < ($1.ordem, $1.nome) }
    }

    /// Cópia dos manifests no código: só usada quando o diretório não existe.
    /// Mantida em paridade com `agents.d/` por teste (`AgentesTests`).
    static let embutidos: [Def] = [
        Def(nome: "claude", rotulo: "Claude Code", sigla: "CL", custoEstimado: true,
            resumeCLI: "claude", pesoFontes: ["quota", "gasto"], cli: "claude", painel: true,
            ordem: 1, corBase: "#FF8A5C", corGradiente: "#E8673C", corClaro: "#FFAE85",
            corPainel: "#9B7BFF", tipoUso: "claude",
            fonteUso: "", credencialUso: ""),
        Def(nome: "codex", rotulo: "Codex", sigla: "CX", custoEstimado: true,
            resumeCLI: "codex", pesoFontes: ["quota", "gasto"], cli: "codex", painel: true,
            ordem: 2, corBase: "#7D5CFF", corGradiente: "#5B3DF0", corClaro: "#B79DFF",
            corPainel: "#3DFFA8", tipoUso: "codex",
            fonteUso: "", credencialUso: ""),
        Def(nome: "opencode", rotulo: "OpenCode", sigla: "OP", custoEstimado: true,
            resumeCLI: "opencode", pesoFontes: ["quota", "gasto"], cli: "opencode", painel: true,
            ordem: 3, corBase: "#FF7AB8", corGradiente: "#E14E96", corClaro: "#FFAED4",
            corPainel: "#3DE8FF", tipoUso: "opencode",
            fonteUso: "", credencialUso: ""),
        Def(nome: "opencode-go", rotulo: "OpenCode Go", sigla: "OG", custoEstimado: true,
            resumeCLI: "opencode", pesoFontes: ["quota", "gasto"], cli: "opencode", painel: true,
            ordem: 4, corBase: "#5CFFC8", corGradiente: "#2E9BFF", corClaro: "#9BE6FF",
            corPainel: "#5CFFC8", tipoUso: "opencode",
            fonteUso: "", credencialUso: ""),
        Def(nome: "grok", rotulo: "Grok CLI", sigla: "GR", custoEstimado: false,
            resumeCLI: "grok", pesoFontes: ["quota", "gasto"], cli: "grok", painel: true,
            ordem: 5, corBase: "#5CD3FF", corGradiente: "#2E9BFF", corClaro: "#9BE6FF",
            corPainel: "#5CD3FF", tipoUso: "grok",
            fonteUso: "", credencialUso: ""),
        Def(nome: "cursor", rotulo: "Grok Bot / SuperGrok (via Cursor)", sigla: "CU", custoEstimado: false,
            resumeCLI: nil, pesoFontes: ["quota"], cli: nil, painel: false,
            ordem: 6, corBase: "#5CFFC8", corGradiente: "#5CFFC8", corClaro: "#5CFFC8",
            corPainel: "#5CFFC8", tipoUso: "cursor",
            fonteUso: "",
            credencialUso: ""),
        Def(nome: "gemini", rotulo: "Gemini", sigla: "GE", custoEstimado: false,
            resumeCLI: "gemini", pesoFontes: ["quota"], cli: "gemini", painel: false,
            ordem: 7, corBase: "#4C8DFF", corGradiente: "#2F6FE0", corClaro: "#A9C8FF",
            corPainel: "#4C8DFF", tipoUso: "gemini",
            fonteUso: "",
            credencialUso: "", optIn: true),
        Def(nome: "copilot", rotulo: "Copilot", sigla: "CP", custoEstimado: false,
            resumeCLI: nil, pesoFontes: ["quota"], cli: nil, painel: false,
            ordem: 8, corBase: "#6E40C9", corGradiente: "#4B2A8C", corClaro: "#C4B5FD",
            corPainel: "#6E40C9", tipoUso: "copilot",
            fonteUso: "api.github.com/users/{username}/settings/billing/premium_request/usage",
            credencialUso: "copilot_token", optIn: true),
    ]

    // MARK: - Consultas

    /// Agente pelo nome.
    public static func def(_ nome: String) -> Def? { todos.first { $0.nome == nome } }

    /// Ordem dos agentes no painel (para o registro, todos).
    public static var ordem: [String] { todos.map(\.nome) }

    /// Só os que entram na lista de lanes do painel/notch, na ordem de exibição.
    public static var ordemPainel: [String] { todos.filter(\.painel).map(\.nome) }

    public static func peso(nome: String) -> (Int, String) {
        (ordem.firstIndex(of: nome) ?? ordem.count, nome)
    }

    public static func ordemLane(_ a: String, _ b: String) -> Bool {
        peso(nome: a) < peso(nome: b)
    }

    public static var custoEstimado: Set<String> {
        Set(todos.filter(\.custoEstimado).map(\.nome))
    }

    public static var clisComResume: [String] {
        todos.compactMap(\.resumeCLI)
    }

    /// CLI do `<cli> --resume <id>`. Sem resume conhecido, cai em `claude`.
    public static func cliResume(lane: String) -> String {
        def(lane)?.resumeCLI ?? "claude"
    }

    /// Tipos de conta medidos pelo `ColetorUso`, sem repetir (vários agentes podem
    /// medir a mesma conta, ex.: opencode e opencode-go medem o Console).
    public static var tiposConta: [String] {
        var vistos = Set<String>()
        return todos.map(\.tipoUso).filter { !$0.isEmpty && vistos.insert($0).inserted }
    }
}

extension Array {
    /// Usa o fallback quando a lista veio vazia (catálogo ausente no ambiente).
    func ifVazio(_ fallback: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
}