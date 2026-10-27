import Foundation

/// Junta ledger + logs + estado das lanes, só leitura. Não grava nada em lugar nenhum.
///
/// - Histórico: o `ledger.jsonl` da ferramenta `gasto` (inclui logs já apagados do disco).
/// - Frescor: logs que mudaram desde a última coleta (tamanho/mtime diferente do `fonte` do ledger),
///   que não estão no ledger ou que estão em andamento são lidos aqui mesmo, com as regras do
///   `parser.py`, e guardados num cache em memória por (nome, tamanho, mtime).
///
/// Não é thread-safe: use sempre da mesma fila serial (por isso `@unchecked Sendable`).
public final class Carregador: @unchecked Sendable {
    public struct Resultado: Sendable {
        public var execucoes: [Execucao]
        public var estado: EstadoLanes
        public var config: Configuracao
        public var ledgerExiste: Bool
        public var logsDirExiste: Bool
        public var lidosDosLogs: Int
        /// Lanes que pararam sem fechar o card e podem ser retomadas (mais nova primeiro).
        public var retomadas: [Retomada] = []
        /// `#N` de cada execução, contado no histórico inteiro (antes de tirar lanes desligadas).
        public var ordinais: [String: Int] = [:]
    }

    private struct ChaveCache: Hashable {
        var nome: String
        var tamanho: Int
        var mtime: Double
        var emAndamento: Bool
    }

    private var cache: [ChaveCache: Execucao] = [:]

    public init() {}

    public func carregar(config: Configuracao) -> Resultado {
        let fm = FileManager.default
        let estadoLido = EstadoLanes.ler(pasta: config.stateDir)
        // Toggle geral (FRA-372): lane desligada não entra em nada — nem gasto,
        // nem retomadas, nem "agora". Sem chave `contas`, valem todas.
        let hab = config.lanesHabilitadas
        let estado = hab.map { h in
            EstadoLanes(heartbeat: estadoLido.heartbeat, lanes: estadoLido.lanes.filter { h.contains($0.lane) })
        } ?? estadoLido
        let rodando = estado.logsEmAndamento
        let ledgerExiste = fm.fileExists(atPath: config.ledger.path)
        var registros = ledgerExiste ? Ledger.carregar(url: config.ledger) : [:]

        var ehPasta: ObjCBool = false
        let logsExiste = fm.fileExists(atPath: config.logsDir.path, isDirectory: &ehPasta) && ehPasta.boolValue
        var lidos = 0
        var novoCache: [ChaveCache: Execucao] = [:]
        if logsExiste {
            let urls = (try? fm.contentsOfDirectory(at: config.logsDir,
                                                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let nome = url.lastPathComponent
                guard let meta = ParserLog.lerNome(nome) else { continue }
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                let fonte = Fonte(tamanho: v.fileSize ?? 0,
                                  mtime: ((v.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded() / 1000)
                let emAndamento = rodando.contains(nome)
                if let antigo = registros[meta.id], let f = antigo.fonte, f.igual(fonte),
                   antigo.status != .emAndamento, antigo.status != .morta, !emAndamento {
                    continue   // o ledger já está em dia com esse log
                }
                let chave = ChaveCache(nome: nome, tamanho: fonte.tamanho, mtime: fonte.mtime, emAndamento: emAndamento)
                if let c = cache[chave] {
                    registros[meta.id] = c
                    novoCache[chave] = c
                    continue
                }
                guard let ex = try? ParserLog.ler(url: url, emAndamento: rodando) else { continue }
                registros[meta.id] = ex
                novoCache[chave] = ex
                lidos += 1
            }
        }
        cache = novoCache
        let retomadas = logsExiste
            ? Retomadas.ler(logsDir: config.logsDir, cardsRodando: Set(estado.lanes.map(\.card)),
                              rotuloDono: config.rotuloDono).filter { hab?.contains($0.lane) ?? true }
            : []
        var lista = registros.values.sorted { ($0.inicio, $0.id) < ($1.inicio, $1.id) }
        let ordinais = Indicadores.ordinais(lista)
        if let hab { lista.removeAll { !hab.contains($0.lane) } }
        return Resultado(execucoes: lista, estado: estado, config: config, ledgerExiste: ledgerExiste,
                         logsDirExiste: logsExiste, lidosDosLogs: lidos, retomadas: retomadas, ordinais: ordinais)
    }
}
