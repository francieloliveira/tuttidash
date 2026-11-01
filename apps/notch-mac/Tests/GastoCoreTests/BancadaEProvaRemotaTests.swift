import XCTest
@testable import GastoCore

/// FRA-618/620: o cadastro guarda a bancada e as pastas do app, e o app confere a prova remota.
final class BancadaEProvaRemotaTests: XCTestCase {
    private func dados(_ extra: [String: Any]) -> [String: Any] {
        var item: [String: Any] = ["id": "5f8bff08-72d9-4293-b1ab-17cef0af2c29", "nome": "App", "repo": "/tmp/app"]
        item.merge(extra) { _, novo in novo }
        return ["projetos": [item]]
    }

    func testLeEGravaBancadaEPastasDoApp() {
        let lidos = ProjetosConfig.ler(dados([
            "bancada": ["ativo": true],
            "prova_remota": ["pastas_do_app": ["App", "App.xcodeproj"]],
        ]))
        XCTAssertTrue(lidos[0].bancada)
        XCTAssertEqual(lidos[0].pastasDoApp, ["App", "App.xcodeproj"])
        // Salvar pelo app não apaga nenhum dos dois (antes o dict só tinha os campos conhecidos).
        let item = ProjetosConfig.dict(lidos)[0]
        XCTAssertEqual((item["bancada"] as? [String: Bool])?["ativo"], true)
        XCTAssertEqual((item["prova_remota"] as? [String: [String]])?["pastas_do_app"], ["App", "App.xcodeproj"])
    }

    func testBancadaSoLigaComAtivoTrue() {
        for bruto: Any in [true, ["ativo": "sim"], ["ativo": 1], [String: Any]()] {
            XCTAssertFalse(ProjetosConfig.ler(dados(["bancada": bruto]))[0].bancada, "\(bruto)")
        }
        var p = ProjetosConfig.ler(dados([:]))[0]
        XCTAssertFalse(p.bancada)
        XCTAssertNil(ProjetosConfig.dict([p])[0]["bancada"])
        p.bancada = true
        XCTAssertNotNil(ProjetosConfig.dict([p])[0]["bancada"])
    }

    func testEstadoDaProvaRemota() throws {
        XCTAssertEqual(ProvaRemotaProjeto.estado(repo: "  "), .semPasta)
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: pasta.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasta) }
        var visto: [String] = []
        let ok = ProvaRemotaProjeto.estado(repo: pasta.path) { _, args in
            visto = args
            return Subprocesso.Resultado(codigo: 0, saida: Data())
        }
        XCTAssertEqual(ok, .instalada)
        XCTAssertEqual(visto.suffix(3), ["cat-file", "-e", "origin/main:.github/workflows/prova-remota.yml"])
        let falta = ProvaRemotaProjeto.estado(repo: pasta.path) { _, _ in Subprocesso.Resultado(codigo: 128, saida: Data()) }
        XCTAssertEqual(falta, .falta)
        if case .desconhecido = ProvaRemotaProjeto.estado(repo: "/tmp/nao-existe-\(UUID().uuidString)") {} else {
            XCTFail("pasta sem .git devia ser desconhecido")
        }
    }

    func testComandoInstalarRecusaIdEstranho() {
        XCTAssertNil(ProvaRemotaProjeto.comandoInstalar(projetoID: ""))
        XCTAssertNil(ProvaRemotaProjeto.comandoInstalar(projetoID: "--pr"))
        XCTAssertTrue(ScriptsDoBundle.relativos.contains("tools/instalar-prova-remota"))
    }
}
