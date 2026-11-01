import XCTest
@testable import GastoCore

final class IntegridadeControleTests: XCTestCase {
    let home = "/Users/teste"
    let controle = "/Applications/TuttiDash.app/Contents/Resources/controle"

    func ancora(_ texto: String, uid: uid_t = 0, caminho: String? = nil, regular: Bool = true,
                gravavel: Bool = false, diretorio: Bool = true) -> AncoraLida {
        AncoraLida(caminho: caminho ?? IntegridadeControle.caminhoAncora, texto: texto, uid: uid,
                   regular: regular, gravavelPeloGrupo: gravavel, diretorioConfiavel: diretorio)
    }

    func avaliar(_ arquivos: [String: Data], texto: String? = nil, assinatura: Bool = true,
                 caminho: String? = nil, uid: uid_t = 0, gravavel: Bool = false,
                 diretorio: Bool = true, regular: Bool = true) -> VereditoIntegridade {
        let manifesto = texto ?? IntegridadeControle.textoManifesto(arquivos.filter { !$0.key.contains("__pycache__") && !$0.key.hasSuffix(".pyc") })
        return IntegridadeControle.avaliar(
            ancora: ancora(manifesto, uid: uid, caminho: caminho, regular: regular, gravavel: gravavel, diretorio: diretorio),
            arquivos: arquivos, home: home, controle: controle, assinaturaAceita: assinatura)
    }

    func testHashQueConferePassa() {
        let arquivos = ["lanes/dispatcher.py": Data("bundle".utf8), "gasto_lanes/catalogo.py": Data("mod".utf8)]
        let v = avaliar(arquivos)
        XCTAssertTrue(v.confere)
        XCTAssertNil(v.aviso)
    }

    func testTrocarModuloDoBundleEDetectado() {
        let original = ["lanes/dispatcher.py": Data("bundle".utf8), "gasto_lanes/catalogo.py": Data("mod".utf8)]
        let manifesto = IntegridadeControle.textoManifesto(original)
        var trocado = original
        trocado["gasto_lanes/catalogo.py"] = Data("trocado".utf8)
        let v = IntegridadeControle.avaliar(
            ancora: ancora(manifesto), arquivos: trocado, home: home, controle: controle, assinaturaAceita: true)
        XCTAssertFalse(v.confere)
        XCTAssertEqual(v.aviso, "integridade: divergencia: hash gasto_lanes/catalogo.py")
    }

    func testCopiaEmTranscentiaNaoEAncora() {
        let arquivos = ["bots/watch.py": Data("vigia".utf8)]
        let v = avaliar(arquivos, caminho: home + "/.transcentia/controle.sha256")
        XCTAssertFalse(v.confere)
        XCTAssertEqual(v.aviso, "integridade: divergencia: alcance")
    }

    func testManifestoDentroDoBundleNaoEAncora() {
        let arquivos = ["bots/watch.py": Data("vigia".utf8)]
        let v = avaliar(arquivos, caminho: controle + "/controle.sha256")
        XCTAssertFalse(v.confere)
        XCTAssertEqual(v.aviso, "integridade: divergencia: alcance")
    }

    func testDonoQueNaoERootNaoVale() {
        let arquivos = ["tools/bots-chave": Data("chave".utf8)]
        let v = avaliar(arquivos, uid: 501)
        XCTAssertFalse(v.confere)
        XCTAssertTrue(v.aviso?.contains("integridade: divergencia: ancora") == true)
        XCTAssertTrue(v.aviso?.contains(IntegridadeControle.caminhoAncora) == true)
    }

    func testAssinaturaAdHocNaoPassa() {
        let arquivos = ["tools/bots-chave": Data("chave".utf8)]
        let v = avaliar(arquivos, assinatura: false)
        XCTAssertFalse(v.confere)
        XCTAssertEqual(v.aviso, "integridade: divergencia: assinatura \(IntegridadeControle.equipe)")
        XCTAssertFalse(IntegridadeControle.requisito.lowercased().contains("cdhash"))
        XCTAssertTrue(IntegridadeControle.requisito.contains("anchor apple generic"))
        XCTAssertTrue(IntegridadeControle.requisito.contains("certificate leaf[subject.OU]"))
    }

    func testPycacheNaoContaEArquivoExtraConta() {
        var arquivos = ["lanes/dispatcher.py": Data("bundle".utf8)]
        let manifesto = IntegridadeControle.textoManifesto(arquivos)
        arquivos["gasto_lanes/__pycache__/catalogo.pyc"] = Data("pyc".utf8)
        let ok = IntegridadeControle.avaliar(
            ancora: ancora(manifesto), arquivos: arquivos, home: home, controle: controle, assinaturaAceita: true)
        XCTAssertTrue(ok.confere)
        arquivos["gasto_lanes/evil.py"] = Data("evil".utf8)
        let ruim = IntegridadeControle.avaliar(
            ancora: ancora(manifesto), arquivos: arquivos, home: home, controle: controle, assinaturaAceita: true)
        XCTAssertFalse(ruim.confere)
        XCTAssertEqual(ruim.aviso, "integridade: divergencia: hash gasto_lanes/evil.py")
    }

    func testArquivoSemAssinaturaNaoPassaNoCodesign() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fra616-sem-assinatura-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(IntegridadeControle.assinaturaAceita(alvo: url))
    }

    func testCaminhoDeSistemaFicaForaDoAgente() {
        XCTAssertTrue(IntegridadeControle.caminhoForaDoAgente(
            IntegridadeControle.caminhoAncora, home: home, controle: controle))
        XCTAssertFalse(IntegridadeControle.caminhoAncora.contains(".transcentia"))
        XCTAssertFalse(IntegridadeControle.caminhoAncora.contains("/Contents/"))
    }
}
