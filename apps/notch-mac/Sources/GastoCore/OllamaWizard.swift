import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Ollama no wizard de projeto: rascunho do norte quando nenhum CLI tem conta.
///
/// Não há teto por nome nem por tamanho: quem decide é a memória livre do Mac naquele
/// momento. O teste de 08/11 (`qwen2.5-coder:14b` com 32k de contexto, 15,8 GB) travou
/// um Mac de 16 GB; aqui o contexto novo é de 8k e o modelo que o wizard carregou sai da
/// memória assim que responde. Modelo que outro app já tem carregado (ex.: um agente
/// local) é reaproveitado no mesmo contexto e nunca é descarregado pelo wizard.
public enum OllamaWizard {
    /// Modelo escolhido nos Ajustes. Separado do modelo da triagem do vigia.
    public static let chaveModelo = "wizard.modelo_ollama"
    /// Modelo que o «Baixar» do wizard oferece: instrução geral de 8B, 5,2 GB em Q4.
    public static let modeloSugerido = "qwen3:8b"
    /// O Ollama informa tamanhos em bytes decimais (5,2 GB = 5,2 × 10⁹).
    public static let gb: Int64 = 1_000_000_000
    /// Contexto de 8k + o que o sistema e os apps abertos precisam além do modelo.
    public static let folga: Int64 = 2 * gb
    /// Contexto quando o wizard carrega o modelo. A leitura do repo + o prompt cabem em ≈5k tokens.
    public static let numCtx = 8_192

    public struct ModeloBaixado: Equatable, Sendable {
        public var nome: String
        public var tamanho: Int64
        /// Só em `/api/ps`: o contexto com que o modelo está carregado. nil = o servidor não disse.
        public var contexto: Int?
        public init(nome: String, tamanho: Int64, contexto: Int? = nil) {
            self.nome = nome
            self.tamanho = tamanho
            self.contexto = contexto
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

    /// `GET /api/ps` → modelos carregados agora (por qualquer um: outro app, vigia, wizard),
    /// com a memória ocupada (`size`) e o contexto (`context_length`). Corpo ilegível = nil.
    public static func lerCarregados(_ dados: Data) -> [ModeloBaixado]? {
        guard let obj = JV.objeto(dados) else { return nil }
        let lista = (obj["models"] as? [[String: Any]]) ?? []
        return lista.compactMap { item in
            guard let nome = JV.texto(item["name"]) ?? JV.texto(item["model"]) else { return nil }
            return ModeloBaixado(nome: nome, tamanho: Int64(JV.numero(item["size"]) ?? 0),
                                 contexto: JV.numero(item["context_length"]).map { Int($0) })
        }
    }

    /// Modelo de embedding não escreve texto: nunca entra no rascunho.
    static func geraTexto(_ nome: String) -> Bool {
        !nome.lowercased().contains("embed")
    }

    /// Carregado com contexto suficiente para o prompt do norte: dá para usar sem recarregar.
    /// Contexto desconhecido conta como suficiente; a chamada então não manda `num_ctx`,
    /// para o Ollama não recarregar o modelo de outro uso.
    static func reaproveitavel(_ m: ModeloBaixado) -> Bool {
        geraTexto(m.nome) && (m.contexto ?? numCtx) >= numCtx
    }

    public enum Escolha: Equatable, Sendable {
        case usar(String)
        /// O motivo vai para a tela, como está.
        case nenhum(String)
    }

    static func emGB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / Double(gb)).replacingOccurrences(of: ".", with: ",")
    }

    /// Qual modelo usar agora, ou por que nenhum. Quem limita é a memória, não o tamanho.
    ///
    /// Sem `escolhido`, nesta ordem:
    /// 1. um modelo que já está carregado (ex.: por um agente local) — não custa memória nova;
    /// 2. o sugerido, se baixado e couber na memória;
    /// 3. o maior baixado que couber na memória (o maior escreve melhor).
    ///
    /// `disponivel` nil (não deu para medir): só o que já está carregado. Carregar modelo
    /// novo sem saber a memória é o que travou o Mac em 08/11.
    public static func escolher(baixados: [ModeloBaixado], escolhido: String, disponivel: Int64?,
                                carregados: [ModeloBaixado] = []) -> Escolha {
        let textuais = baixados.filter { geraTexto($0.nome) && $0.tamanho > 0 }
        func carregado(_ nome: String) -> ModeloBaixado? {
            carregados.first { OllamaLocal.mesmoModelo($0.nome, nome) }
        }
        func cabe(_ m: ModeloBaixado) -> Bool {
            guard let disponivel else { return false }
            return m.tamanho + folga <= disponivel
        }
        func semMemoria(_ m: ModeloBaixado) -> Escolha {
            guard let disponivel else {
                return .nenhum(String(localized: "Não deu para medir a memória livre; o wizard não carrega o \(m.nome) às cegas."))
            }
            let outros = carregados.map(\.nome)
            let quem = outros.isEmpty ? "" : String(localized: " Carregado no Ollama agora: \(outros.joined(separator: ", ")) (o wizard não descarrega modelo de outro uso).")
            return .nenhum(String(localized: "Memória livre insuficiente: o \(m.nome) precisa de \(emGB(m.tamanho + folga)) GB e há \(emGB(disponivel)) GB.\(quem) Feche alguns apps ou espere e tente de novo."))
        }

        let e = escolhido.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty {
            guard let m = textuais.first(where: { OllamaLocal.mesmoModelo($0.nome, e) }) else {
                return .nenhum(String(localized: "O modelo \(e) não está baixado."))
            }
            if let c = carregado(m.nome) {
                // Número sem separador de milhar: o texto localizado faria «4.096».
                let tem = String(c.contexto ?? 0), precisa = String(numCtx)
                return reaproveitavel(c) ? .usar(m.nome)
                    : .nenhum(String(localized: "O \(m.nome) está carregado com contexto de \(tem); o norte precisa de \(precisa). O wizard não recarrega modelo de outro uso."))
            }
            return cabe(m) ? .usar(m.nome) : semMemoria(m)
        }

        if let ja = carregados.first(where: { c in reaproveitavel(c) && textuais.contains { OllamaLocal.mesmoModelo($0.nome, c.nome) } }) {
            return .usar(ja.nome)
        }
        // Daqui em diante, só modelo que não está carregado (carregado com contexto curto não serve).
        let livres = textuais.filter { carregado($0.nome) == nil }
        if let s = livres.first(where: { OllamaLocal.mesmoModelo($0.nome, modeloSugerido) }), cabe(s) {
            return .usar(s.nome)
        }
        if let maior = livres.filter(cabe).max(by: { ($0.tamanho, $1.nome) < ($1.tamanho, $0.nome) }) {
            return .usar(maior.nome)
        }
        guard let menor = livres.min(by: { $0.tamanho < $1.tamanho }) else {
            return .nenhum(String(localized: "Nenhum modelo de texto baixado. Baixe o \(modeloSugerido)."))
        }
        return semMemoria(menor)
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
    /// carregou; se outro uso (outro app, vigia) já o tinha na memória, fica como estava.
    /// `contexto`: o `num_ctx` do pedido. nil = não manda (modelo de outro uso, contexto
    /// desconhecido): um `num_ctx` diferente do carregado faz o Ollama recarregar o modelo.
    public static func corpoGerar(modelo: String, sistema: String, prompt: String,
                                  descarregar: Bool, contexto: Int? = numCtx) throws -> Data {
        var opcoes: [String: Any] = ["temperature": 0.3]
        if let contexto { opcoes["num_ctx"] = contexto }
        var corpo: [String: Any] = [
            "model": modelo,
            "system": sistema,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "options": opcoes,
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
        // Já carregado por outro uso: mesmo contexto e fica na memória. Senão: 8k e sai no fim.
        let ja = (await carregados() ?? []).first { OllamaLocal.mesmoModelo($0.nome, modelo) }
        let descarregar = ja == nil
        let contexto: Int? = ja.map { $0.contexto } ?? numCtx
        var req = URLRequest(url: OllamaLocal.base.appendingPathComponent("api/generate"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try corpoGerar(modelo: modelo, sistema: sistema, prompt: prompt,
                                     descarregar: descarregar, contexto: contexto)
        let (dados, resp) = try await URLSession.shared.data(for: req)
        let codigo = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let texto = try lerResposta(dados), codigo == 200 { return texto }
        throw OllamaLocal.ErroOllama.servidor("HTTP \(codigo)")
    }
}
