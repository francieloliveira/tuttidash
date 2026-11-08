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
        let ps = Data(#"{"models":[{"name":"gemma4:12b","model":"gemma4:12b","size":9100000000,"context_length":32768}]}"#.utf8)
        XCTAssertEqual(OllamaWizard.lerCarregados(ps), [.init(nome: "gemma4:12b", tamanho: 9_100_000_000, contexto: 32_768)])
        XCTAssertNil(OllamaWizard.lerTags(Data("x".utf8)))
    }

    func testSemEscolhaUsaOSugeridoQuandoCabe() {
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: 12 * gb), .usar("qwen3:8b"))
    }

    func testSemTetoOGemmaEntraQuandoAMemoriaDeixa() {
        let sem = baixados.filter { $0.nome != "qwen3:8b" }
        XCTAssertEqual(OllamaWizard.escolher(baixados: sem, escolhido: "", disponivel: 12 * gb), .usar("gemma4:12b"))
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "gemma4:12b", disponivel: 12 * gb),
                       .usar("gemma4:12b"))
        // Sem memória para o maior, cai no que cabe.
        XCTAssertEqual(OllamaWizard.escolher(baixados: sem, escolhido: "", disponivel: 5 * gb), .usar("phi3:mini"))
    }

    func testReaproveitaModeloDeOutroAppCarregadoSemMemoriaNova() {
        let hermes = [OllamaWizard.ModeloBaixado(nome: "gemma4:12b", tamanho: 9_100_000_000, contexto: 32_768)]
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: 1 * gb, carregados: hermes),
                       .usar("gemma4:12b"))
        let semContexto = [OllamaWizard.ModeloBaixado(nome: "gemma4:12b", tamanho: 9_100_000_000)]
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: 1 * gb, carregados: semContexto),
                       .usar("gemma4:12b"))
    }

    func testCarregadoComContextoCurtoNaoERecarregado() {
        let curto = [OllamaWizard.ModeloBaixado(nome: "gemma4:12b", tamanho: 8_000_000_000, contexto: 4_096)]
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: 8 * gb, carregados: curto),
                       .usar("qwen3:8b"), "não recarrega o modelo de outro app; usa outro que caiba")
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: baixados, escolhido: "gemma4:12b",
                                                               disponivel: 15 * gb, carregados: curto) else {
            return XCTFail("escolhido com contexto curto não pode ser recarregado")
        }
        XCTAssertTrue(motivo.contains("4096"))
    }

    func testSoEmbeddingNaoServe() {
        let soEmbedding = [OllamaWizard.ModeloBaixado(nome: "nomic-embed-text:latest", tamanho: 274_000_000)]
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: soEmbedding, escolhido: "", disponivel: 12 * gb) else {
            return XCTFail("embedding não escreve texto")
        }
        XCTAssertTrue(motivo.contains("qwen3:8b"))
    }

    func testEscolhidoNaoBaixado() {
        XCTAssertEqual(OllamaWizard.escolher(baixados: baixados, escolhido: "llama9:1b", disponivel: nil),
                       .nenhum("O modelo llama9:1b não está baixado."))
    }

    func testMemoriaInsuficienteCitaQuemEstaCarregado() {
        let outro = [OllamaWizard.ModeloBaixado(nome: "gemma4:12b", tamanho: 9_100_000_000, contexto: 2_048)]
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: baixados, escolhido: "",
                                                               disponivel: 1 * gb, carregados: outro) else {
            return XCTFail("nada cabe em 1 GB e o gemma carregado tem contexto curto")
        }
        XCTAssertTrue(motivo.contains("gemma4:12b"))
        XCTAssertTrue(motivo.contains("não descarrega modelo de outro uso"))
    }

    func testSemMedirMemoriaNaoCarregaNadaNovo() {
        guard case .nenhum(let motivo) = OllamaWizard.escolher(baixados: baixados, escolhido: "", disponivel: nil) else {
            return XCTFail("sem medida de memória não carrega modelo às cegas")
        }
        XCTAssertTrue(motivo.contains("às cegas"))
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
        XCTAssertNil(sem["keep_alive"], "não derruba o modelo que outro uso já tinha carregado")
        let semCtx = try XCTUnwrap(JV.objeto(OllamaWizard.corpoGerar(modelo: "gemma4:12b", sistema: "s", prompt: "p",
                                                                       descarregar: false, contexto: nil)))
        XCTAssertNil((semCtx["options"] as? [String: Any])?["num_ctx"], "contexto desconhecido: não força recarga")
    }

    func testRespostaSemPensamentoEErroDoServidor() throws {
        let r = Data(#"{"response":"<think>rascunho interno</think>\nNORTE:\n## 1. Objetivo\nx","done":true}"#.utf8)
        XCTAssertEqual(try OllamaWizard.lerResposta(r), "NORTE:\n## 1. Objetivo\nx")
        XCTAssertThrowsError(try OllamaWizard.lerResposta(Data(#"{"error":"model not found"}"#.utf8)))
        XCTAssertNil(try OllamaWizard.lerResposta(Data("x".utf8)))
    }
}
