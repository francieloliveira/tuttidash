import Foundation

/// Ferramenta que o TuttiDash precisa ou usa (FRA-570): as de base ficam aqui; as dos agentes vêm
/// do bloco `instalar` de cada manifesto (`agents.d`). Instalar e entrar abrem o Terminal com o
/// comando oficial: a pessoa vê o que vai rodar e responde ao login. Nada roda escondido.
public struct Ferramenta: Identifiable, Equatable, Sendable {
    public enum Tipo: Sendable { case base, agente }
    public var id: String
    public var nome: String
    public var tipo: Tipo
    /// Para que serve, em uma linha.
    public var paraQue: String
    /// Executável procurado (ou `xcode-select` para as ferramentas da Apple).
    public var executavel: String
    /// Comando oficial de instalação.
    public var instalar: String
    /// Comando que entra na conta (vazio = não precisa).
    public var entrar: String
    /// O que a pessoa faz depois de abrir o comando de entrar.
    public var dicaEntrar: String
    public var docs: URL?
    /// true quando o comando de instalar usa o Homebrew.
    public var precisaBrew: Bool { instalar.hasPrefix("brew ") }
    /// Caminho achado. nil = não instalada.
    public var encontrada: String?
    /// nil = não dá para saber pelo app; true/false quando dá (ex.: `gh auth status`).
    public var conectada: Bool?
    public var opcional: Bool

    public init(id: String, nome: String, tipo: Tipo, paraQue: String, executavel: String, instalar: String,
                entrar: String = "", dicaEntrar: String = "", docs: URL? = nil, encontrada: String? = nil,
                conectada: Bool? = nil, opcional: Bool = false) {
        self.id = id; self.nome = nome; self.tipo = tipo; self.paraQue = paraQue; self.executavel = executavel
        self.instalar = instalar; self.entrar = entrar; self.dicaEntrar = dicaEntrar; self.docs = docs
        self.encontrada = encontrada; self.conectada = conectada; self.opcional = opcional
    }
}

public enum Ferramentas {
    /// Onde os instaladores oficiais põem os executáveis.
    public static func pastas(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
         home.appendingPathComponent(".grok/bin").path, home.appendingPathComponent(".opencode/bin").path,
         // O app DeepSeek Harness já traz o CLI `dsh`; não precisa de instalação global.
         "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin",
         "/usr/bin", "/bin"]
    }

    /// PATH dos comandos que o app roda e do roteiro do Terminal.
    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        pastas(home: home).joined(separator: ":")
    }

    public static func achar(_ executavel: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        pastas(home: home).map { "\($0)/\(executavel)" }.first(where: existe)
    }

    /// Ferramentas de base. git e python3 vêm das ferramentas de linha de comando da Apple: em
    /// `/usr/bin` há só um atalho que pede a instalação, por isso a conferência é o `xcode-select -p`.
    public static func base() -> [Ferramenta] {
        [Ferramenta(id: "brew", nome: "Homebrew", tipo: .base,
                    paraQue: String(localized: "Instala as outras ferramentas (gh, tmux)."),
                    executavel: "brew",
                    instalar: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                    docs: URL(string: "https://brew.sh")),
         Ferramenta(id: "apple", nome: String(localized: "Ferramentas da Apple (git e python3)"), tipo: .base,
                    paraQue: String(localized: "O git guarda o código; o python3 roda o dispatcher e o vigia."),
                    executavel: "xcode-select", instalar: "xcode-select --install",
                    docs: URL(string: "https://developer.apple.com/xcode/resources/")),
         Ferramenta(id: "gh", nome: "GitHub CLI (gh)", tipo: .base,
                    paraQue: String(localized: "Lista seus repositórios, clona e abre os PRs das lanes."),
                    executavel: "gh", instalar: "brew install gh", entrar: "gh auth login",
                    dicaEntrar: String(localized: "Escolha GitHub.com e entre pelo navegador."),
                    docs: URL(string: "https://cli.github.com")),
         Ferramenta(id: "tmux", nome: "tmux", tipo: .base,
                    paraQue: String(localized: "Mostra o terminal de cada lane no painel de logs."),
                    executavel: "tmux", instalar: "brew install tmux",
                    docs: URL(string: "https://github.com/tmux/tmux/wiki"), opcional: true)]
    }

    /// Ferramentas dos agentes que declaram `instalar` no manifesto; um executável aparece uma vez
    /// (OpenCode e OpenCode Go usam o mesmo `opencode`).
    public static func agentes(_ catalogo: [CatalogoAgentes.ModeloAgente]) -> [Ferramenta] {
        var vistos = Set<String>()
        return catalogo.sorted { $0.ordem < $1.ordem }.compactMap { a in
            guard let i = a.instalar, let exe = a.cli, vistos.insert(exe).inserted else { return nil }
            return Ferramenta(id: "agente-\(exe)", nome: i.nome.isEmpty ? a.rotulo : i.nome, tipo: .agente,
                              paraQue: a.optIn ? String(localized: "Conta de uso (opcional).")
                                               : String(localized: "Agente que trabalha nas lanes."),
                              executavel: exe, instalar: i.comando, entrar: i.entrar, dicaEntrar: i.dicaEntrar,
                              docs: URL(string: i.docs), opcional: a.optIn)
        }
    }

    /// Confere o que está instalado e, quando dá, se está conectado.
    public static func conferir(_ lista: [Ferramenta], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                existe: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                rodar: ([String]) -> Int32 = Ferramentas.codigo) -> [Ferramenta] {
        lista.map { f in
            var f = f
            if f.id == "apple" {
                f.encontrada = rodar(["/usr/bin/xcode-select", "-p"]) == 0 ? "/usr/bin/git" : nil
            } else {
                f.encontrada = achar(f.executavel, home: home, existe: existe)
            }
            if f.id == "gh", let gh = f.encontrada { f.conectada = rodar([gh, "auth", "status"]) == 0 }
            return f
        }
    }

    /// Código de saída de um comando curto (sem shell). -1 = não rodou.
    public static func codigo(_ args: [String]) -> Int32 {
        guard let exe = args.first else { return -1 }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path()
        return Subprocesso.rodar(exe, Array(args.dropFirst()), ambiente: env).codigo
    }

    // MARK: - Terminal

    /// Texto entre aspas simples para o bash.
    static func aspas(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Roteiro `.command` que o Terminal abre: mostra o comando, espera o Enter e roda.
    public static func roteiro(titulo: String, comando: String, dica: String = "", docs: URL? = nil,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var l = ["#!/bin/bash",
                 "export PATH=\(aspas(path(home: home))):\"$PATH\"",
                 "clear",
                 "echo \(aspas("TuttiDash · \(titulo)"))",
                 "echo"]
        if let docs { l.append("echo \(aspas(String(localized: "Comando oficial (\(docs.absoluteString)):")))") }
        else { l.append("echo \(aspas(String(localized: "Comando:")))") }
        l += ["printf '\\n    %s\\n\\n' \(aspas(comando))"]
        if !dica.isEmpty { l.append("echo \(aspas(dica))"); l.append("echo") }
        l += ["read -r -p \(aspas(String(localized: "Enter para rodar, Ctrl+C para cancelar. "))) _",
              "echo",
              comando,
              "codigo=$?",
              "echo",
              "if [ $codigo -eq 0 ]; then echo \(aspas(String(localized: "Pronto. Volte ao TuttiDash: a tela confere sozinha.")));"
                + " else echo \(aspas(String(localized: "Terminou com erro (código"))) $codigo')'; fi",
              "echo \(aspas(String(localized: "Pode fechar esta janela.")))"]
        return l.joined(separator: "\n") + "\n"
    }

    /// Grava o roteiro em `~/Library/Caches/TuttiDash/terminal/<id>.command` e abre no Terminal.
    @discardableResult
    public static func abrirNoTerminal(id: String, titulo: String, comando: String, dica: String = "", docs: URL? = nil,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let pasta = home.appendingPathComponent("Library/Caches/TuttiDash/terminal")
        let nome = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let arquivo = pasta.appendingPathComponent("\(nome.isEmpty ? "comando" : nome).command")
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            try roteiro(titulo: titulo, comando: comando, dica: dica, docs: docs, home: home)
                .write(to: arquivo, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: arquivo.path)
        } catch { return false }
        return codigo(["/usr/bin/open", "-a", "Terminal", arquivo.path]) == 0
    }
}
