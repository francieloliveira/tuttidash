import XCTest
@testable import GastoCore

/// Cadastro de contas acompanhadas. A chave continua `contas`, no formato que o
/// coletor e o carregador já leem. `ativo` ausente significa ligada.
final class ContasConfigTests: XCTestCase {
    private func conta(_ id: String, tipo: String? = nil, rotulo: String? = nil,
                       ativo: Bool = true, nova: Bool = false) -> ContaCadastro {
        let tipoConta = tipo ?? id
        return ContaCadastro(id: id, tipo: tipoConta, rotulo: rotulo ?? id, nome: id,
                             sigla: String(id.prefix(1)).uppercased(), ativo: ativo, nova: nova)
    }

    // MARK: - Leitura

    func testSemChaveSemeiaOPadrao() {
        XCTAssertEqual(ContasConfig.ler([:]), ContaUso.padrao.map { ContaCadastro(conta: $0) })
    }

    func testListaVaziaOuSoComTipoInvalidoSemeiaOPadrao() {
        let esperado = ContaUso.padrao.map { ContaCadastro(conta: $0) }
        XCTAssertEqual(ContasConfig.ler(["contas": [] as [[String: Any]]]), esperado)
        XCTAssertEqual(ContasConfig.ler(["contas": [["id": "x", "tipo": "tipo-que-nao-existe"]]]), esperado)
        XCTAssertEqual(ContasConfig.ler(["contas": "nao-e-lista"]), esperado)
    }

    func testLeOFormatoAtualSemCampoAtivo() {
        let d: [String: Any] = ["contas": [
            ["id": "g", "tipo": "grok", "rotulo": "G", "nome": "g", "sigla": "GR"],
        ]]
        let cs = ContasConfig.ler(d)
        XCTAssertEqual(cs.map(\.id), ["g"])
        XCTAssertEqual(cs[0].tipo, "grok")
        XCTAssertEqual(cs[0].rotulo, "G")
        XCTAssertEqual(cs[0].sigla, "GR")
        XCTAssertTrue(cs[0].ativo)
        XCTAssertFalse(cs[0].nova)
    }

    func testIdRepetidoSomeEAtivoFalseFica() {
        let d: [String: Any] = ["contas": [
            ["id": "claude", "tipo": "claude", "rotulo": "Claude", "ativo": true],
            ["id": "claude", "tipo": "claude", "rotulo": "Outra"],
            ["id": "grok", "tipo": "grok", "rotulo": "Grok", "ativo": false],
        ]]
        let cs = ContasConfig.ler(d)
        XCTAssertEqual(cs.map(\.id), ["claude", "grok"])
        XCTAssertEqual(cs[0].rotulo, "Claude")
        XCTAssertFalse(cs[1].ativo)
    }

    func testAgenteForaDosTiposDeMedicaoContinuaNaLista() {
        guard let extra = Agentes.ordem.first(where: { !ContaUso.tipos.contains($0) }) else { return }
        let d: [String: Any] = ["contas": [
            ["id": "claude", "tipo": "claude", "rotulo": "Claude"],
            ["id": extra, "tipo": extra],
        ]]
        XCTAssertEqual(ContasConfig.ler(d).map(\.id), ["claude", extra])
        var nova = conta("nova", tipo: extra, nova: true)
        nova.id = "nova"
        XCTAssertNotNil(ContasConfig.problema(nova, nas: [conta("claude"), nova]),
                        "conta nova não aceita um nome de lane que o coletor não mede")
        XCTAssertNil(ContasConfig.problema(conta(extra, tipo: extra), nas: [conta(extra, tipo: extra)]),
                     "conta já gravada com esse tipo continua válida")
    }

    // MARK: - Adicionar, remover, validar

    func testAdicionarEscolheOPrimeiroTipoLivre() {
        let base = [conta("claude")]
        let r = ContasConfig.rascunho(nas: base)
        XCTAssertTrue(r.nova)
        XCTAssertTrue(r.ativo)
        XCTAssertEqual(r.tipo, ContasConfig.primeiroTipoLivre(nas: base))
        if ContaUso.tipos.count > 1 {
            XCTAssertNotEqual(r.tipo, "claude")
        }
        XCTAssertFalse(base.map(\.id).contains(r.id))
        XCTAssertNil(ContasConfig.problema(r, nas: base + [r]))
    }

    func testAdicionarComTodosOsTiposUsadosGeraIdDistinto() {
        let base = ContaUso.tipos.map { conta($0, tipo: $0) }
        let r = ContasConfig.rascunho(nas: base)
        XCTAssertEqual(r.tipo, ContaUso.tipos.first)
        XCTAssertNotEqual(r.id, r.tipo)
        XCTAssertFalse(base.map(\.id).contains(r.id))
        XCTAssertNil(ContasConfig.problema(r, nas: base + [r]))
        XCTAssertEqual(ContasConfig.avisoTipo(r, nas: base + [r]),
                       "Já existe uma conta deste tipo. As duas leem a mesma credencial.")
    }

    func testRejeitaTipoInvalidoEIdRepetido() {
        let base = [conta("claude")]
        XCTAssertNotNil(ContasConfig.problema(conta("x", tipo: "tipo-que-nao-existe", nova: true), nas: base))
        XCTAssertNotNil(ContasConfig.problema(conta("x", tipo: "desconhecido"), nas: base))
        if !ContasConfig.tipoAceito("gemini") {
            XCTAssertNotNil(ContasConfig.problema(conta("x", tipo: "gemini", nova: true), nas: base))
        }
        XCTAssertNotNil(ContasConfig.problema(conta("claude", nova: true), nas: base + [conta("claude", nova: true)]))
        XCTAssertNil(ContasConfig.problema(conta("claude-2", tipo: "claude", nova: true),
                                           nas: base + [conta("claude-2", tipo: "claude", nova: true)]))
        XCTAssertNil(ContaUso(dict: ["id": "x", "tipo": "desconhecido"]))
    }

    func testNaoRemoveAUltimaContaGravadaERemoveRascunho() {
        let a = conta("claude")
        XCTAssertFalse(ContasConfig.podeRemover([a], a))
        XCTAssertNil(ContasConfig.remover(a, de: [a]))
        let b = conta("grok")
        XCTAssertEqual(ContasConfig.remover(a, de: [a, b])?.map(\.id), ["grok"])
        let r = ContasConfig.rascunho(nas: [a])
        XCTAssertTrue(ContasConfig.podeRemover([a, r], r))
        XCTAssertEqual(ContasConfig.remover(r, de: [a, r])?.map(\.id), ["claude"])
        XCTAssertFalse(ContasConfig.podeRemover([a, r], a))
    }

    func testTipoSoMudaEmContaNovaENaoApagaApelido() {
        let salva = conta("claude", rotulo: "Claude")
        let outro = ContaUso.tipos.first { $0 != "claude" } ?? "claude"
        XCTAssertEqual(ContasConfig.aplicarTipo(salva, tipo: outro, nas: [salva]).tipo, "claude")

        var r = ContasConfig.rascunho(nas: [])
        r.rotulo = "Meu apelido"
        let mudou = ContasConfig.aplicarTipo(r, tipo: outro, nas: [r])
        if outro != r.tipo {
            XCTAssertEqual(mudou.tipo, outro)
            XCTAssertEqual(mudou.rotulo, "Meu apelido")
            XCTAssertNotEqual(mudou.id, r.id)
        }
    }

    func testNormalizarPreencheRotuloNomeESigla() {
        var c = conta("grok")
        c.rotulo = "  "
        c.nome = ""
        c.sigla = ""
        let n = ContasConfig.normalizar(c)
        XCTAssertEqual(n.rotulo, ContasConfig.rotuloDoTipo("grok"))
        XCTAssertEqual(n.nome, "grok")
        XCTAssertEqual(n.sigla, ContasConfig.agente(do: "grok")?.sigla)
    }

    func testTituloESubtitulo() {
        let grok = ContaCadastro(conta: ContaUso(id: "grok", tipo: "grok", rotulo: "Grok CLI",
                                                 nome: "grok", sigla: "GR"))
        XCTAssertEqual(grok.titulo, ClarezaCota.tituloGrokCLI)
        XCTAssertEqual(grok.subtitulo, ClarezaCota.detalheGrokCLI)
        XCTAssertTrue(grok.mostraSubtitulo)

        let bot = conta("bot", tipo: "cursor", rotulo: "Bot")
        XCTAssertEqual(bot.titulo, "Bot")
        XCTAssertEqual(bot.subtitulo, ContasConfig.rotuloDoTipo("cursor"))
        XCTAssertTrue(bot.mostraSubtitulo)
    }

    // MARK: - Gravação

    func testDictAtivoOmiteAChaveEInativoGravaFalse() {
        let ativa = conta("claude", rotulo: "Claude")
        XCTAssertNil(ativa.dict["ativo"])
        XCTAssertEqual(ativa.dict["id"] as? String, "claude")
        XCTAssertEqual(ativa.dict["tipo"] as? String, "claude")
        XCTAssertEqual(ativa.dict["rotulo"] as? String, "Claude")
        XCTAssertEqual(ativa.dict["nome"] as? String, "claude")
        XCTAssertEqual(ativa.dict["sigla"] as? String, "C")
        var inativa = ativa
        inativa.ativo = false
        XCTAssertEqual(inativa.dict["ativo"] as? Bool, false)
        XCTAssertNil(ContaUso(id: "claude", tipo: "claude", rotulo: "Claude").dict["ativo"])
        XCTAssertEqual(ContaUso(dict: ["id": "claude", "tipo": "claude"])?.ativo, true)
        XCTAssertEqual(ContaUso(dict: ["id": "claude", "tipo": "claude", "ativo": false])?.ativo, false)
    }

    func testGravarNaoLevaRascunhoNemTipoInvalidoENaoApagaOResto() {
        var d: [String: Any] = [
            "teto_semanal_usd": 12,
            "opencode_db": "~/.local/share/opencode/opencode.db",
            "uso_contas": false,
            "contas": [["id": "claude", "tipo": "claude", "rotulo": "C", "nome": "claude", "sigla": "CL", "nota": "local"]],
        ]
        var salva = conta("claude", rotulo: "Meu Claude")
        salva.nome = "claude"
        salva.sigla = "CL"
        let rascunho = ContasConfig.rascunho(nas: [salva])
        ContasConfig.gravar([salva, rascunho, conta("g", tipo: "tipo-que-nao-existe")], em: &d)
        let lista = d["contas"] as? [[String: Any]]
        XCTAssertEqual(lista?.count, 1)
        XCTAssertEqual(lista?[0]["rotulo"] as? String, "Meu Claude")
        XCTAssertEqual(lista?[0]["sigla"] as? String, "CL")
        XCTAssertEqual(lista?[0]["nota"] as? String, "local")
        XCTAssertNil(lista?[0]["ativo"])
        XCTAssertEqual(d["teto_semanal_usd"] as? Int, 12)
        XCTAssertEqual(d["opencode_db"] as? String, "~/.local/share/opencode/opencode.db")
        XCTAssertEqual(d["uso_contas"] as? Bool, false, "conta ativa não liga a consulta sozinha")
    }

    func testSemContaAtivaDesligaAConsulta() {
        var d: [String: Any] = ["uso_contas": true, "logs_dir": "~/logs"]
        ContasConfig.gravar([conta("claude", ativo: false), conta("grok", ativo: false)], em: &d)
        XCTAssertEqual(d["uso_contas"] as? Bool, false)
        XCTAssertEqual((d["contas"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(d["logs_dir"] as? String, "~/logs")
    }

    func testIdaEVoltaPeloArquivo() throws {
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        let contas = [
            conta("claude", rotulo: "Meu Claude"),
            conta("bot", tipo: "cursor", rotulo: "Bot", ativo: false),
        ]
        try m.definirContas(contas)
        let outro = ModeloAjustes(home: t.url)
        XCTAssertEqual(ContasConfig.ler(outro.dados), contas)
        XCTAssertEqual(outro.dados["version"] as? Int, Configuracao.versaoAtual)

        let cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(cfg.contas.map(\.id), ["claude"])
        XCTAssertEqual(cfg.contas.map(\.rotulo), ["Meu Claude"])
        XCTAssertEqual(cfg.lanesHabilitadas, ["claude"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: t.url.appendingPathComponent(".transcentia/lanes/enabled").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: t.url.appendingPathComponent(".transcentia/bots/PAUSE").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: t.url.appendingPathComponent(".transcentia/bots/PAUSE.manual").path))
    }

    func testAtivoFalseNoJsonNaoEntraNaMedicao() throws {
        let bruto = #"{"id":"claude","tipo":"claude","rotulo":"C","ativo":false}"#.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: bruto) as! [String: Any]
        let lida = try XCTUnwrap(ContaUso(dict: obj))
        XCTAssertFalse(lida.ativo)

        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        try m.definirContas([conta("claude", ativo: false), conta("grok")])
        let cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertEqual(cfg.contas.map(\.id), ["grok"])
        XCTAssertEqual(cfg.lanesHabilitadas, ["grok"])
        XCTAssertTrue(cfg.usoContas)
    }

    func testOpencodeGoInativoNaoHabilitaALane() throws {
        guard Agentes.ordem.contains("opencode-go"), !ContaUso.tipos.contains("opencode-go") else { return }
        let t = try PastaTemp()
        let m = ModeloAjustes(home: t.url)
        try m.definirContas([
            conta("opencode"),
            conta("opencode-go", tipo: "opencode-go", rotulo: "OpenCode Go"),
        ])
        var cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertTrue(cfg.lanesHabilitadas?.contains("opencode") == true)
        XCTAssertTrue(cfg.lanesHabilitadas?.contains("opencode-go") == true)
        XCTAssertFalse(cfg.contas.contains { $0.tipo == "opencode-go" })

        try m.definirContas([
            conta("opencode"),
            conta("opencode-go", tipo: "opencode-go", rotulo: "OpenCode Go", ativo: false),
        ])
        cfg = Configuracao.resolver(ambiente: [:], home: t.url)
        XCTAssertFalse(cfg.lanesHabilitadas?.contains("opencode-go") == true)
        XCTAssertTrue(cfg.lanesHabilitadas?.contains("opencode") == true)
    }
}
