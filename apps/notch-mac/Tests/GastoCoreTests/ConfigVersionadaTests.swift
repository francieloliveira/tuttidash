import XCTest
@testable import GastoCore

/// FRA-295: config versionada em Application Support, fallback no legado e nos padrões.
final class ConfigVersionadaTests: XCTestCase {
    func testSemArquivoUsaPadroesENovoCaminho() throws {
        let t = try PastaTemp()
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.arquivoConfig.path, Configuracao.arquivoNovo(home: t.url).path)
        XCTAssertFalse(c.usandoLegado); XCTAssertNil(c.versao); XCTAssertEqual(c.avisoPct, 80)
        let d = Configuracao.lerArquivo(ambiente: [:], home: t.url)
        XCTAssertTrue(d.isEmpty)
        XCTAssertEqual(Configuracao.numero("preflight.max_load", padrao: 16, em: d), 16)
    }

    func testLegadoComoFallback() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json", #"{"aviso_pct":70}"#)
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertTrue(c.usandoLegado); XCTAssertEqual(c.avisoPct, 70); XCTAssertNil(c.versao)
    }

    func testNovoVenceLegado() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json", #"{"aviso_pct":70}"#)
        try t.escrever("Library/Application Support/TranscentIA Gasto/config.json",
                       #"{"version":1,"aviso_pct":60,"preflight":{"max_load":20}}"#)
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertFalse(c.usandoLegado); XCTAssertEqual(c.avisoPct, 60); XCTAssertEqual(c.versao, 1)
        let d = Configuracao.lerArquivo(ambiente: [:], home: t.url)
        XCTAssertEqual(Configuracao.numero("preflight.max_load", padrao: 16, em: d), 20)
        XCTAssertEqual(Configuracao.numero("preflight.jobs", padrao: 2, em: d), 2)
    }

    func testMigracaoMantemLegadoENaoSobrescreve() throws {
        let t = try PastaTemp()
        try t.escrever(".transcentia/tools/config.json", #"{"teto_semanal_usd":28}"#)
        XCTAssertTrue(try Configuracao.migrar(home: t.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Configuracao.arquivoLegado(home: t.url).path))
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.versao, Configuracao.versaoAtual); XCTAssertEqual(c.tetoSemanalUSD, 28)
        XCTAssertFalse(try Configuracao.migrar(home: t.url))
    }

    func testPastaLanekeeperECopiadaSemApagar() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/Lanekeeper/config.json", #"{"aviso_pct":61}"#)
        try t.escrever("Library/Application Support/Lanekeeper/agendas.json", "[]")
        XCTAssertEqual(Configuracao.lerArquivo(ambiente: [:], home: t.url)["aviso_pct"] as? Int, 61)
        XCTAssertEqual(Configuracao.copiarPastaAntiga(home: t.url), ["agendas.json", "config.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: Configuracao.arquivoLanekeeper(home: t.url).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Configuracao.arquivoNovo(home: t.url).path))
        XCTAssertEqual(Configuracao.copiarPastaAntiga(home: t.url), [])
    }

    func testTaxaUsdBrlVemDaConfigOuDoAmbiente() throws {
        let aninhada = try PastaTemp()
        try aninhada.escrever("Library/Application Support/Lanekeeper/config.json",
                              #"{"cambio":{"usd_brl":5.25}}"#)
        XCTAssertEqual(Configuracao.resolver(ambiente: [:], home: aninhada.url).taxaUsdBrl ?? 0, 5.25, accuracy: 0.001)

        let topo = try PastaTemp()
        try topo.escrever("Library/Application Support/Lanekeeper/config.json", #"{"usd_brl":4}"#)
        XCTAssertEqual(Configuracao.resolver(ambiente: [:], home: topo.url).taxaUsdBrl ?? 0, 4, accuracy: 0.001)

        let comEnv = try PastaTemp()
        try comEnv.escrever("Library/Application Support/Lanekeeper/config.json",
                            #"{"usd_brl":4,"cambio":{"usd_brl":9}}"#)
        let env = Configuracao.resolver(ambiente: ["TRANSCENTIA_GASTO_USD_BRL": "6,5"], home: comEnv.url)
        XCTAssertEqual(env.taxaUsdBrl ?? 0, 6.5, accuracy: 0.001)

        let zero = try PastaTemp()
        try zero.escrever("Library/Application Support/Lanekeeper/config.json", #"{"usd_brl":0}"#)
        XCTAssertNil(Configuracao.resolver(ambiente: [:], home: zero.url).taxaUsdBrl)
        XCTAssertNil(Configuracao.resolver(ambiente: [:], home: try PastaTemp().url).taxaUsdBrl)
    }

    func testNomeProvisorioAceitoEMigrado() throws {
        let t = try PastaTemp()
        try t.escrever("Library/Application Support/TranscentIA Gasto/config.json", #"{"version":1,"aviso_pct":65}"#)
        XCTAssertEqual(Configuracao.resolver(ambiente: [:], home: t.url).avisoPct, 65)
        XCTAssertTrue(try Configuracao.migrar(home: t.url))
        let c = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(c.arquivoConfig.path, Configuracao.arquivoNovo(home: t.url).path); XCTAssertEqual(c.avisoPct, 65)
    }
}
