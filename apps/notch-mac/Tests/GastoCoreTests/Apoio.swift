import Foundation
import XCTest
@testable import GastoCore

/// Fixtures da raiz do repo (`tests/fixtures`). São dado, não código: o Swift e o
/// Python leem os mesmos arquivos, então não existe cópia para divergir.
enum Fixtures {
    static var raizRepo: URL {
        // .../apps/notch-mac/Tests/GastoCoreTests/Apoio.swift -> raiz do repo
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var logs: URL { raizRepo.appendingPathComponent("tests/fixtures/logs") }
    static var estado: URL { raizRepo.appendingPathComponent("tests/fixtures/estado") }

    /// Respostas cruas dos endpoints de uso, como o servidor manda. Geradas por
    /// `tests/fixtures/gerar_uso.py`; os resets são fixos para o teste ser determinístico.
    enum Uso {
        static var pasta: URL { raizRepo.appendingPathComponent("tests/fixtures/uso") }

        /// Corpo bruto do endpoint, ou uma mensagem de falha explícita se faltar —
        /// melhor falhar no teste do que testar com `""` e dar verde à toa.
        static func corpo(_ arquivo: String, file: StaticString = #filePath,
                           line: UInt = #line) -> String {
            let caminho = pasta.appendingPathComponent(arquivo)
            guard let texto = try? String(contentsOf: caminho, encoding: .utf8) else {
                XCTFail("fixture de uso ausente: \(caminho.path) "
                        + "(gere com python3 tests/fixtures/gerar_uso.py)", file: file, line: line)
                return ""
            }
            return texto
        }
    }
}

/// Pasta temporária própria do teste (nada fora dela é tocado).
final class PastaTemp {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-gasto-testes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func escrever(_ caminho: String, _ texto: String) throws -> URL {
        let u = url.appendingPathComponent(caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}

func calendarioFixo() -> Calendar {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    return c
}

func data(_ s: String) -> Date {
    Datas.lerLocal(s, calendario: calendarioFixo())!
}

func ex(_ id: String, custo: Double?, status: StatusExecucao = .ok, tipo: TipoCusto? = nil,
        duracaoMs: Int? = 60_000, estimadaMs: Int? = nil, respostas: Int? = nil) -> Execucao {
    let meta = ParserLog.lerNome(id + ".jsonl", calendario: calendarioFixo())!
    let t: TipoCusto = tipo ?? (custo == nil ? .desconhecido
        : (Agentes.custoEstimado.contains(meta.lane) ? .estimado : .informado))
    return Execucao(id: meta.id, card: meta.card, lane: meta.lane, inicio: meta.inicio, dia: meta.dia,
                    semana: meta.semana, status: status, custoUSD: custo, custo: t, duracaoMs: duracaoMs,
                    duracaoEstimadaMs: estimadaMs, respostasParciais: respostas)
}
