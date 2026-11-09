import AppKit
import SwiftUI
import GastoCore

/// Wizard do norte de um projeto (PRD do norte, passo 5).
///
/// Rascunho pelo agente do Brainstorm; sem conta, o dono escolhe entre fazer login, usar o
/// Ollama ou escrever à mão. Nada é escrito no repositório antes do clique em «Abrir PR»,
/// e o merge desse PR é a permissão do dono.
@MainActor
final class EstadoWizardNorte: ObservableObject {
    enum Fase: Equatable {
        case inicio
        case rascunhando(String)
        case semConta
        case revisao
        case enviando
        case enviado(String)
    }

    enum Motor: Equatable {
        case agente
        case ollama(String)
    }

    let projeto: ProjetoCadastro
    /// Chamado quando o PR abriu (ou o norte já estava na main): o cadastro passa a apontar para ele.
    let aoGravar: () -> Void

    @Published var fase: Fase = .inicio
    @Published var markdown = ""
    @Published var perguntas: [String] = []
    @Published var respostas: [String] = []
    /// Sugestão do agente para cada pergunta. Enquanto a resposta for igual a ela, a tela marca
    /// «sugestão do agente»; vale como resposta se o dono não mudar, e some se ele apagar.
    @Published var sugestoes: [String] = []
    @Published var erro: String?
    @Published var motor: Motor?
    // Ollama
    @Published var ollamaInstalado = OllamaLocal.instalado()
    @Published var ollamaNoAr = false
    @Published var escolhaOllama: OllamaWizard.Escolha?
    @Published var baixando: Double?

    init(projeto: ProjetoCadastro, aoGravar: @escaping () -> Void) {
        self.projeto = projeto
        self.aoGravar = aoGravar
    }

    var repo: URL {
        let r = projeto.repo
        let caminho = r.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(r.dropFirst(2))).path : r
        return URL(fileURLWithPath: caminho)
    }

    var problemaDoTexto: String? { NorteProjeto.problema(markdown) }

    /// Por que o «Abrir PR» está travado, dizendo quais seções ainda estão a definir.
    var motivoTravado: String? {
        if projeto.github.isEmpty { return String(localized: "Falta o repositório do GitHub no cadastro do projeto.") }
        guard problemaDoTexto != nil else { return nil }
        let pendentes = NorteProjeto.secoesPendentes(markdown)
        if pendentes.isEmpty { return problemaDoTexto }
        return String(localized: "Ainda \(NorteRascunho.aDefinir): \(pendentes.joined(separator: ", ")). Escreva no texto ou refaça com as respostas.")
    }

    private func aplicar(_ r: NorteRascunho.Rascunho) {
        markdown = r.markdown(nome: projeto.nome)
        perguntas = r.perguntas
        sugestoes = r.perguntas.indices.map { r.sugestoes.indices.contains($0) ? r.sugestoes[$0] : "" }
        respostas = sugestoes
        fase = .revisao
    }

    private var textoRespostas: String { NorteProjeto.respostas(perguntas: perguntas, respostas: respostas) }

    func rascunharComAgente() async {
        erro = nil
        motor = .agente
        fase = .rascunhando(String(localized: "O agente do Brainstorm está lendo o repositório…"))
        do {
            aplicar(try await AgenteBrainstorm.rascunharNorte(nome: projeto.nome, repo: repo, respostas: textoRespostas))
        } catch {
            if AgenteBrainstorm.ehFaltaDeConta(error) {
                fase = .semConta
                await conferirOllama()
            } else {
                erro = error.localizedDescription
                fase = markdown.isEmpty ? .inicio : .revisao
            }
        }
    }

    func conferirOllama() async {
        ollamaInstalado = OllamaLocal.instalado()
        guard let baixados = await OllamaWizard.baixados() else {
            ollamaNoAr = false
            escolhaOllama = nil
            return
        }
        ollamaNoAr = true
        let carregados = await OllamaWizard.carregados() ?? []
        let cfg = Configuracao.lerArquivo()
        let escolhido = (Configuracao.valor(OllamaWizard.chaveModelo, em: cfg) as? String) ?? ""
        escolhaOllama = OllamaWizard.escolher(baixados: baixados, escolhido: escolhido,
                                              disponivel: OllamaWizard.memoriaDisponivelAgora(),
                                              carregados: carregados)
    }

    func rascunharComOllama() async {
        await conferirOllama()
        guard case .usar(let modelo) = escolhaOllama else { return }
        erro = nil
        motor = .ollama(modelo)
        fase = .rascunhando(String(localized: "O \(modelo) está escrevendo o rascunho no Ollama deste Mac…"))
        let pedido = NorteRascunho.prompt(nome: projeto.nome, leitura: NorteRascunho.lerRepositorio(repo),
                                          respostas: textoRespostas)
        do {
            let bruto = try await OllamaWizard.gerar(modelo: modelo, sistema: NorteRascunho.sistema, prompt: pedido)
            guard let r = NorteRascunho.ler(bruto) else {
                erro = String(localized: "O \(modelo) respondeu fora do formato. Tente de novo ou escreva à mão.")
                fase = markdown.isEmpty ? .semConta : .revisao
                return
            }
            aplicar(r)
        } catch {
            erro = error.localizedDescription
            fase = markdown.isEmpty ? .semConta : .revisao
        }
    }

    func baixarSugerido() async {
        baixando = 0
        defer { baixando = nil }
        do {
            try await OllamaLocal.baixar(OllamaWizard.modeloSugerido) { p in
                Task { @MainActor in if let f = p.fracao { self.baixando = f } }
            }
        } catch {
            erro = error.localizedDescription
        }
        await conferirOllama()
    }

    func abrirOllama() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
    }

    func escreverSemAgente() {
        erro = nil
        motor = nil
        aplicar(NorteProjeto.esqueleto)
    }

    func refazer() async {
        switch motor {
        case .ollama: await rascunharComOllama()
        case .agente: await rascunharComAgente()
        case nil: break
        }
    }

    func abrirPR() async {
        if let p = problemaDoTexto { erro = p; return }
        erro = nil
        let arquivo = FileManager.default.temporaryDirectory.appendingPathComponent("tuttidash-norte-\(UUID().uuidString).md")
        do {
            try markdown.write(to: arquivo, atomically: true, encoding: .utf8)
        } catch {
            erro = error.localizedDescription
            return
        }
        guard let cmd = NorteProjeto.comandoInstalar(projetoID: projeto.projetoID, arquivoNorte: arquivo) else {
            erro = String(localized: "O instalador do norte não está no app. Reinstale o TuttiDash.")
            return
        }
        fase = .enviando
        let r = await Task.detached {
            Subprocesso.rodar(cmd[0], Array(cmd.dropFirst()), ambiente: ProvaRemotaProjeto.ambiente)
        }.value
        try? FileManager.default.removeItem(at: arquivo)
        let texto = r.texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.codigo == 0 {
            aoGravar()
            fase = .enviado(texto)
        } else {
            erro = texto.isEmpty ? String(localized: "O instalador falhou (código \(r.codigo)).") : texto
            fase = .revisao
        }
    }
}

struct WizardNorteSheet: View {
    @StateObject var estado: EstadoWizardNorte
    @Environment(\.dismiss) private var fechar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Norte de \(estado.projeto.nome)")).font(.title3.weight(.semibold))
            Text(String(localized: "O norte diz o que o projeto é e o que não pode acontecer. Os cards do Brainstorm e as lanes se ancoram nele. Só você altera: depois do merge, nenhuma lane edita o arquivo."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = estado.erro {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            conteudo
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(enviado ? String(localized: "Fechar") : String(localized: "Cancelar")) { fechar() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 600)
    }

    private var enviado: Bool {
        if case .enviado = estado.fase { return true }
        return false
    }

    @ViewBuilder private var conteudo: some View {
        switch estado.fase {
        case .inicio:
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "O rascunho sai do que o repositório mostra (README, AGENTS.md/CLAUDE.md, manifestos, testes). O que não der para deduzir vira pergunta para você."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "Rascunhar com o agente")) { Task { await estado.rascunharComAgente() } }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Escrever sem agente")) { estado.escreverSemAgente() }
                }
            }
        case .rascunhando(let msg):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(msg).font(.callout) }
        case .semConta:
            semConta
        case .revisao:
            revisao
        case .enviando:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Gravando o norte numa branch e abrindo o PR no repositório do projeto…")).font(.callout)
            }
        case .enviado(let texto):
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Pronto. O cadastro já aponta para o norte; ele vale depois do seu merge."),
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(texto).font(.callout.monospaced()).textSelection(.enabled)
                if let url = texto.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("https://") }),
                   let link = URL(string: String(url)) {
                    Link(String(localized: "Abrir o PR"), destination: link)
                }
            }
        }
    }

    private var semConta: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Nenhum CLI do Brainstorm tem conta neste Mac. Escolha como seguir:"))
                .font(.callout.weight(.medium))
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Fazer login no Claude")).font(.callout.weight(.medium))
                    Text(String(localized: "O Terminal abre o login. Quando terminar, volte e tente de novo."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Abrir o login")) { AgenteBrainstorm.abrirLogin() }
                        Button(String(localized: "Tentar de novo")) { Task { await estado.rascunharComAgente() } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Usar o Ollama deste Mac")).font(.callout.weight(.medium))
                    ollama
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Escrever sem agente")).font(.callout.weight(.medium))
                    Text(String(localized: "Abre as cinco seções em branco para você preencher."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "Escrever à mão")) { estado.escreverSemAgente() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var ollama: some View {
        if !estado.ollamaInstalado {
            Text(String(localized: "O Ollama não está instalado. A instalação é sua; o TuttiDash não instala programas."))
                .font(.caption).foregroundStyle(.secondary)
            Link(String(localized: "Baixar o Ollama"), destination: OllamaLocal.paginaDownload)
            Button(String(localized: "Já instalei")) { Task { await estado.conferirOllama() } }
        } else if !estado.ollamaNoAr {
            Text(String(localized: "O Ollama está instalado, mas parado.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Abrir o Ollama")) { estado.abrirOllama() }
                Button(String(localized: "Conferir de novo")) { Task { await estado.conferirOllama() } }
            }
        } else if case .usar(let modelo) = estado.escolhaOllama {
            Text(String(localized: "Modelo: \(modelo). Se ele não estava carregado, sai da memória ao terminar."))
                .font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "Rascunhar com o Ollama")) { Task { await estado.rascunharComOllama() } }
        } else {
            if case .nenhum(let motivo) = estado.escolhaOllama {
                Text(motivo).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let f = estado.baixando {
                ProgressView(value: f) {
                    Text(String(localized: "Baixando o \(OllamaWizard.modeloSugerido)…")).font(.caption)
                }
            } else {
                HStack {
                    Button(String(localized: "Baixar o \(OllamaWizard.modeloSugerido) (≈5 GB)")) {
                        Task { await estado.baixarSugerido() }
                    }
                    Button(String(localized: "Conferir de novo")) { Task { await estado.conferirOllama() } }
                }
            }
        }
    }

    private var revisao: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Revise e edite. As seções 1 a 4 não podem ficar \(NorteRascunho.aDefinir)."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $estado.markdown)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if !estado.perguntas.isEmpty {
                Text(String(localized: "Perguntas do agente")).font(.callout.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(estado.perguntas.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(estado.perguntas[i]).font(.caption)
                                // TextEditor quebra a linha; o TextField vertical no macOS rolava
                                // na horizontal e cortava a sugestão.
                                TextEditor(text: $estado.respostas[i])
                                    .font(.callout)
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                                    .frame(minHeight: 44, maxHeight: 76)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                if estado.sugestoes.indices.contains(i), !estado.sugestoes[i].isEmpty,
                                   estado.respostas[i] == estado.sugestoes[i] {
                                    let palpite = estado.sugestoes[i].lowercased().hasPrefix("palpite:")
                                    Text(palpite ? String(localized: "Palpite do agente, sem base no repositório: confirme, edite ou apague.")
                                                 : String(localized: "Sugestão do agente: vale como sua resposta se você não mudar."))
                                        .font(.caption2).foregroundStyle(palpite ? Color.orange : Color.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 240)
            }
            HStack {
                if estado.motor != nil, !estado.perguntas.isEmpty {
                    Button(String(localized: "Refazer com as respostas")) { Task { await estado.refazer() } }
                }
                Spacer()
                Button(String(localized: "Abrir PR no repositório")) { Task { await estado.abrirPR() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(estado.problemaDoTexto != nil || estado.projeto.github.isEmpty)
                    .help(estado.problemaDoTexto ?? String(localized: "Grava o norte, o mapa e a referência no AGENTS.md/CLAUDE.md numa branch e abre o PR. O merge é seu."))
            }
            // O motivo do botão travado fica à vista, não só na dica do mouse.
            if let motivo = estado.motivoTravado {
                Text(motivo).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
