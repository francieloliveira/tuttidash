import Foundation

/// Leitor dos manifests de agente (`agents.d/*.json`).
///
/// Fonte da verdade única da lista de CLIs/agentes: adicionar um agente novo =
/// 1 arquivo JSON em `agents.d/`, sem tocar em código. O Swift e o Python leem o
/// mesmo diretório, então a paridade dos dois registries é estrutural.
///
/// Os manifests versionados no repo são a fonte (E13). Em runtime o app lê a cópia
/// instalada em `~/.transcentia/agents.d/` (ou a do bundle), **só leitura**.
public enum CatalogoAgentes {

    // MARK: - Manifesto

    public struct ModeloAgente: Equatable, Sendable {
        /// Revisão de PR só leitura (revisor): o que a tela de Ajustes precisa mostrar.
        /// O comando em si é do Python (`bots/watch.py`); aqui só papel e opções.
        public struct Revisao: Equatable, Sendable {
            /// "sozinho" (aprova e bloqueia) ou "segunda_opiniao" (só bloqueia).
            public var papel: String
            /// Entra na reserva `auto`. false = só se escolhido à mão (ex.: modelo que treina com os dados).
            public var auto: Bool
            public var modelos: [String]
            public var modeloPadrao: String
            public var esforcos: [String]
            public var esforcoPadrao: String

            public init(papel: String, auto: Bool, modelos: [String], modeloPadrao: String,
                        esforcos: [String], esforcoPadrao: String) {
                self.papel = papel; self.auto = auto; self.modelos = modelos
                self.modeloPadrao = modeloPadrao; self.esforcos = esforcos; self.esforcoPadrao = esforcoPadrao
            }
        }

        public struct Modelo: Equatable, Sendable {
            /// ID do modelo no CLI (ex.: `opencode-go/deepseek-v4.1-flash`). Vazio = default do CLI.
            public var id: String
            /// Flags exatas passadas ao CLI (ex.: `["-m", "deepseek"]`).
            public var flags: [String]

            public init(id: String, flags: [String]) {
                self.id = id; self.flags = flags
            }
        }

        public struct Cor: Equatable, Sendable {
            public var base: String
            public var gradiente: String
            public var claro: String

            public init(base: String, gradiente: String, claro: String) {
                self.base = base; self.gradiente = gradiente; self.claro = claro
            }
        }

        public struct Uso: Equatable, Sendable {
            /// Tipo da conta no `ColetorUso` (pode repetir entre agentes: opencode e opencode-go).
            public var tipo: String
            /// Descrição da fonte, só para tooltip no painel.
            public var fonte: String
            /// Chave da credencial na `Configuracao` (ex.: `auth_codex`).
            public var credencial: String

            public init(tipo: String, fonte: String, credencial: String) {
                self.tipo = tipo; self.fonte = fonte; self.credencial = credencial
            }
        }

        public var nome: String
        public var rotulo: String
        public var sigla: String
        /// Executável do CLI. nil = sem execução real (conta de uso só, como o cursor).
        public var cli: String?
        /// Ordem de exibição no painel e no notch (menor primeiro).
        public var ordem: Int
        /// Entra na lista de lanes do painel/notch.
        public var painel: Bool
        public var cor: Cor
        /// Cor da lane no painel v1 ( notch enxuto). Vazio = usa a cor determinística do nome.
        public var corPainel: String
        /// "estimado" (preço de tabela) ou "informado" (servidor).
        public var custoEstimado: Bool
        /// CLI do `<cli> --resume <id>`. nil = sem resume (cai em `claude`).
        public var resumeCLI: String?
        /// Fontes de peso do dispatcher, em ordem.
        public var pesoFontes: [String]
        public var modelos: [String: Modelo]
        public var uso: Uso
        /// Filtro de privacidade da lista de modelos (OpenCode). nil = a lista não passa por esse filtro.
        public var privacidade: String? = nil
        /// Bloco `revisao` do manifesto. nil = o agente não revisa PR.
        public var revisao: Revisao? = nil
        /// true = conta fora da lista padrão. A pessoa adiciona em Ajustes › Contas.
        public var optIn: Bool = false

        /// Modelo de um esforço. nil = sem flags (usa o default do CLI).
        public func modelo(_ effort: String) -> Modelo? { modelos[effort] }
        /// Flags do modelo de um esforço (vetor vazio se não houver).
        public func flags(_ effort: String) -> [String] { modelos[effort]?.flags ?? [] }
    }

    /// Versão do schema que este código entende. Manifest com versão maior é recusado.
    public static let schemaAtual = 1

    // MARK: - Erros

    public enum ErroCatalogo: Error, Equatable, Sendable {
        case pastaInexistente(URL)
        case schemaInvalido(nome: String, versao: Int)
        case campoObrigatorio(nome: String, campo: String)
        case jsonInvalido(nome: String)

        public var mensagem: String {
            switch self {
            case .pastaInexistente(let p): return "pasta de agentes não existe: \(p.path)"
            case .schemaInvalido(let n, let v): return "\(n): schema \(v) (este app entende até \(schemaAtual))"
            case .campoObrigatorio(let n, let c): return "\(n): falta o campo obrigatório `\(c)`"
            case .jsonInvalido(let n): return "\(n): JSON inválido"
            }
        }
    }

    // MARK: - Descoberta

    /// Diretórios onde os manifests podem estar, em ordem de precedência.
    /// A cópia instalada (E13) tem prioridade; o bundle serve de fallback em dev.
    public static func diretorios(
        instalado: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcentia/agents.d"),
        fallback: URL? = Bundle.main.resourceURL?.appendingPathComponent("agents.d")
    ) -> [URL] {
        var saida: [URL] = [instalado]
        if let fallback, fallback != instalado { saida.append(fallback) }
        return saida
    }

    /// Lê todos os manifests de um diretório. Um manifest ruim não derruba os outros.
    /// - Throws: só quando nenhum manifest válido foi encontrado no diretório.
    public static func ler(diretorio: URL) throws -> [ModeloAgente] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: diretorio.path) else { throw ErroCatalogo.pastaInexistente(diretorio) }
        let nomes = ((try? fm.contentsOfDirectory(atPath: diretorio.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        var saida: [ModeloAgente] = []
        for arquivo in nomes {
            guard let m = try? lerUm(diretorio.appendingPathComponent(arquivo), nome: arquivo) else { continue }
            saida.append(m)
        }
        guard !saida.isEmpty else { throw ErroCatalogo.pastaInexistente(diretorio) }
        return saida.sorted { ($0.ordem, $0.nome) < ($1.ordem, $1.nome) }
    }

    /// Lê o primeiro diretório que tiver manifests válidos. Lista vazia = nenhum achado.
    public static func carregar(caminhos: [URL]? = nil) -> [ModeloAgente] {
        for dir in caminhos ?? diretorios() {
            if let lista = try? ler(diretorio: dir), !lista.isEmpty { return lista }
        }
        return []
    }

    private static func lerUm(_ url: URL, nome: String) throws -> ModeloAgente {
        let dados: Data
        do { dados = try Data(contentsOf: url) } catch { throw ErroCatalogo.jsonInvalido(nome: nome) }
        guard let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else {
            throw ErroCatalogo.jsonInvalido(nome: nome)
        }
        let versao = (obj["schema"] as? NSNumber).map { $0.intValue } ?? 0
        guard versao <= schemaAtual else {
            throw ErroCatalogo.schemaInvalido(nome: nome, versao: versao)
        }
        func texto(_ chave: String) throws -> String {
            guard let v = obj[chave] as? String, !v.isEmpty else {
                throw ErroCatalogo.campoObrigatorio(nome: nome, campo: chave)
            }
            return v
        }
        let rot = try texto("rotulo")
        let cli = obj["cli"] as? String
        let resume = obj["resume"] as? String
        let corObj = (obj["cor"] as? [String: Any]) ?? [:]
        func hex(_ chave: String, padrao: String) -> String {
            (corObj[chave] as? String).flatMap { $0.hasPrefix("#") ? $0 : nil } ?? padrao
        }
        let usoObj = (obj["uso"] as? [String: Any]) ?? [:]
        let modelos: [String: ModeloAgente.Modelo] = {
            guard let d = obj["modelos"] as? [String: Any] else { return [:] }
            return d.compactMapValues { v -> ModeloAgente.Modelo? in
                guard let m = v as? [String: Any] else { return nil }
                return .init(id: (m["id"] as? String) ?? "",
                             flags: (m["flags"] as? [String]) ?? [])
            }
        }()
        return ModeloAgente(
            nome: try texto("nome"), rotulo: rot, sigla: (obj["sigla"] as? String)
                ?? String(rot.prefix(1)).uppercased(),
            cli: cli, ordem: (obj["ordem"] as? NSNumber)?.intValue ?? 999,
            painel: (obj["painel"] as? NSNumber).map { $0.boolValue } ?? true,
            cor: .init(base: hex("base", padrao: "#FFFFFF"),
                       gradiente: hex("gradiente", padrao: "#FFFFFF"),
                       claro: hex("claro", padrao: "#FFFFFF")),
            corPainel: (obj["corPainel"] as? String) ?? "",
            custoEstimado: (obj["custo"] as? String) == "estimado",
            resumeCLI: resume,
            pesoFontes: (obj["pesoFontes"] as? [String]) ?? ["quota", "gasto"],
            modelos: modelos,
            uso: .init(tipo: (usoObj["tipo"] as? String) ?? "",
                       fonte: (usoObj["fonte"] as? String) ?? "",
                       credencial: (usoObj["credencial"] as? String) ?? ""),
            privacidade: privacidadeDe(obj["privacidade"]),
            revisao: revisaoDe(obj["revisao"]),
            optIn: Self.flag(obj["optIn"]))
    }

    /// `optIn: true` no manifesto. Ausente = entra na lista padrão de contas.
    static func flag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber, JV.ehBool(n) { return n.boolValue }
        return false
    }

    /// `privacidade` do manifesto. Vazio não filtra a lista.
    static func privacidadeDe(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Lê o bloco `revisao` (igual ao `_revisao` do `catalogo.py`): sem `comando`, não revisa.
    static func revisaoDe(_ v: Any?) -> ModeloAgente.Revisao? {
        guard let r = v as? [String: Any], let cmd = r["comando"] as? [Any], !cmd.isEmpty else { return nil }
        let modelos = (r["modelos"] as? [String]) ?? []
        let esforcos = (r["esforcos"] as? [String]) ?? []
        let padraoModelo = (r["modelo_padrao"] as? String) ?? ""
        let padraoEsforco = (r["esforco_padrao"] as? String) ?? ""
        return .init(papel: (r["papel"] as? String) == "segunda_opiniao" ? "segunda_opiniao" : "sozinho",
                     auto: (r["auto"] as? NSNumber).map { $0.boolValue } ?? true,
                     modelos: modelos,
                     modeloPadrao: padraoModelo.isEmpty ? (modelos.first ?? "padrao") : padraoModelo,
                     esforcos: esforcos,
                     esforcoPadrao: padraoEsforco.isEmpty ? (esforcos.first ?? "") : padraoEsforco)
    }
}