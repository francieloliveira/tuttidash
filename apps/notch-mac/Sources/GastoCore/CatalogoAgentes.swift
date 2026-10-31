import CryptoKit
import Darwin
import Foundation

/// Leitor dos manifests de agente (`agents.d/*.json`).
///
/// Fonte da verdade única da lista de CLIs/agentes: adicionar um agente novo =
/// 1 arquivo JSON em `agents.d/`, sem tocar em código. O Swift e o Python leem o
/// mesmo diretório, então a paridade dos dois registries é estrutural.
///
/// Os manifests versionados no repo são a fonte (E13). Em runtime o app lê a cópia
/// instalada em `~/.transcentia/agents.d/` só quando o hash e o dono batem com o
/// `agents.d` do bundle assinado (FRA-604). Sem isso, vale o bundle — ou nada.
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
            /// `flag_esforco` do manifesto: vazio = o CLI não recebe esforço (mesmo critério do Python).
            public var flagEsforco: [String]

            public init(papel: String, auto: Bool, modelos: [String], modeloPadrao: String,
                        esforcos: [String], esforcoPadrao: String, flagEsforco: [String] = []) {
                self.papel = papel; self.auto = auto; self.modelos = modelos
                self.modeloPadrao = modeloPadrao; self.esforcos = esforcos; self.esforcoPadrao = esforcoPadrao
                self.flagEsforco = flagEsforco
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
        /// Bloco `instalar` (FRA-570): como instala e como entra. nil = o app não oferece o botão.
        public var instalar: Instalar? = nil

        public struct Instalar: Equatable, Sendable {
            /// Nome na lista de ferramentas. Vazio = o rótulo do agente.
            public var nome: String
            /// Comando oficial de instalação.
            public var comando: String
            /// Comando que entra na conta. Vazio = não precisa.
            public var entrar: String
            /// O que fazer depois de abrir o `entrar`.
            public var dicaEntrar: String
            /// Documentação oficial da instalação.
            public var docs: String
            public init(nome: String = "", comando: String, entrar: String = "", dicaEntrar: String = "", docs: String = "") {
                self.nome = nome; self.comando = comando; self.entrar = entrar; self.dicaEntrar = dicaEntrar; self.docs = docs
            }
        }

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

    /// `cli` que pode virar executável. Fora disto o campo é ignorado (não vira comando).
    public static func cliValido(_ cli: String) -> Bool {
        cli.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    /// Diretórios de manifesto em que o app confia, em ordem de precedência.
    ///
    /// O bundle só entra se a assinatura do processo for válida. A cópia instalada
    /// (E13) só entra na frente quando cada JSON é arquivo regular, do mesmo uid,
    /// e o SHA-256 é igual ao do bundle. `dono` e `hash` existem para o teste
    /// simular dono errado sem `chown`.
    public static func diretorios(
        instalado: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcentia/agents.d"),
        fallback: URL? = Bundle.main.resourceURL?.appendingPathComponent("agents.d"),
        bundleAssinado: Bool? = nil,
        uid: uid_t = getuid(),
        dono: ((URL) -> uid_t?)? = nil,
        hash: ((URL) -> String?)? = nil
    ) -> [URL] {
        let assinado = bundleAssinado ?? processoAssinado
        guard assinado, let fallback, FileManager.default.fileExists(atPath: fallback.path) else { return [] }
        var saida = [fallback]
        if fallback.standardizedFileURL.path != instalado.standardizedFileURL.path,
           ArquivoConfianca.copiaConfiavel(instalado: instalado, referencia: fallback, uid: uid,
                                           dono: dono ?? ArquivoConfianca.dono,
                                           hash: hash ?? ArquivoConfianca.sha256) {
            saida.insert(instalado, at: 0)
        }
        return saida
    }

    /// Assinatura do processo, calculada uma vez. Testes passam `bundleAssinado` e não chegam aqui.
    private static let processoAssinado: Bool = ArquivoConfianca.bundleAssinado()

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
    ///
    /// Sem `caminhos`, a busca é a de `diretorios()` (bundle assinado ou cópia conferida).
    /// `caminhos` explícito é de quem já escolheu a pasta — os testes do repo usam isso.
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
        let cli = (obj["cli"] as? String).flatMap { cliValido($0) ? $0 : nil }
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
            optIn: Self.flag(obj["optIn"]),
            instalar: instalarDe(obj["instalar"]))
    }

    /// Bloco `instalar` do manifesto. Sem `comando`, não há botão.
    static func instalarDe(_ v: Any?) -> ModeloAgente.Instalar? {
        guard let d = v as? [String: Any], let cmd = d["comando"] as? String,
              !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let t = { (k: String) in (d[k] as? String) ?? "" }
        return .init(nome: t("nome"), comando: cmd, entrar: t("entrar"), dicaEntrar: t("dica_entrar"), docs: t("docs"))
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
                     esforcoPadrao: padraoEsforco.isEmpty ? (esforcos.first ?? "") : padraoEsforco,
                     flagEsforco: (r["flag_esforco"] as? [String]) ?? [])
    }
}

/// Confere assinatura do bundle e o par hash/dono da cópia instalada (FRA-604).
enum ArquivoConfianca {
    static func bundleAssinado(_ bundle: Bundle = .main) -> Bool {
        Subprocesso.rodar("/usr/bin/codesign", ["--verify", bundle.bundleURL.path]).codigo == 0
    }

    static func sha256(_ url: URL) -> String? {
        guard let dados = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: dados).map { String(format: "%02x", Int($0)) }.joined()
    }

    /// uid do arquivo ou da pasta. Symlink devolve nil: o alvo não herda a confiança do link.
    static func dono(_ url: URL) -> uid_t? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let tipo = st.st_mode & S_IFMT
        guard tipo == S_IFREG || tipo == S_IFDIR else { return nil }
        return st.st_uid
    }

    static func copiaConfiavel(instalado: URL, referencia: URL, uid: uid_t,
                               dono: (URL) -> uid_t?, hash: (URL) -> String?) -> Bool {
        var pasta = Darwin.stat()
        guard lstat(instalado.path, &pasta) == 0, (pasta.st_mode & S_IFMT) == S_IFDIR, pasta.st_uid == uid else {
            return false
        }
        guard let nomesI = jsons(instalado), let nomesR = jsons(referencia),
              !nomesI.isEmpty, nomesI == nomesR else { return false }
        for nome in nomesI {
            let a = instalado.appendingPathComponent(nome)
            let b = referencia.appendingPathComponent(nome)
            guard arquivoRegular(a), arquivoRegular(b), dono(a) == uid,
                  let ha = hash(a), let hb = hash(b), ha == hb else { return false }
        }
        return true
    }

    private static func jsons(_ dir: URL) -> [String]? {
        guard let nomes = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let lista = nomes.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        guard lista.allSatisfy({ $0.range(of: #"^[A-Za-z0-9._-]+\.json$"#, options: .regularExpression) != nil }) else {
            return nil
        }
        return lista
    }

    private static func arquivoRegular(_ url: URL) -> Bool {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }
}