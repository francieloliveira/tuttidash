import XCTest
@testable import GastoCore

final class MigracaoControleTests: XCTestCase {
    func testDoutorMostraBundleQuandoOHashConfere() {
        let veredito = VereditoIntegridade(confere: true, aviso: nil)
        let r = DoutorControle.avaliar(
            pistas: ["/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente", "dispatcher"],
            veredito: veredito)
        XCTAssertEqual(r.copia, .bundle("/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"))
        XCTAssertTrue(r.hashConfere)
        XCTAssertEqual(r.texto, "cópia em uso: bundle (/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente)\nhash: confere")
    }

    func testDoutorPrefereLegadoEHashDivergente() {
        let veredito = VereditoIntegridade(confere: false, aviso: "integridade: divergencia: hash")
        let legado = "/Users/teste/.transcentia/lanes/dispatcher.py"
        let r = DoutorControle.avaliar(
            pistas: ["/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente", legado],
            veredito: veredito)
        XCTAssertEqual(r.copia, .legado(legado))
        XCTAssertFalse(r.hashConfere)
        XCTAssertTrue(r.texto.contains("cópia em uso: legado (\(legado))"))
        XCTAssertTrue(r.texto.contains("hash: não confere"))
    }

    func testDoutorSemCopia() {
        let r = DoutorControle.avaliar(pistas: [], veredito: .ok)
        XCTAssertEqual(r.copia, .nenhuma)
        XCTAssertEqual(r.texto, "cópia em uso: nenhuma\nhash: confere")
    }

    func testPistasLeemOProgramaDoPlist() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fra617-pistas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.transcentia.lanes.dispatcher.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "ProgramArguments": ["/usr/bin/python3", "/tmp/x/.transcentia/lanes/dispatcher.py"],
        ]
        let dados = try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
        try dados.write(to: plist)
        let pistas = DoutorControle.pistas(home: home)
        XCTAssertTrue(pistas.contains("/tmp/x/.transcentia/lanes/dispatcher.py"))
        let r = DoutorControle.avaliar(pistas: pistas, veredito: .ok)
        XCTAssertEqual(r.copia.nome, "legado")
    }

    func testVerificacaoFalhadaNaoMoveERestauraDepois() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fra617-ap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent(".transcentia/lanes/dispatcher.py")
        let pause = home.appendingPathComponent(".transcentia/bots/PAUSE")
        let config = home.appendingPathComponent(".transcentia/tools/config.json")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ANTIGO\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: script.path)
        try FileManager.default.createDirectory(at: pause.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pause\n".utf8).write(to: pause)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"enabled\": false}\n".utf8).write(to: config)

        let ruim = AposentadoriaControle.aplicar(home: home, confere: false, aviso: "integridade: divergencia: hash")
        XCTAssertEqual(ruim, .rollback("integridade: divergencia: hash"))
        XCTAssertEqual(try String(contentsOf: script), "ANTIGO\n")
        XCTAssertEqual(try String(contentsOf: pause), "pause\n")

        let boa = AposentadoriaControle.aplicar(home: home, confere: true, aviso: "")
        guard case .aposentadas(let avisos) = boa else { return XCTFail("\(boa)") }
        XCTAssertTrue(avisos.contains { $0.contains("aposentada") && $0.contains("dispatcher.py") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertEqual(try String(contentsOf: pause), "pause\n")
        XCTAssertEqual(try String(contentsOf: config), "{\"enabled\": false}\n")
        let aposentado = try XCTUnwrap(FileManager.default.enumerator(at: home.appendingPathComponent(".transcentia/aposentados"), includingPropertiesForKeys: nil)?.allObjects
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "dispatcher.py" })
        let modo = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: aposentado.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(modo.uint16Value & 0o111, 0)

        XCTAssertTrue(AposentadoriaControle.restaurar(home: home))
        XCTAssertEqual(try String(contentsOf: script), "ANTIGO\n")
        let voltou = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(voltou.uint16Value & 0o755, 0o755)
        XCTAssertEqual(try String(contentsOf: pause), "pause\n")
        XCTAssertEqual(try String(contentsOf: config), "{\"enabled\": false}\n")
    }
}
