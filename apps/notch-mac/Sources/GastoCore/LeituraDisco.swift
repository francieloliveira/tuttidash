import Foundation

/// Data de modificação e tamanho de cada arquivo que a leitura do painel consulta (FRA-580).
/// Carimbo igual ao da leitura anterior = nada mudou no disco. Só lê metadados, não abre arquivo.
public struct CarimboArquivos: Equatable, Sendable {
    struct Marca: Equatable, Sendable {
        var mtime: Double
        var tamanho: Int
    }

    /// Caminho → marca. Arquivo novo entra no mapa; arquivo apagado sai.
    private(set) var marcas: [String: Marca] = [:]

    public init() {}

    /// Arquivo: ele mesmo. Pasta: cada item do primeiro nível que passa no filtro; uma subpasta
    /// conta pela própria data, que muda quando entra ou sai item dela. Segue link simbólico.
    /// Caminho ausente não marca nada.
    public mutating func marcar(_ url: URL, itens filtro: (String) -> Bool = { _ in true }) {
        let fm = FileManager.default
        let alvo = url.resolvingSymlinksInPath()
        guard let attrs = try? fm.attributesOfItem(atPath: alvo.path) else { return }
        guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
            marcas[url.path] = Marca(mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                     tamanho: (attrs[.size] as? NSNumber)?.intValue ?? 0)
            return
        }
        let chaves: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let itens = (try? fm.contentsOfDirectory(at: alvo, includingPropertiesForKeys: chaves, options: [])) ?? []
        for item in itens where filtro(item.lastPathComponent) {
            let v = try? item.resourceValues(forKeys: Set(chaves))
            marcas[url.appendingPathComponent(item.lastPathComponent).path] =
                Marca(mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0, tamanho: v?.fileSize ?? 0)
        }
    }

    /// Tudo que `Carregador.carregar` e `LeitorPainelDisco.ler` consultam: estado das lanes, logs,
    /// ledger, log do dispatcher e de build, config, cache de modelos, agentes e o `.lane` de cada
    /// lane rodando (a prova).
    public static func painel(config: Configuracao, pastasLane: [URL]) -> CarimboArquivos {
        var c = CarimboArquivos()
        c.marcar(config.stateDir)
        c.marcar(config.logsDir)
        c.marcar(config.ledger)
        // Ao lado da pasta de logs, só o log do dispatcher e os de build entram.
        c.marcar(config.logsDir.deletingLastPathComponent()) { nome in
            nome == LeituraDisco.nomeLogDispatcher || (nome.hasPrefix("device-build-") && nome.hasSuffix(".log"))
        }
        c.marcar(config.arquivoConfig)
        c.marcar(ListaModelos.arquivoCache(home: config.home))
        for pasta in CatalogoAgentes.diretorios() + pastasLane { c.marcar(pasta) }
        return c
    }
}

/// Uma leitura completa do disco para o painel e o carimbo tirado antes dela (FRA-580).
/// O ciclo de 30 s reaproveita a leitura enquanto nenhum arquivo muda.
public struct LeituraDisco: Sendable {
    public static let nomeLogDispatcher = "lanes-dispatcher.log"

    public var resultado: Carregador.Resultado
    public var entrada: EntradaPainel
    public var carimbo: CarimboArquivos
    public var lidaEm: Date

    public static func logDispatcher(config: Configuracao) -> URL {
        config.logsDir.deletingLastPathComponent().appendingPathComponent(nomeLogDispatcher)
    }

    /// Lê ledger, logs e estado das lanes, ou devolve `anterior` (`pulou` true) quando ela ainda
    /// vale. `forcar` sempre lê («Atualizar agora», abrir o painel, Ajustes).
    /// Use da mesma fila do `carregador`.
    public static func ler(config: Configuracao, carregador: Carregador, anterior: LeituraDisco?,
                           forcar: Bool = false, politica: PoliticaAtualizacao = .padrao,
                           agora: Date = Date()) -> (leitura: LeituraDisco, pulou: Bool) {
        // Carimbo antes de ler: o que mudar durante a leitura aparece no próximo ciclo.
        let carimbo = CarimboArquivos.painel(config: config, pastasLane: anterior?.entrada.pastasLane ?? [])
        if !forcar, let anterior, anterior.vale(carimbo: carimbo, config: config, politica: politica, agora: agora) {
            return (anterior, true)
        }
        let resultado = carregador.carregar(config: config)
        let entrada = LeitorPainelDisco.ler(pasta: config.stateDir, logDispatcher: logDispatcher(config: config),
                                            logsDir: config.logsDir, agora: agora,
                                            worktrees: worktreesDosProjetos(config))
        return (LeituraDisco(resultado: resultado, entrada: entrada, carimbo: carimbo, lidaEm: agora), false)
    }

    /// Pastas de worktrees do cadastro de projetos. É onde ficam as provas dos cards
    /// que já fecharam: `~/…/<projeto>-worktrees`, expandido como no dispatcher.
    static func worktreesDosProjetos(_ config: Configuracao) -> [URL] {
        config.projetos.compactMap { projeto in
            let caminho = projeto.worktreesEfetivo.trimmingCharacters(in: .whitespaces)
            guard !caminho.isEmpty else { return nil }
            return Configuracao.expandir(caminho, ambiente: config.ambiente, home: config.home)
        }
    }

    /// Ainda vale: nenhum arquivo mudou, a config é a mesma, a leitura é mais nova que
    /// `idadeMaximaLeitura` e nenhum limite de conta venceu (o leitor só guarda limite futuro).
    func vale(carimbo: CarimboArquivos, config: Configuracao, politica: PoliticaAtualizacao, agora: Date) -> Bool {
        let idade = agora.timeIntervalSince(lidaEm)
        return carimbo == self.carimbo && config == resultado.config
            && idade >= 0 && idade < politica.idadeMaximaLeitura
            && !entrada.limitesAte.values.contains { $0 <= agora }
    }
}
