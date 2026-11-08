import XCTest
@testable import GastoCore

final class OllamaWizardTests: XCTestCase {
    private let gb = OllamaWizard.gb
    private var baixados: [OllamaWizard.ModeloBaixado] {
        [.init(nome: "gemma4:12b", tamanho: 7_700_000_000),
         .init(nome: "phi3:mini", tamanho: 2_200_000_000),
         .init(nome: "nomic-embed-text:latest", tamanho: 274_000_000),
         .init(nome: "qwen3:8b", tamanho: 5_200_000_000)]
    }

    func testLerTagsECarregados() throws {
        let tags = Data(#"{"models":[{"name":"qwen3:8b","size":5200000000},{"name":"sem-tamanho"}]}"#.utf8)
        XCTAssertEqual(OllamaWizard.lerTags(tags), [.init(nome: "qwen3:8b", tamanho: 5_200_000_000)])
        let ps = Data(#"{"models":[{"name":"gemma4:12b","model":"gemma4:12b","size":9100000000}]}"#.utf8)
        XCTAssertEqual(OllamaWizard.lerCarregados(ps), [.init(nome: "gemma4:12b", tamanho: 9_100_000_000)])
        XCTAssertNil(OllamaWizard.lerTags(Data("x".utf8)))
    }

    func testSemEscolhaUsaOSugeridoQuandoBaixado() {
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: 12 * gb), .usar("qwen3:8b"))
    }

    func testSemSugeridoUsaOMaiorQueCabeENuncaEmbedding() {
        let sem = baixados.filter { $0.nome != "qwen3:8b" }
        XCTAssertEqual(OllamaWizard.escolher(baixados: sem, escolhido: "", disponivel: 12 * gb), .usar("phi3:mini"))
        let soEmbedding = [OllamaWizard.ModeloBaixado(nome: "nomic-embed-text:latest", tamanho: 274_000_000)]
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: soEmbedding, escolhido: "", disponivel: nil) else {
            return XCTFail("embedding não escreve texto")
        }
        XCTAssertTrue(motivo.contains("qwen3:8b"))
    }

    func testModeloAcimaDoTetoNaoEntraMesmoEscolhido() {
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: baixados, escolhido: "gemma4:12b",
                                                               disponivel: 15 * gb) else {
            return XCTFail("12b passa do teto de 6 GB")
        }
        XCTAssertTrue(motivo.contains("7,7 GB"))
        XCTAssertTrue(motivo.contains("6,0 GB"))
    }

    func testEscolhidoNaoBaixado() {
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "llama9:1b", disponivel: nil),
                       .nenhum("O modelo llama9:1b não está baixado."))
    }

    func testMemoriaInsuficienteCitaQuemEstaCarregadoENaoDescarrega() {
        let hermes = [OllamaWizard.ModeloBaixado(nome: "gemma4:12b", tamanho: 9_100_000_000)]
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: baixados, escolhido: "",
                                                               disponivel: 6 * gb, carregados: hermes) else {
            return XCTFail("5,2 + 2 GB não cabem em 6 GB")
        }
        XCTAssertTrue(motivo.contains("7,2 GB"))
        XCTAssertTrue(motivo.contains("gemma4:12b"))
        XCTAssertTrue(motivo.contains("Hermes"))
    }

    func testModeloJaCarregadoNaoPedeMemoriaNova() {
        let ja = [OllamaWizard.ModeloBaixado(nome: "qwen3:8b", tamanho: 6_000_000_000)]
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "qwen3:8b", disponivel: 1 * gb,
                                             carregados: ja), .usar("qwen3:8b"))
    }

    func testTetoDaConfig() {
        XCTAssertEqual(OllamaWizard.teto(config: [:]), OllamaWizard.tetoPadrao)
        XCTAssertEqual(OllamaWizard.teto(config: ["wizard": ["teto_ollama_gb": 4.5]]), 4_500_000_000)
        XCTAssertEqual(OllamaWizard.teto(config: ["wizard": ["teto_ollama_gb": -1]]), OllamaWizard.tetoPadrao)
        XCTAssertEqual(OllamaWizard.teto(config: ["wizard": ["teto_ollama_gb": "x"]]), OllamaWizard.tetoPadrao)
    }

    func testMemoriaDisponivelSomaAsPaginasLiberaveis() {
        XCTAssertEqual(OllamaWizard.memoriaDisponivel(livres: 1, inativas: 2, especulativas: 3, purgaveis: 4,
                                                      tamanhoPagina: 16_384), 10 * 16_384)
        XCTAssertNotNil(OllamaWizard.memoriaDisponivelAgora())
    }

    func testCorpoGerarSoDescarregaQuandoOWizardCarregou() throws {
        let com = try XCTUnwrap(JV.objeto(OllamaWizard.corpoGerar(modelo: "qwen3:8b", sistema: "s", prompt: "p",
                                                                    descarregar: true)))
        XCTAssertEqual(JV.numero(com["keep_alive"]), 0)
        XCTAssertEqual(com["stream"] as? Bool, false)
        XCTAssertEqual(com["think"] as? Bool, false)
        XCTAssertEqual(JV.numero((com["options"] as? [String: Any])?["num_ctx"]), 8_192)
        XCTAssertEqual(com["system"] as? String, "s")
        let sem = try XCTUnwrap(JV.objeto(OllamaWizard.corpoGerar(modelo: "gemma4:12b", sistema: "s", prompt: "p",
                                                                    descarregar: false)))
        XCTAssertNil(sem["keep_alive"], "não derruba o modelo que outro uso (Hermes) já tinha carregado")
    }

    func testRespostaSemPensamentoEErroDoServidor() throws {
        let r = Data(#"{"response":"<think>rascunho interno</think>\nNORTE:\n## 1. Objetivo\nx","done":true}"#.utf8)
        XCTAssertEqual(try OllamaWizard.lerResposta(r), "NORTE:\n## 1. Objetivo\nx")
        XCTAssertThrowsError(try OllamaWizard.lerResposta(Data(#"{"error":"model not found"}"#.utf8)))
        XCTAssertNil(try OllamaWizard.lerResposta(Data("x".utf8)))
    }
}
