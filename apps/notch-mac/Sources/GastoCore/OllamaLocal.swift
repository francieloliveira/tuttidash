import Foundation

/// Ollama local (modelo da triagem do vigia e da lane Ollama). Só consulta o servidor do
/// próprio Mac (`localhost:11434`); baixar um modelo só acontece pelo clique em «Baixar».
public enum OllamaLocal {
    public static let base = URL(string: "http://localhost:11434")!
    /// Chave do modelo nos Ajustes. Vazio = o primeiro modelo baixado.
    public static let chaveModelo = "watch.modelo_needs_ollama"
    public static let paginaDownload = URL(string: "https://ollama.com/download")!
    /// Onde o Ollama costuma estar (app e Homebrew).
    public static let caminhos = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama",
                                  "/Applications/Ollama.app/Contents/Resources/ollama"]

    public enum Estado: Equatable, Sendable {
        case naoInstalado
        case parado
        case semModelo
        case naoBaixado(String)
        case pronto(String)

        public var texto: String {
            switch self {
            case .naoInstalado: return String(localized: "Ollama não instalado")
            case .parado: return String(localized: "Ollama instalado, mas parado")
            case .semModelo: return String(localized: "Nenhum modelo baixado")
            case .naoBaixado(let m): return String(localized: "Modelo \(m) não baixado")
            case .pronto(let m): return String(localized: "Pronto: \(m)")
            }
        }
        public var ok: Bool { if case .pronto = self { return true }; return false }
    }

    /// `gemma4` e `gemma4:latest` são o mesmo modelo para o Ollama.
    public static func mesmoModelo(_ a: String, _ b: String) -> Bool {
        func n(_ x: String) -> String {
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.contains(":") ? t : t + ":latest"
        }
        return n(a) == n(b)
    }

    /// Estado a partir do que se sabe: binário presente, lista do servidor (nil = parado) e escolha.
    public static func estado(instalado: Bool, modelos: [String]?, escolhido: String) -> Estado {
        guard let modelos else { return instalado ? .parado : .naoInstalado }
        let e = escolhido.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return modelos.first.map { .pronto($0) } ?? .semModelo }
        return modelos.contains { mesmoModelo($0, e) } ? .pronto(e) : .naoBaixado(e)
    }

    public static func instalado(_ existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        caminhos.contains(where: existe)
    }

    /// `GET /api/tags` → nomes dos modelos. Corpo ilegível = nil.
    public static func lerModelos(_ dados: Data) -> [String]? {
        guard let obj = JV.objeto(dados) else { return nil }
        let lista = (obj["models"] as? [[String: Any]]) ?? []
        return lista.compactMap { JV.texto($0["name"]) }
    }

    /// Uma linha do `POST /api/pull` (stream). `fracao` só quando o servidor informa total.
    public struct Progresso: Equatable, Sendable {
        public var status: String
        public var fracao: Double?
        public var erro: String?
        public var fim: Bool { status == "success" }
    }

    public static func lerLinhaPull(_ linha: String) -> Progresso? {
        guard let obj = JV.objeto(Data(linha.utf8)) else { return nil }
        if let e = JV.texto(obj["error"]) { return Progresso(status: "erro", fracao: nil, erro: e) }
        let status = JV.texto(obj["status"]) ?? ""
        var fracao: Double?
        if let total = JV.numero(obj["total"]), total > 0, let feito = JV.numero(obj["completed"]) {
            fracao = min(max(feito / total, 0), 1)
        }
        return Progresso(status: status, fracao: fracao, erro: nil)
    }

    /// Modelos baixados; nil = servidor fora do ar.
    public static func modelos(timeout: TimeInterval = 3) async -> [String]? {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"), timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (dados, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return lerModelos(dados)
    }

    /// Baixa o modelo pelo servidor local, chamando `progresso` a cada linha. Erro do servidor vira throw.
    public static func baixar(_ modelo: String, progresso: @escaping @Sendable (Progresso) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/pull"), timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelo, "stream": true])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ErroOllama.servidor("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        for try await linha in bytes.lines {
            guard let p = lerLinhaPull(linha) else { continue }
            if let e = p.erro { throw ErroOllama.servidor(e) }
            progresso(p)
        }
    }

    public enum ErroOllama: Error, LocalizedError, Equatable {
        case servidor(String)
        public var errorDescription: String? {
            if case .servidor(let m) = self { return String(localized: "O Ollama recusou: \(m)") }
            return nil
        }
    }
}
