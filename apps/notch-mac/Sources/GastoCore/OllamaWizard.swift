import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Ollama no wizard de projeto: rascunho do norte quando nenhum CLI tem conta.
///
/// A regra é de tamanho, não de nome: o modelo tem de caber no teto e na memória livre
/// do Mac naquele momento. O teste de 08/11 (`qwen2.5-coder:14b` com 32k de contexto,
/// 15,8 GB) travou um Mac de 16 GB; aqui o contexto é fixo em 8k e o modelo sai da
/// memória assim que responde (`keep_alive: 0`).
public enum OllamaWizard {
    /// Modelo escolhido nos Ajustes. Separado do modelo da triagem do vigia.
    public static let chaveModelo = "wizard.modelo_ollama"
    /// Teto em GB (tamanho do modelo em disco). Ausente = `tetoPadrao`.
    public static let chaveTetoGB = "wizard.teto_ollama_gb"
    /// Modelo que o «Baixar» do wizard oferece: instrução geral de 8B, 5,2 GB em Q4.
    public static let modeloSugerido = "qwen3:8b"
    /// O Ollama informa tamanhos em bytes decimais (5,2 GB = 5,2 × 10⁹).
    public static let gb: Int64 = 1_000_000_000
    public static let tetoPadrao: Int64 = 6 * gb
    /// Contexto de 8k + o que o sistema e os apps abertos precisam além do modelo.
    public static let folga: Int64 = 2 * gb
    public static let numCtx = 8_192

    public struct ModeloBaixado: Equatable, Sendable {
        public var nome: String
        public var tamanho: Int64
        public init(nome: String, tamanho: Int64) {
            self.nome = nome
            self.tamanho = tamanho
        }
    }

    /// `GET /api/tags` → nome e tamanho de cada modelo. Corpo ilegível = nil.
    public static func lerTags(_ dados: Data) -> [ModeloBaixado]? {
        guard let obj = JV.objeto(dados) else { return nil }
        let lista = (obj["models"] as? [[String: Any]]) ?? []
        return lista.compactMap { item in
            guard let nome = JV.texto(item["name"]), let t = JV.numero(item["size"]) else { return nil }
            return ModeloBaixado(nome: nome, tamanho: Int64(t))
        }
    }

    /// `GET /api/ps` → modelos carregados agora (por qualquer um: Hermes, vigia, wizard).
    /// Usa `size` (memória ocupada). Corpo ilegível = nil.
    public static func lerCarregados(_ dados: Data) -> [ModeloBaixado]? {
        guard let obj = JV.objeto(dados) else { return nil }
        let lista = (obj["models"] as? [[String: Any]]) ?? []
        return lista.compactMap { item in
            guard let nome = JV.texto(item["name"]) ?? JV.texto(item["model"]) else { return nil }
            return ModeloBaixado(nome: nome, tamanho: Int64(JV.numero(item["size"]) ?? 0))
        }
    }

    /// Modelo de embedding não escreve texto: nunca entra no rascunho.
    static func geraTexto(_ nome: String) -> Bool {
        !nome.lowercased().contains("embed")
    }

    public enum Escolha: Equatable, Sendable {
        case usar(String)
        /// O motivo vai para a tela, como está.
        case nenhum(String)
    }

    static func emGB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / Double(gb)).replacingOccurrences(of: ".", with: ",")
    }

    /// Qual modelo usar agora, ou por que nenhum.
    ///
    /// - `escolhido` vazio: o sugerido, se baixado e dentro do teto; senão o maior que cabe
    ///   (o maior escreve melhor, e o teto já garante a folga de memória).
    /// - `disponivel` nil = não deu para medir a memória: decide só pelo teto.
    /// - `carregados`: o que já ocupa memória no Ollama. Modelo do wizard que já está
    ///   carregado não custa memória nova; os outros só entram na mensagem. O wizard
    ///   nunca descarrega modelo de outro (ex.: o `gemma4` do Hermes).
    public static func escolher(baixados: [ModeloBaixado], escolhido: String,
                                teto: Int64 = tetoPadrao, disponivel: Int64?,
                                carregados: [ModeloBaixado] = []) -> Escolha {
        let textuais = baixados.filter { geraTexto($0.nome) && $0.tamanho > 0 }
        let e = escolhido.trimmingCharacters(in: .whitespacesAndNewlines)
        let alvo: ModeloBaixado
        if !e.isEmpty {
            guard let m = textuais.first(where: { OllamaLocal.mesmoModelo($0.nome, e) }) else {
                return .nenhum(String(localized: "O modelo \(e) não está baixado."))
            }
            guard m.tamanho <= teto else {
                return .nenhum(String(localized: "O modelo \(m.nome) tem \(emGB(m.tamanho)) GB, acima do teto de \(emGB(teto)) GB."))
            }
            alvo = m
        } else {
            let cabem = textuais.filter { $0.tamanho <= teto }
            if let s = cabem.first(where: { OllamaLocal.mesmoModelo($0.nome, modeloSugerido) }) {
                alvo = s
            } else if let maior = cabem.max(by: { ($0.tamanho, $1.nome) < ($1.tamanho, $0.nome) }) {
                alvo = maior
            } else {
                return .nenhum(String(localized: "Nenhum modelo baixado cabe no teto de \(emGB(teto)) GB. Baixe o \(modeloSugerido)."))
            }
        }
        let jaCarregado = carregados.contains { OllamaLocal.mesmoModelo($0.nome, alvo.nome) }
        if let disponivel, !jaCarregado, alvo.tamanho + folga > disponivel {
            let outros = carregados.map(\.nome)
            let quem = outros.isEmpty ? "" : String(localized: " Carregado no Ollama agora: \(outros.joined(separator: ", ")) (o wizard não descarrega modelo de outro uso, como o Hermes).")
            return .nenhum(String(localized: "Memória livre insuficiente: o \(alvo.nome) precisa de \(emGB(alvo.tamanho + folga)) GB e há \(emGB(disponivel)) GB.\(quem) Feche alguns apps ou espere e tente de novo."))
        }
        return .usar(alvo.nome)
    }

    /// Teto lido da config (GB, aceita fração). Inválido ou ausente = padrão.
    public static func teto(config: [String: Any]) -> Int64 {
        guard let v = Configuracao.valor(chaveTetoGB, em: config), let n = JV.numero(v), n > 0, n <= 64 else {
            return tetoPadrao
        }
        return Int64(n * Double(gb))
    }

    // MARK: - Memória

    /// Memória que o macOS consegue entregar sem swap: livre + inativa + especulativa + purgável.
    public static func memoriaDisponivel(livres: UInt64, inativas: UInt64, especulativas: UInt64,
                                         purgaveis: UInt64, tamanhoPagina: UInt64) -> Int64 {
        Int64((livres + inativas + especulativas + purgaveis) * tamanhoPagina)
    }

    /// Medida agora (`host_statistics64`). nil se o sistema não responder.
    public static func memoriaDisponivelAgora() -> Int64? {
        #if canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        var pagina: vm_size_t = 0
        host_page_size(mach_host_self(), &pagina)
        return memoriaDisponivel(livres: UInt64(stats.free_count), inativas: UInt64(stats.inactive_count),
                                 especulativas: UInt64(stats.speculative_count),
                                 purgaveis: UInt64(stats.purgeable_count), tamanhoPagina: UInt64(pagina))
        #else
        return nil
        #endif
    }

    // MARK: - Geração

    /// Corpo do `POST /api/generate`: sem stream, contexto fixo, sem raciocínio exposto.
    /// `descarregar`: o modelo sai da memória logo depois. Só vale quando foi o wizard que o
    /// carregou; se outro uso (Hermes, vigia) já o tinha na memória, fica como estava.
    public static func corpoGerar(modelo: String, sistema: String, prompt: String,
                                  descarregar: Bool) throws -> Data {
        var corpo: [String: Any] = [
            "model": modelo,
            "system": sistema,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "options": ["num_ctx": numCtx, "temperature": 0.3],
        ]
        if descarregar { corpo["keep_alive"] = 0 }
        return try JSONSerialization.data(withJSONObject: corpo, options: [.sortedKeys])
    }

    /// Tira o bloco `<think>…</think>` que alguns modelos devolvem mesmo com `think: false`.
    public static func semPensamento(_ texto: String) -> String {
        var t = texto
        while let a = t.range(of: "<think>"), let b = t.range(of: "</think>", range: a.upperBound..<t.endIndex) {
            t.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resposta do `/api/generate`. Erro do servidor vira throw; corpo ilegível = nil.
    public static func lerResposta(_ dados: Data) throws -> String? {
        guard let obj = JV.objeto(dados) else { return nil }
        if let e = JV.texto(obj["error"]) { throw OllamaLocal.ErroOllama.servidor(e) }
        guard let r = JV.texto(obj["response"]) else { return nil }
        return semPensamento(r)
    }

    /// Modelos carregados agora; nil = servidor fora do ar.
    public static func carregados(timeout: TimeInterval = 3) async -> [ModeloBaixado]? {
        await consultar("api/ps", timeout: timeout).flatMap(lerCarregados)
    }

    /// Modelos baixados com tamanho; nil = servidor fora do ar.
    public static func baixados(timeout: TimeInterval = 3) async -> [ModeloBaixado]? {
        await consultar("api/tags", timeout: timeout).flatMap(lerTags)
    }

    static func consultar(_ caminho: String, timeout: TimeInterval) async -> Data? {
        var req = URLRequest(url: OllamaLocal.base.appendingPathComponent(caminho), timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (dados, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return dados
    }

    /// Uma chamada ao Ollama local. Quem chama confere `escolher` antes.
    /// Descarrega o modelo no fim só se ele não estava carregado antes da chamada.
    public static func gerar(modelo: String, sistema: String, prompt: String,
                             timeout: TimeInterval = 600) async throws -> String {
        let antes = await carregados() ?? []
        let descarregar = !antes.contains { OllamaLocal.mesmoModelo($0.nome, modelo) }
        var req = URLRequest(url: OllamaLocal.base.appendingPathComponent("api/generate"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try corpoGerar(modelo: modelo, sistema: sistema, prompt: prompt, descarregar: descarregar)
        let (dados, resp) = try await URLSession.shared.data(for: req)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let texto = try lerResposta(dados), codigo == 200 { return texto }
        throw OllamaLocal.ErroOllama.servidor("HTTP \(codigo)")
    }
}
