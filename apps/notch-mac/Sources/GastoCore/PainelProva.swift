import Foundation

/// Lê o texto de um `proof.log` e organiza o lock único (uma prova por vez).
public enum Provas {
    public static let tentativasDoScript = 2
    /// Teto da lista da tela Testes. O resumo curto continua em `limiteUltimas`.
    public static let limiteHistorico = 80
    /// «Últimas» de quem ainda quer só um punhado, uma prova por card.
    public static let limiteUltimas = 5

    public static func organizar(_ brutas: [ProvaBruta], agora: Date) -> (cartas: [CartaoProva], historico: [ResumoProvaHistorico]) {
        let atuais = brutas.filter { !$0.historico }
        let rodando = atuais.filter { emAndamento($0) }.sorted { ordem($0, $1) }
        let dono = rodando.first
        let extras = Array(rodando.dropFirst())
        let fila = (atuais.filter(\.esperandoLock) + extras).sorted { ordem($0, $1) }
        let filaIDs = Set(fila.map(chave))
        let donoID = dono.map(chave)
        let terminadas = atuais.filter { bruta in
            let id = chave(bruta)
            return id != donoID && !filaIDs.contains(id)
        }.sorted { ordem($1, $0) }

        var cartas: [CartaoProva] = []
        if let dono {
            cartas.append(carta(dono, agora: agora, seguraLock: true, posicao: nil, espera: nil))
        }
        for (indice, bruta) in fila.enumerated() {
            let espera = bruta.pedidoEm.map { max(0, Int(agora.timeIntervalSince($0))) }
            cartas.append(carta(bruta, agora: agora, seguraLock: false, posicao: indice + 1, espera: espera))
        }
        for bruta in terminadas {
            cartas.append(carta(bruta, agora: agora, seguraLock: false, posicao: nil, espera: nil))
        }

        let arquivadas = brutas.filter(\.historico).sorted { ordem($1, $0) }
        return (cartas, historico(cartas, arquivadas: arquivadas, agora: agora))
    }

    /// Histórico da tela Testes: cada prova fechada, a mais nova primeiro, até `limiteHistorico`.
    /// A que está em curso ou na fila não entra, nem duração 0 s. O mesmo card pode repetir.
    static func historico(_ cartas: [CartaoProva], arquivadas: [ProvaBruta], agora: Date,
                           limite: Int = limiteHistorico) -> [ResumoProvaHistorico] {
        var lista = cartas.filter(fechada).map(resumo)
        lista += arquivadas.map { resumo(carta($0, agora: agora, seguraLock: false, posicao: nil, espera: nil)) }
        let fechadas = lista.filter(fechada).sorted { a, b in
            if a.segundos != b.segundos { return a.segundos < b.segundos }
            if a.card != b.card { return a.card < b.card }
            return a.lane < b.lane
        }
        return Array(fechadas.prefix(max(0, limite)))
    }

    /// Resumo curto: uma prova por card, no máximo `limiteUltimas`. A tela Testes usa `historico`.
    static func ultimas(_ cartas: [CartaoProva], arquivadas: [ProvaBruta], agora: Date,
                         limite: Int = limiteUltimas) -> [ResumoProvaHistorico] {
        var vistos: Set<String> = []
        var saida: [ResumoProvaHistorico] = []
        let teto = max(0, limite)
        for item in historico(cartas, arquivadas: arquivadas, agora: agora, limite: .max) {
            let id = item.card.uppercased()
            if vistos.contains(id) { continue }
            vistos.insert(id)
            saida.append(item)
            if saida.count == teto { break }
        }
        return saida
    }

    static func fechada(_ carta: CartaoProva) -> Bool {
        !carta.emCurso && carta.posicaoFila == nil && !carta.seguraLock && carta.segundos > 0
    }

    static func fechada(_ item: ResumoProvaHistorico) -> Bool {
        !item.emCurso && item.segundos > 0 && item.selo != "em curso"
    }

    public static func carta(_ bruta: ProvaBruta, agora: Date, seguraLock: Bool, posicao: Int?, espera: Int?) -> CartaoProva {
        let analise = analisar(bruta.log)
        let terminou = bruta.saida != nil || analise.sucesso || analise.falhaDeclarada
        let executados = analise.executados ?? analise.testes
        let zero = terminou && executados == 0
        let falha = zero || (analise.falhaDeclarada && !analise.sucesso)
            || (bruta.saida != nil && bruta.saida != 0 && !analise.sucesso)
        let emCurso = !terminou && !bruta.esperandoLock && posicao == nil
        let segundos = bruta.pedidoEm.map { max(0, Int(agora.timeIntervalSince($0))) } ?? 0
        let tentativa = max(analise.tentativa, 1)
        let tentativas = max(tentativasDoScript, tentativa)
        let suiteFalhou = analise.suites.contains { $0.estado == .falha }
        let motivo: String?
        if zero {
            motivo = "A prova rodou 0 testes e por isso conta como falha."
        } else if let frase = analise.frase, suiteFalhou || falha {
            motivo = frase
        } else if let suite = analise.suites.first(where: { $0.estado == .falha }) {
            motivo = "\(suite.nome) falhou."
        } else if falha {
            motivo = "A prova falhou."
        } else {
            motivo = nil
        }
        let proxima: String
        if bruta.esperandoLock || posicao != nil {
            proxima = "Nada é compilado enquanto espera o lock."
        } else if emCurso {
            proxima = "Aguardar o fim desta prova."
        } else if zero || (falha && tentativa < tentativas) {
            proxima = "Nova tentativa com preflight. Se falhar de novo, o card volta para a lane com o motivo."
        } else if falha {
            proxima = "O card volta para a lane com o motivo da falha."
        } else {
            proxima = "Seguir para o fechamento do card."
        }
        return CartaoProva(
            lane: bruta.lane, card: bruta.card, descricao: bruta.descricao ?? "sem descrição",
            segundos: segundos, tentativa: tentativa, tentativas: tentativas,
            fases: fases(analise, terminou: terminou, falha: falha, zero: zero),
            suites: analise.suites, motivo: motivo, proximaAcao: proxima,
            zeroTestes: zero, falha: falha, emCurso: emCurso,
            seguraLock: seguraLock, posicaoFila: posicao, esperaSegundos: espera)
    }

    static func emAndamento(_ bruta: ProvaBruta) -> Bool {
        if bruta.esperandoLock || bruta.historico || bruta.saida != nil { return false }
        let analise = analisar(bruta.log)
        return !analise.sucesso && !analise.falhaDeclarada
    }

    static func chave(_ bruta: ProvaBruta) -> String { "\(bruta.lane)|\(bruta.card)|\(bruta.pedidoEm?.timeIntervalSince1970 ?? 0)" }

    static func ordem(_ a: ProvaBruta, _ b: ProvaBruta) -> Bool {
        let da = a.pedidoEm ?? .distantFuture
        let db = b.pedidoEm ?? .distantFuture
        if da != db { return da < db }
        return a.lane < b.lane
    }

    static func resumo(_ carta: CartaoProva) -> ResumoProvaHistorico {
        let selo: String
        if carta.emCurso { selo = "em curso" }
        else if carta.zeroTestes { selo = "0 testes" }
        else if carta.falha { selo = "falha" }
        else { selo = "ok" }
        return ResumoProvaHistorico(card: carta.card, titulo: carta.descricao, lane: carta.lane, selo: selo, segundos: carta.segundos,
                                    zeroTestes: carta.zeroTestes, falha: carta.falha, emCurso: carta.emCurso)
    }

    struct Analise {
        var compilou = false
        var arquivos = 0
        var testes = 0
        var executados: Int?
        var segunda = false
        var tentativa = 1
        var sucesso = false
        var falhaDeclarada = false
        var frase: String?
        var suites: [SuiteProva] = []
    }

    static func analisar(_ log: String) -> Analise {
        var a = Analise()
        var ordemSuites: [String] = []
        var acum: [String: (segundos: Double, falhou: Bool, rodou: Bool)] = [:]
        var planejadas: [String] = []
        let linhas = log.split(whereSeparator: \.isNewline).map { String($0) }
        let caso = try? NSRegularExpression(pattern: #"Test Case '-\[(?:\S+?\.)?(\w+) \w+\]' (passed|failed)(?: \(([0-9.]+) seconds\))?"#)
        let swift = try? NSRegularExpression(pattern: #"[✔✘] Test (\S+?)\(\) (passed|failed)"#)
        let executado = try? NSRegularExpression(pattern: #"Executed (\d+) tests?"#)
        let prova = try? NSRegularExpression(pattern: #"\[prova\] ([A-Za-z0-9_./]+)(?:.*?(\d+)ª tentativa)?"#)
        // unittest do Python (o projeto TuttiDash prova com `python3 -m unittest`).
        let pythonRan = try? NSRegularExpression(pattern: #"Ran (\d+) tests? in"#)
        var suitePython: String?
        var ranPython = 0
        for linha in linhas {
            if linha.contains("CompileSwift") || linha.contains("SwiftCompile") || linha.contains("Compiling ") {
                a.compilou = true
                a.arquivos += 1
            }
            if let m = primeiro(prova, linha), m.count >= 2 {
                a.compilou = true
                suitePython = m[0]
                ranPython = 0
                if let n = Int(m[1]) {
                    a.tentativa = max(a.tentativa, n)
                    if n >= 2 { a.segunda = true }
                }
                if !planejadas.contains(m[0]) { planejadas.append(m[0]) }
            }
            if let m = primeiro(caso, linha) {
                registrar(&acum, ordem: &ordemSuites, nome: m[0], passou: m.count > 1 && m[1] == "passed",
                          segundos: m.count > 2 ? Double(m[2]) : nil, analise: &a)
            } else if let m = primeiro(swift, linha) {
                let nome = m[0].split(separator: ".").last.map(String.init) ?? m[0]
                registrar(&acum, ordem: &ordemSuites, nome: nome, passou: m.count > 1 && m[1] == "passed",
                          segundos: nil, analise: &a)
            }
            if let m = primeiro(executado, linha), let n = Int(m[0]) {
                a.executados = n
            }
            if let m = primeiro(pythonRan, linha), let n = Int(m[0]) {
                ranPython = n
                a.executados = max(a.executados ?? 0, n)
            }
            if let suite = suitePython, ranPython > 0 {
                let limpa = linha.trimmingCharacters(in: .whitespaces)
                if limpa == "OK" || limpa.hasPrefix("OK (") {
                    registrarPython(&acum, ordem: &ordemSuites, nome: suite, passou: true,
                                    rodou: ranPython, analise: &a)
                    suitePython = nil
                    ranPython = 0
                } else if limpa.hasPrefix("FAILED (") {
                    registrarPython(&acum, ordem: &ordemSuites, nome: suite, passou: false,
                                    rodou: ranPython, analise: &a)
                    a.falhaDeclarada = true
                    a.sucesso = false
                    suitePython = nil
                    ranPython = 0
                }
            }
            if linha.contains("TEST SUCCEEDED") { a.sucesso = true; a.falhaDeclarada = false }
            if linha.contains("TEST FAILED") || linha.contains("BUILD FAILED") { a.falhaDeclarada = true; a.sucesso = false }
            if a.frase == nil, let frase = fraseDe(linha) { a.frase = frase }
        }
        if ordemSuites.isEmpty {
            for nome in planejadas {
                a.suites.append(SuiteProva(nome: nome, segundos: nil, estado: .pendente))
            }
        } else {
            for nome in ordemSuites {
                let s = acum[nome] ?? (0, false, false)
                a.suites.append(SuiteProva(nome: nome, segundos: s.rodou ? Int(s.segundos.rounded()) : nil,
                                           estado: s.falhou ? .falha : .ok))
            }
        }
        return a
    }

    static func registrar(_ acum: inout [String: (segundos: Double, falhou: Bool, rodou: Bool)],
                          ordem: inout [String], nome: String, passou: Bool, segundos: Double?, analise: inout Analise) {
        analise.testes += 1
        if !ordem.contains(nome) {
            ordem.append(nome)
            acum[nome] = (0, false, false)
        }
        var atual = acum[nome] ?? (0, false, false)
        atual.rodou = true
        atual.segundos += segundos ?? 0
        if !passou { atual.falhou = true }
        acum[nome] = atual
    }

    static func registrarPython(_ acum: inout [String: (segundos: Double, falhou: Bool, rodou: Bool)],
                                ordem: inout [String], nome: String, passou: Bool, rodou: Int,
                                analise: inout Analise) {
        analise.testes += rodou
        if !ordem.contains(nome) {
            ordem.append(nome)
            acum[nome] = (0, false, false)
        }
        var atual = acum[nome] ?? (0, false, false)
        atual.rodou = true
        if !passou { atual.falhou = true }
        acum[nome] = atual
    }

    static func fases(_ a: Analise, terminou: Bool, falha: Bool, zero: Bool) -> [FaseMarcada] {
        let compilou = a.compilou || a.testes > 0 || terminou
        let andando = a.testes > 0 && !terminou && !a.segunda
        let compilar: FaseMarcada
        if !compilou {
            compilar = FaseMarcada(fase: .compilar, marca: .aguardando, detalhe: "aguardando")
        } else if andando || a.segunda || terminou {
            compilar = FaseMarcada(fase: .compilar, marca: .feita, detalhe: a.arquivos > 0 ? "\(a.arquivos) arquivos" : "feito")
        } else {
            compilar = FaseMarcada(fase: .compilar, marca: .atual, detalhe: "em curso")
        }
        let rodar: FaseMarcada
        if a.testes == 0 && !terminou {
            rodar = FaseMarcada(fase: .rodarSuites, marca: compilou ? .atual : .aguardando,
                                detalhe: compilou ? "aguardando suítes" : "aguardando")
        } else if a.segunda || terminou {
            rodar = FaseMarcada(fase: .rodarSuites, marca: .feita, detalhe: "\(max(a.suites.count, 1)) suítes")
        } else {
            let feitas = a.suites.filter { $0.estado != .pendente }.count
            rodar = FaseMarcada(fase: .rodarSuites, marca: .atual, detalhe: "\(feitas) feitas")
        }
        let repetir: FaseMarcada
        if a.segunda && !terminou {
            repetir = FaseMarcada(fase: .reexecutar, marca: .atual, detalhe: "em curso")
        } else if a.segunda && terminou {
            repetir = FaseMarcada(fase: .reexecutar, marca: falha ? .falha : .feita, detalhe: falha ? "falhou" : "feito")
        } else {
            repetir = FaseMarcada(fase: .reexecutar, marca: .aguardando, detalhe: "aguardando")
        }
        let veredito: FaseMarcada
        if !terminou {
            veredito = FaseMarcada(fase: .veredito, marca: .aguardando, detalhe: "aguardando")
        } else if falha || zero {
            veredito = FaseMarcada(fase: .veredito, marca: .falha, detalhe: zero ? "0 testes" : "falhou")
        } else {
            veredito = FaseMarcada(fase: .veredito, marca: .feita, detalhe: "ok")
        }
        return [compilar, rodar, repetir, veredito]
    }

    static func fraseDe(_ linha: String) -> String? {
        let baixa = linha.lowercased()
        if baixa.contains("test case") { return nil }
        let chaves = ["error:", "fatal error", "xctassert", "test failed", "abortado pelo preflight"]
        guard chaves.contains(where: { baixa.contains($0) }) else { return nil }
        var texto = linha.trimmingCharacters(in: .whitespaces)
        if let ponto = texto.firstIndex(of: "."), texto.distance(from: texto.startIndex, to: ponto) > 12,
           texto.distance(from: texto.startIndex, to: ponto) < 160 {
            texto = String(texto[...ponto])
        }
        if texto.count > 180 { texto = String(texto.prefix(177)) + "..." }
        return texto.isEmpty ? nil : texto
    }

    static func primeiro(_ re: NSRegularExpression?, _ texto: String) -> [String]? {
        guard let re else { return nil }
        let ns = texto as NSString
        let faixa = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: texto, range: faixa) else { return nil }
        var saida: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            saida.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return saida
    }
}
