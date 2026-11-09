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
    /// O norte em passos: o dono marca, edita e acrescenta itens; o arquivo é montado no fim.
    @Published var norte = NorteEstruturado()
    /// Passo na tela: 0…4 são as seções; 5 é «Revisar».
    @Published var passo = 0
    @Published var temRascunho = false
    /// Passo que pediu «sugerir de novo»; nil = rascunho inteiro.
    @Published var sugerindo: Int?
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

    var markdown: String { norte.markdown(nome: projeto.nome) }

    /// Por que o «Abrir PR» está travado; nil quando dá para abrir.
    var motivoTravado: String? {
        if projeto.github.isEmpty { return String(localized: "Falta o repositório do GitHub no cadastro do projeto.") }
        if let p = norte.primeiroPendente, let m = norte.pendencia(p) {
            return String(localized: "Falta no passo \(p + 1) (\(NorteEstruturado.passos[p])): \(m)")
        }
        return NorteProjeto.problema(markdown)
    }

    private func aplicar(_ r: NorteRascunho.Rascunho) {
        let novo = NorteEstruturado.de(r)
        if let p = sugerindo, temRascunho {
            norte.mesclar(passo: p, com: novo)
        } else {
            norte = novo
            passo = 0
        }
        sugerindo = nil
        temRascunho = true
        fase = .revisao
    }

    /// O que o dono já decidiu vai como «respostas do dono» quando ele pede nova sugestão.
    private var textoRespostas: String {
        temRascunho ? "Norte atual do dono (mantenha o que está aqui):\n" + markdown : ""
    }

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
                sugerindo = nil
                fase = temRascunho ? .revisao : .inicio
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
                sugerindo = nil
                fase = temRascunho ? .revisao : .semConta
                return
            }
            aplicar(r)
        } catch {
            erro = error.localizedDescription
            sugerindo = nil
            fase = temRascunho ? .revisao : .semConta
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
        norte = NorteEstruturado()
        passo = 0
        temRascunho = true
        fase = .revisao
    }

    /// Nova proposta do agente só para um passo; o que o dono marcou ou editou fica.
    func sugerirDeNovo(_ p: Int) async {
        sugerindo = p
        switch motor {
        case .ollama: await rascunharComOllama()
        case .agente: await rascunharComAgente()
        case nil: sugerindo = nil
        }
    }

    func abrirPR() async {
        if let p = motivoTravado { erro = p; return }
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
        .frame(width: 760, height: 660)
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

    // MARK: - Passos

    private var titulosPassos: [String] { NorteEstruturado.passos + [String(localized: "Revisar")] }

    private var revisao: some View {
        VStack(alignment: .leading, spacing: 10) {
            barraPassos
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("\(estado.passo + 1). \(titulosPassos[estado.passo])").font(.headline)
                AjudaPasso(texto: NorteEstruturado.ajuda(estado.passo))
                Spacer()
                if estado.passo < 5, estado.motor != nil {
                    if estado.sugerindo == estado.passo {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Sugerir de novo")) { Task { await estado.sugerirDeNovo(estado.passo) } }
                            .help(String(localized: "Nova proposta do agente só para este passo. O que você marcou ou editou fica."))
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if estado.passo == 0 {
                        objetivo
                    } else if estado.passo < 5 {
                        lista(estado.passo)
                    } else {
                        Text(estado.markdown)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if estado.passo < 5 { perguntasDoPasso(estado.passo) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            rodapePasso
        }
    }

    private var barraPassos: some View {
        HStack(spacing: 4) {
            ForEach(titulosPassos.indices, id: \.self) { i in
                let pronto = i < 5 && estado.norte.pendencia(i) == nil
                Button {
                    estado.passo = i
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: i == 5 ? "doc.text" : (pronto ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(pronto ? Color.green : Color.secondary)
                        Text(titulosPassos[i]).lineLimit(1)
                    }
                    .font(.caption.weight(i == estado.passo ? .semibold : .regular))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(i == estado.passo ? Color.accentColor.opacity(0.18) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var objetivo: some View {
        TextEditor(text: Binding(get: { estado.norte.objetivo },
                                 set: { estado.norte.objetivo = $0; estado.norte.objetivoEditado = true }))
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 90, maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private func lista(_ p: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if estado.norte.itens[p].isEmpty {
                Text(String(localized: "Nenhum item ainda. Adicione abaixo ou use uma pergunta do agente."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($estado.norte.itens[p]) { $item in
                LinhaItem(item: $item, ordenado: p == 2,
                          subir: { mover(p, item.id, -1) }, descer: { mover(p, item.id, 1) },
                          remover: { estado.norte.itens[p].removeAll { $0.id == item.id } })
            }
            Button {
                estado.norte.itens[p].append(.init(texto: "", marcado: true, editado: true))
            } label: { Label(String(localized: "Adicionar"), systemImage: "plus") }
                .buttonStyle(.borderless)
        }
    }

    private func mover(_ p: Int, _ id: UUID, _ delta: Int) {
        guard let i = estado.norte.itens[p].firstIndex(where: { $0.id == id }),
              estado.norte.itens[p].indices.contains(i + delta) else { return }
        estado.norte.itens[p].swapAt(i, i + delta)
    }

    @ViewBuilder private func perguntasDoPasso(_ p: Int) -> some View {
        let abertas = estado.norte.perguntas.filter { $0.passo == p && !$0.resolvida }
        if !abertas.isEmpty {
            Text(String(localized: "Perguntas do agente sobre este passo")).font(.callout.weight(.medium)).padding(.top, 4)
            ForEach(abertas) { q in
                PerguntaPasso(pergunta: q) { texto in estado.norte.responder(q.id, com: texto) }
            }
        }
    }

    private var rodapePasso: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button(String(localized: "‹ Voltar")) { estado.passo -= 1 }.disabled(estado.passo == 0)
                Spacer()
                if estado.passo < 5 {
                    Button(String(localized: "Próximo ›")) { estado.passo += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(estado.norte.pendencia(estado.passo) != nil)
                } else {
                    Button(String(localized: "Abrir PR no repositório")) { Task { await estado.abrirPR() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(estado.motivoTravado != nil)
                }
            }
            // O motivo do botão travado fica à vista.
            if estado.passo < 5, let m = estado.norte.pendencia(estado.passo) {
                Text(m).font(.caption).foregroundStyle(.orange)
            } else if estado.passo == 5, let m = estado.motivoTravado {
                Text(m).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}


/// Um item de passo: marcar, editar, origem, ordem (no Desempate) e remover.
private struct LinhaItem: View {
    @Binding var item: NorteEstruturado.Item
    var ordenado: Bool
    var subir: () -> Void
    var descer: () -> Void
    var remover: () -> Void
    @State private var editando = false
    @State private var rascunho = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $item.marcado).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                // Text quebra a linha; a edição é num TextEditor (o TextField vertical cortava no macOS).
                if editando || item.texto.isEmpty {
                    TextEditor(text: $rascunho)
                        .font(.callout).scrollContentBackground(.hidden).padding(4)
                        .frame(minHeight: 44, maxHeight: 90)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Button(String(localized: "OK")) {
                        item.texto = rascunho.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.editado = true
                        editando = false
                    }
                    .disabled(rascunho.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text(item.texto).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.palpite && !item.editado {
                    Text(String(localized: "palpite: o agente não achou isto no repositório")).font(.caption2).foregroundStyle(.orange)
                } else if let f = item.fonte, !item.editado {
                    Text(String(localized: "fonte: \(f)")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if ordenado {
                Button(action: subir) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button(action: descer) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            }
            if !editando, !item.texto.isEmpty {
                Button { rascunho = item.texto; editando = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(String(localized: "Editar"))
            }
            Button(action: remover) { Image(systemName: "trash") }.buttonStyle(.borderless)
                .help(String(localized: "Remover"))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(item.marcado ? 1 : 0.4)))
    }
}

/// Pergunta do agente no passo que ela resolve: usar a sugestão ou responder.
private struct PerguntaPasso: View {
    let pergunta: NorteEstruturado.Pergunta
    let responder: (String) -> Void
    @State private var resposta = ""
    @State private var escrevendo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pergunta.texto).font(.callout)
            if !pergunta.sugestao.isEmpty {
                Text(pergunta.sugestao).font(.caption)
                    .foregroundStyle(pergunta.sugestao.lowercased().hasPrefix("palpite:") ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if escrevendo {
                TextEditor(text: $resposta)
                    .font(.callout).scrollContentBackground(.hidden).padding(4)
                    .frame(minHeight: 44, maxHeight: 76)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Button(String(localized: "Usar esta resposta")) { responder(resposta) }
                        .disabled(resposta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(String(localized: "Cancelar")) { escrevendo = false }
                }
            } else {
                HStack {
                    if !pergunta.sugestao.isEmpty {
                        Button(String(localized: "Usar sugestão")) {
                            let s = pergunta.sugestao
                            responder(s.lowercased().hasPrefix("palpite:") ? String(s.dropFirst("palpite:".count)) : s)
                        }
                    }
                    Button(String(localized: "Responder")) { resposta = ""; escrevendo = true }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

/// O (?) de cada passo.
private struct AjudaPasso: View {
    let texto: String
    @State private var aberto = false

    var body: some View {
        Button { aberto.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless)
            .help(String(localized: "O que é este passo"))
            .popover(isPresented: $aberto, arrowEdge: .bottom) {
                Text(texto).font(.callout).padding(12).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            }
    }
}
