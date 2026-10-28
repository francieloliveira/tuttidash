import Foundation
import CoreServices

/// Observa diretórios do sistema de arquivos com `FSEventStream` e avisa (com debounce)
/// quando há mudanças. Se a criação/arranque do stream falhar, cai num timer de polling
/// (fallback) para não perder atualizações.
///
/// Uso típico:
/// ```
/// let obs = ObservadorArquivos(caminhos: [stateDir, logsDir]) { atualizar() }
/// obs.iniciar()
/// ```
public final class ObservadorArquivos {
    // MARK: - Caminhos observados

    public private(set) var caminhos: [URL]
    public var paths: [URL] { caminhos }
    public var urls: [URL] { caminhos }
    public var diretorios: [URL] { caminhos }

    // MARK: - Configuração

    public var debounce: TimeInterval
    public var intervaloDebounce: TimeInterval { debounce }
    public var debounceInterval: TimeInterval { debounce }

    public let fallbackIntervalo: TimeInterval
    public var fallbackInterval: TimeInterval { fallbackIntervalo }

    // MARK: - Estado

    public private(set) var estaObservando: Bool = false
    public var isObserving: Bool { estaObservando }
    public var observando: Bool { estaObservando }

    public private(set) var usaFallback: Bool = false
    public var usingFallback: Bool { usaFallback }
    public var fallbackAtivo: Bool { usaFallback }

    // MARK: - Callback (vários nomes para compatibilidade)

    private var _aoMudar: (() -> Void)?
    public var aoMudar: (() -> Void)? {
        get { _aoMudar }
        set { _aoMudar = newValue }
    }
    public var onChange: (() -> Void)? {
        get { _aoMudar }
        set { _aoMudar = newValue }
    }
    public var onChanged: (() -> Void)? {
        get { _aoMudar }
        set { _aoMudar = newValue }
    }
    public var callback: (() -> Void)? {
        get { _aoMudar }
        set { _aoMudar = newValue }
    }
    public var acao: (() -> Void)? {
        get { _aoMudar }
        set { _aoMudar = newValue }
    }

    // MARK: - Internos

    private var stream: FSEventStreamRef?
    private let fila: DispatchQueue
    private var trabalhoPendente: DispatchWorkItem?
    private var timerFallback: Timer?

    // MARK: - Inits

    public init(caminhos: [URL],
                debounce: TimeInterval = 0.25,
                fallbackIntervalo: TimeInterval = 30,
                aoMudar: (() -> Void)? = nil) {
        self.caminhos = caminhos
        self.debounce = max(0.05, debounce)
        self.fallbackIntervalo = max(1, fallbackIntervalo)
        self._aoMudar = aoMudar
        self.fila = DispatchQueue(label: "tuttidash.observador", qos: .utility)
    }

    public convenience init(caminhos: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    public convenience init(caminhos: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            acao: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: acao)
    }

    public convenience init(caminhos: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            callback: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: callback)
    }

    public convenience init(paths: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: paths, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(paths: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: paths, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    public convenience init(urls: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: urls, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(urls: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: urls, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    public convenience init(diretorios: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: diretorios, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(diretorios: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: diretorios, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    // Strings
    public convenience init(caminhos: [String],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: caminhos.map { URL(fileURLWithPath: $0) }, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(paths: [String],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: paths.map { URL(fileURLWithPath: $0) }, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    // Unlabeled first
    public convenience init(_ caminhos: [URL],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(_ caminhos: [String],
                            debounce: TimeInterval = 0.25,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: caminhos.map { URL(fileURLWithPath: $0) }, debounce: debounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    // intervaloDebounce alias param
    public convenience init(caminhos: [URL],
                            intervaloDebounce: TimeInterval,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: intervaloDebounce, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(caminhos: [URL],
                            intervaloDebounce: TimeInterval,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: intervaloDebounce, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    public convenience init(caminhos: [URL],
                            debounceInterval: TimeInterval,
                            fallbackIntervalo: TimeInterval = 30,
                            aoMudar: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounceInterval, fallbackIntervalo: fallbackIntervalo, aoMudar: aoMudar)
    }

    public convenience init(caminhos: [URL],
                            debounceInterval: TimeInterval,
                            fallbackIntervalo: TimeInterval = 30,
                            onChange: (() -> Void)? = nil) {
        self.init(caminhos: caminhos, debounce: debounceInterval, fallbackIntervalo: fallbackIntervalo, aoMudar: onChange)
    }

    deinit { parar() }

    // MARK: - Controle

    @discardableResult
    public func iniciar() -> Bool { iniciarObservacao() }

    @discardableResult
    public func start() -> Bool { iniciarObservacao() }

    @discardableResult
    public func observe() -> Bool { iniciarObservacao() }

    @discardableResult
    public func iniciarObservacao() -> Bool {
        parar()
        // Tenta FSEvents.
        if !caminhos.isEmpty, criarStream() {
            estaObservando = true
            usaFallback = false
            return true
        }
        // Fallback: polling.
        usaFallback = true
        estaObservando = false
        ativarFallback()
        return false
    }

    public func parar() { pararObservacao() }

    public func stop() { pararObservacao() }

    public func pararObservacao() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        trabalhoPendente?.cancel()
        trabalhoPendente = nil
        timerFallback?.invalidate()
        timerFallback = nil
        estaObservando = false
        usaFallback = false
    }

    // MARK: - FSEvents

    private func criarStream() -> Bool {
        let paths = caminhos.map { $0.path } as CFArray
        var context = FSEventStreamContext(version: 0,
                                          info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault,
                                          { _, info, _, _, _, _ in
                                              guard let info else { return }
                                              let obs = Unmanaged<ObservadorArquivos>.fromOpaque(info).takeUnretainedValue()
                                              obs.receberEvento()
                                          },
                                          &context,
                                          paths,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.1,
                                          flags) else {
            return false
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, fila)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            return false
        }
        return true
    }

    private func receberEvento() {
        trabalhoPendente?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.disparar()
        }
        trabalhoPendente = item
        fila.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func disparar() {
        DispatchQueue.main.async { [weak self] in
            self?._aoMudar?()
        }
    }

    private func ativarFallback() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timerFallback?.invalidate()
            self.timerFallback = Timer.scheduledTimer(withTimeInterval: self.fallbackIntervalo, repeats: true) { [weak self] _ in
                self?._aoMudar?()
            }
        }
    }
}
