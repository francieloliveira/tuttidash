import Foundation
import CoreServices

/// Um caminho que o `ObservadorArquivos` vigia e quão depressa reagir a ele (FRA-581).
public struct CaminhoObservado: Equatable, Sendable {
    public enum Tipo: Equatable, Sendable { case pasta, arquivo }

    public var url: URL
    public var tipo: Tipo
    /// Espera mínima entre duas leituras puxadas por mudança aqui. Curta para o estado das lanes;
    /// longa para logs, que crescem a cada linha do agente.
    public var intervaloMinimo: TimeInterval

    public init(pasta url: URL, intervaloMinimo: TimeInterval) {
        self.url = url
        tipo = .pasta
        self.intervaloMinimo = max(0, intervaloMinimo)
    }

    public init(arquivo url: URL, intervaloMinimo: TimeInterval) {
        self.url = url
        tipo = .arquivo
        self.intervaloMinimo = max(0, intervaloMinimo)
    }

    /// O que vai para o `FSEventStream`: a própria pasta, ou a pasta do arquivo. Arquivo direto na
    /// home (ou acima dela) fica sozinho: vigiar a home inteira acordaria o app a cada mudança no Mac.
    func raiz(home: URL) -> String {
        let real = ObservadorArquivos.real(url.path)
        guard tipo == .arquivo else { return real }
        let pai = (real as NSString).deletingLastPathComponent
        let casa = ObservadorArquivos.real(home.path)
        if pai == "/" || pai == casa || casa.hasPrefix(pai + "/") { return real }
        return pai
    }
}

/// Quando disparar a leitura depois de um evento (FRA-581). Espera `debounce` para juntar a rajada
/// de escritas e nunca dispara antes do `intervaloMinimo` do caminho, contado da leitura anterior.
/// Evento novo não empurra um disparo já marcado: escrita contínua não adia a leitura para sempre.
/// Instantes em segundos de um relógio monotônico (quem chama passa `agora`).
public struct AgendaDisparo: Equatable, Sendable {
    public var debounce: TimeInterval
    public private(set) var ultimoDisparo: TimeInterval?
    public private(set) var proximo: TimeInterval?

    public init(debounce: TimeInterval) {
        self.debounce = max(0, debounce)
    }

    /// Chegou um evento relevante. true = `proximo` mudou e o disparo precisa ser (re)marcado.
    public mutating func evento(agora: TimeInterval, intervaloMinimo: TimeInterval) -> Bool {
        var alvo = agora + debounce
        if let u = ultimoDisparo { alvo = max(alvo, u + intervaloMinimo) }
        if let p = proximo, p <= alvo { return false }
        proximo = alvo
        return true
    }

    public mutating func disparou(agora: TimeInterval) {
        ultimoDisparo = agora
        proximo = nil
    }
}

/// Vigia pastas e arquivos com `FSEventStream` e chama `aoMudar` quando algo relevante muda,
/// sem reler a cada linha escrita (`AgendaDisparo`). Se o stream não sobe, cai num timer de
/// polling a cada `fallback` segundos.
///
/// Use só na main thread: o stream entrega os eventos na fila main e os timers rodam no run loop dela.
public final class ObservadorArquivos {
    public let caminhos: [CaminhoObservado]
    public let fallback: TimeInterval
    /// true = FSEvents ativo.
    public private(set) var observando = false
    /// true = o stream não subiu e o timer de `fallback` faz as leituras.
    public private(set) var emFallback = false

    /// Eventos que o FSEvents perdeu ou juntou: vale como mudança em todos os caminhos.
    static let flagsPerda = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)

    private let aoMudar: () -> Void
    private var agenda: AgendaDisparo
    /// Caminho real (minúsculas, sem barra no fim) e intervalo de cada `caminhos`.
    private var alvos: [(caminho: String, intervalo: TimeInterval)] = []
    private var stream: FSEventStreamRef?
    private var caixa: Caixa?
    private var disparoPendente: DispatchWorkItem?
    private var timerFallback: Timer?

    public init(caminhos: [CaminhoObservado], debounce: TimeInterval = 0.5, fallback: TimeInterval = 30,
                aoMudar: @escaping () -> Void) {
        self.caminhos = caminhos
        self.fallback = max(0.05, fallback)
        self.aoMudar = aoMudar
        agenda = AgendaDisparo(debounce: debounce)
    }

    deinit { parar() }

    /// Sobe o stream. false = caiu no polling (`emFallback`).
    @discardableResult
    public func iniciar() -> Bool {
        parar()
        alvos = caminhos.map { (caminho: Self.normalizar(Self.real($0.url.path)), intervalo: $0.intervaloMinimo) }
        let casa = FileManager.default.homeDirectoryForCurrentUser
        var raizes: [String] = []
        for c in caminhos {
            let r = c.raiz(home: casa)
            if !raizes.contains(r) { raizes.append(r) }
        }
        if !raizes.isEmpty, criarStream(raizes) {
            observando = true
            return true
        }
        emFallback = true
        let t = Timer.scheduledTimer(withTimeInterval: fallback, repeats: true) { [weak self] _ in
            self?.aoMudar()
        }
        t.tolerance = fallback / 6
        timerFallback = t
        return false
    }

    public func parar() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        caixa = nil
        disparoPendente?.cancel()
        disparoPendente = nil
        timerFallback?.invalidate()
        timerFallback = nil
        observando = false
        emFallback = false
    }

    // MARK: Eventos

    func receber(caminhos eventos: [String], flags: [FSEventStreamEventFlags]) {
        var menor: TimeInterval?
        for (i, e) in eventos.enumerated() {
            let perdido = i < flags.count && flags[i] & Self.flagsPerda != 0
            let t = perdido ? alvos.map { $0.intervalo }.min() : Self.intervalo(evento: e, alvos: alvos)
            if let t { menor = min(menor ?? t, t) }
        }
        guard let menor else { return }
        let agora = ProcessInfo.processInfo.systemUptime
        guard agenda.evento(agora: agora, intervaloMinimo: menor), let quando = agenda.proximo else { return }
        disparoPendente?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.disparar() }
        disparoPendente = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, quando - agora), execute: item)
    }

    private func disparar() {
        disparoPendente = nil
        agenda.disparou(agora: ProcessInfo.processInfo.systemUptime)
        aoMudar()
    }

    /// Menor intervalo entre os alvos que contêm `evento`. nil = mudança fora do que importa
    /// (por exemplo, outro arquivo na pasta de um arquivo vigiado).
    static func intervalo(evento: String, alvos: [(caminho: String, intervalo: TimeInterval)]) -> TimeInterval? {
        let e = normalizar(evento)
        var menor: TimeInterval?
        for a in alvos where e == a.caminho || e.hasPrefix(a.caminho + "/") {
            menor = min(menor ?? a.intervalo, a.intervalo)
        }
        return menor
    }

    // MARK: Caminhos

    /// O FSEvents manda caminhos reais (`/private/var/...`, links resolvidos) e o APFS ignora caixa.
    static func normalizar(_ caminho: String) -> String {
        var c = caminho.lowercased()
        while c.count > 1, c.hasSuffix("/") { c.removeLast() }
        return c
    }

    /// `realpath` do caminho; se ele ainda não existe, do ancestral mais próximo que existe.
    static func real(_ caminho: String) -> String {
        var atual = (caminho as NSString).standardizingPath
        var resto: [String] = []
        while true {
            if let r = realpath(atual, nil) {
                let base = String(cString: r)
                free(r)
                return resto.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
            }
            let pai = (atual as NSString).deletingLastPathComponent
            if pai == atual || pai.isEmpty { return caminho }
            resto.insert((atual as NSString).lastPathComponent, at: 0)
            atual = pai
        }
    }

    // MARK: FSEvents

    /// O stream guarda a caixa (retain/release) e a caixa guarda o observador fraco:
    /// evento que chega depois do `parar()` não toca num objeto já liberado.
    private final class Caixa {
        weak var dono: ObservadorArquivos?
        init(_ dono: ObservadorArquivos) { self.dono = dono }
    }

    private func criarStream(_ raizes: [String]) -> Bool {
        let caixa = Caixa(self)
        var contexto = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(caixa).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Caixa>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Caixa>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, n, caminhos, flags, _ in
            guard let info else { return }
            let caixa = Unmanaged<Caixa>.fromOpaque(info).takeUnretainedValue()
            let lista = (Unmanaged<CFArray>.fromOpaque(caminhos).takeUnretainedValue() as NSArray) as? [String] ?? []
            caixa.dono?.receber(caminhos: lista, flags: (0..<n).map { flags[$0] })
        }
        let opcoes = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &contexto, raizes as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, opcoes) else {
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        self.caixa = caixa
        return true
    }
}
