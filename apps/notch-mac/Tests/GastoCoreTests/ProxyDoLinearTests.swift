import XCTest
@testable import GastoCore

final class ProxyDoLinearTests: XCTestCase {
    func testArgumentosNaoLevamOToken() {
        let segredo = "lin_api_segredo_teste"
        let args = ProxyDoLinear.argumentos(script: "/tmp/proxy_linear.py")
        XCTAssertEqual(args, ["/usr/bin/python3", "/tmp/proxy_linear.py", "--servir"])
        XCTAssertFalse(args.contains { $0.contains(segredo) })
        XCTAssertEqual(args.filter { $0 == "--servir" }.count, 1)
    }

    func testPrimeiroScriptLegivel() throws {
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasta) }
        let script = pasta.appendingPathComponent("proxy_linear.py")
        try Data("print(1)\n".utf8).write(to: script)
        let achou = ProxyDoLinear.primeiroLegivel([
            pasta.appendingPathComponent("nao-existe.py"),
            script,
        ])
        XCTAssertEqual(achou, script)
        XCTAssertNil(ProxyDoLinear.primeiroLegivel([pasta.appendingPathComponent("nao-existe.py")]))
    }

    func testCandidatosIncluemOBundleENaoOToken() {
        let home = URL(fileURLWithPath: "/tmp/home-teste")
        let recursos = URL(fileURLWithPath: "/tmp/app/Contents/Resources")
        let lista = ProxyDoLinear.candidatosScript(home: home, recursos: recursos, executavel: nil)
        XCTAssertEqual(lista.map(\.path), [
            "/tmp/app/Contents/Resources/proxy_linear.py",
            "/tmp/home-teste/.transcentia/lanes/proxy_linear.py",
            "/tmp/home-teste/.transcentia/bots/proxy_linear.py",
        ])
        XCTAssertFalse(lista.contains { $0.path.contains("lin_api") })
    }
}
