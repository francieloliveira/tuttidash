import XCTest
@testable import GastoCore

/// Medição real do rascunho do norte via Ollama (PRD: "medição no Mac de 16 GB").
/// Só roda com `NORTE_MEDIR=1`; no CI e no `swift test` comum fica pulado.
/// `NORTE_REPO` = repositório lido (padrão: o próprio TuttiDash); resultado em `NORTE_SAIDA`.
final class MedicaoNorteOllamaTests: XCTestCase {
    func testMedirRascunhoReal() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NORTE_MEDIR"] == "1", "medição real só com NORTE_MEDIR=1")
        let repo = URL(fileURLWithPath: ((env["NORTE_REPO"] ?? "~/Developer/tuttidash") as NSString).expandingTildeInPath)
        let saida = env["NORTE_SAIDA"] ?? "/tmp/norte-medicao.txt"

        let lista = await OllamaWizard.baixados()
        let baixados = try XCTUnwrap(lista, "Ollama fora do ar")
        let carregados = await OllamaWizard.carregados() ?? []
        let livreAntes = OllamaWizard.memoriaDisponivelAgora()
        let escolha = OllamaWizard.escolher(baixados: baixados, escolhido: env["NORTE_MODELO"] ?? "",
                                            disponivel: livreAntes, carregados: carregados)
        guard case .usar(let modelo) = escolha else {
            try "RECUSADO: \(escolha)\n".write(toFile: saida, atomically: true, encoding: .utf8)
            throw XCTSkip("regra recusou: \(escolha)")
        }
        let leitura = NorteRascunho.lerRepositorio(repo)
        let prompt = NorteRascunho.prompt(nome: repo.lastPathComponent, leitura: leitura, respostas: "")
        let inicio = Date()
        let bruto = try await OllamaWizard.gerar(modelo: modelo, sistema: NorteRascunho.sistema, prompt: prompt)
        let segundos = Date().timeIntervalSince(inicio)
        let depois = await OllamaWizard.carregados() ?? []
        let rascunho = NorteRascunho.ler(bruto)
        let relatorio = """
        modelo: \(modelo)
        carregados antes: \(carregados.map(\.nome))
        carregados depois: \(depois.map(\.nome))
        memoria disponivel antes (GB): \(Double(livreAntes ?? 0) / 1e9)
        leitura (caracteres): \(leitura.count)
        segundos: \(Int(segundos))
        secoes reconhecidas: \(rascunho != nil)
        pendentes: \(rascunho?.pendentes ?? [])
        perguntas: \(rascunho?.perguntas ?? [])

        ----- resposta bruta -----
        \(bruto)
        """
        try relatorio.write(toFile: saida, atomically: true, encoding: .utf8)
        XCTAssertNotNil(rascunho, "o leitor não reconheceu a resposta")
    }
}
