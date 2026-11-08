import AppKit
import SwiftUI
import GastoCore

/// Chat, idéia e cards do Brainstorm. Vive fora da página: trocar de tela não zera.
/// Só «Limpar tudo» apaga o chat e a idéia. Os cards têm a limpeza deles.
final class SessaoBrainstorm: ObservableObject {
    static let textoInicial = "Descreva a ideia. Eu aponto o furo e proponho itens para a caixa de baixo."
    static let compartilhada = SessaoBrainstorm()

    @Published var messages: [ChatMessage]
    /// Sobe ao limpar. Respostas que ainda estão no ar não reescrevem o chat nem a idéia.
    @Published var conversaGeracao = 0
    @Published var chatInput = ""
    @Published var ideaSummary = ""
    @Published var stories: [UserStory] = []
    @Published var isGenerating = false
    @Published var status = "Pronto"
    @Published var projectId = ""
    @Published var projectName = ""
    @Published var editingStory: UserStory?
    /// Perguntas cuja resposta ainda não voltou.
    @Published var perguntasEmVoo = 0
    /// O agente de reescrita está compondo a idéia.
    @Published var reescrevendo = false
    @Published var precisaLogin = false
    /// Quantas mensagens do chat já entraram no esboço. O que vier depois acrescenta.
    @Published var mensagensNaIdeia = 0
    /// Itens marcados que já foram para o esboço.
    @Published var itensNaIdeia: Set<String> = []

    private init() {
        messages = [ChatMessage(isAgent: true, text: Self.textoInicial)]
        let cfg = Configuracao.resolver()
        if let p = cfg.projetoPadrao {
            projectId = p.projetoID
            projectName = p.nome
        }
    }
}

/// Tela nativa de Brainstorm no painel do TuttiDash.
/// Fluxo: chat (itens) → idéia reescrita → histórias → Linear.
struct PaginaBrainstorm: View {
    var modelo: ModeloNotch
    @ObservedObject private var sessao = SessaoBrainstorm.compartilhada

    private static let textoInicial = SessaoBrainstorm.textoInicial

    private var messages: [ChatMessage] {
        get { sessao.messages }
        nonmutating set { sessao.messages = newValue }
    }
    private var conversaGeracao: Int {
        get { sessao.conversaGeracao }
        nonmutating set { sessao.conversaGeracao = newValue }
    }
    private var chatInput: String {
        get { sessao.chatInput }
        nonmutating set { sessao.chatInput = newValue }
    }
    private var ideaSummary: String {
        get { sessao.ideaSummary }
        nonmutating set { sessao.ideaSummary = newValue }
    }
    private var stories: [UserStory] {
        get { sessao.stories }
        nonmutating set { sessao.stories = newValue }
    }
    private var isGenerating: Bool {
        get { sessao.isGenerating }
        nonmutating set { sessao.isGenerating = newValue }
    }
    private var status: String {
        get { sessao.status }
        nonmutating set { sessao.status = newValue }
    }
    private var projectId: String {
        get { sessao.projectId }
        nonmutating set { sessao.projectId = newValue }
    }
    private var projectName: String {
        get { sessao.projectName }
        nonmutating set { sessao.projectName = newValue }
    }
    private var editingStory: UserStory? {
        get { sessao.editingStory }
        nonmutating set { sessao.editingStory = newValue }
    }
    private var perguntasEmVoo: Int {
        get { sessao.perguntasEmVoo }
        nonmutating set { sessao.perguntasEmVoo = newValue }
    }
    private var reescrevendo: Bool {
        get { sessao.reescrevendo }
        nonmutating set { sessao.reescrevendo = newValue }
    }
    private var precisaLogin: Bool {
        get { sessao.precisaLogin }
        nonmutating set { sessao.precisaLogin = newValue }
    }

    private var lanes: [String] { Agentes.ordemPainelLanes }

    init(modelo: ModeloNotch) {
        self.modelo = modelo
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    passosFluxo
                    chatSection
                    ideaSection
                    gerarBar
                    storiesSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            .background(PV.fundo)

            if !stories.isEmpty {
                footerBar
            }
        }
        .sheet(item: $sessao.editingStory) { story in
            let nova = !stories.contains { $0.id == story.id }
            EditStorySheet(story: story, lanes: lanes, criando: nova, onSave: { updated in
                if let updated {
                    if let index = stories.firstIndex(where: { $0.id == updated.id }) {
                        stories[index] = updated
                    } else {
                        stories.insert(updated, at: 0)
                    }
                }
                editingStory = nil
            }, onRemove: {
                removeStory(story.id)
                editingStory = nil
            })
        }
    }

    // MARK: - Passos

    private var passoAtual: Int {
        if stories.contains(where: \.approved) { return 3 }
        if !stories.isEmpty { return 2 }
        if !ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 1 }
        return 1
    }

    private var passosFluxo: some View {
        HStack(spacing: 8) {
            passo(1, "Ideia")
            chevron
            passo(2, "Histórias")
            chevron
            passo(3, "Linear")
            Spacer(minLength: 8)
            if !projectName.isEmpty {
                Text(projectName)
                    .fontePainel(11)
                    .foregroundStyle(PV.mudo)
                    .lineLimit(1)
            }
            Button("Limpar tudo") { limparConversa() }
                .buttonStyle(.plain)
                .fontePainel(12, .semibold)
                .foregroundStyle(PV.vermelho)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(PV.apagado)
    }

    private func passo(_ n: Int, _ titulo: String) -> some View {
        let ativo = passoAtual >= n
        return HStack(spacing: 6) {
            Text("\(n)")
                .fontePainel(10, .bold)
                .foregroundStyle(ativo ? Color.white : PV.mudo)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ativo ? PV.azul : PV.tag))
            Text(titulo)
                .fontePainel(12, ativo ? .semibold : .regular)
                .foregroundStyle(ativo ? PV.texto : PV.mudo)
        }
    }

    // MARK: - Ideia

    private var ideaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Idéia")
                    .fontePainel(13, .semibold)
                    .foregroundStyle(PV.mudo)
                Spacer()
                if reescrevendo {
                    EfeitoThinking()
                } else {
                    Text(status)
                        .fontePainel(10)
                        .foregroundStyle(PV.apagado)
                        .lineLimit(1)
                }
            }
            Text("Gerar idéia no chat reúne a conversa e os itens marcados. Continuar o chat e gerar de novo acrescenta. A caixa continua editável.")
                .fontePainel(11)
                .foregroundStyle(PV.mudo)

            TextEditor(text: $sessao.ideaSummary)
                .fontePainel(13)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(PV.campo))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PV.campoBorda, lineWidth: 1))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.cartao))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PV.cartaoBorda, lineWidth: 1))
    }

    // MARK: - Chat (auxiliar)

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Chat")
                    .fontePainel(13, .semibold)
                    .foregroundStyle(PV.mudo)
                Spacer(minLength: 8)
                Button("Entrar no Claude") { AgenteBrainstorm.abrirLogin() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(precisaLogin ? PV.ambar : PV.azul)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { msg in
                        HStack {
                            if msg.isAgent {
                                agentBubble(msg)
                                Spacer(minLength: 24)
                            } else {
                                Spacer(minLength: 24)
                                userBubble(msg.text)
                            }
                        }
                    }
                    if perguntasEmVoo > 0 {
                        HStack {
                            EfeitoThinking()
                            Spacer(minLength: 24)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["Explorar riscos", "Quais fluxos principais?", "Simplificar escopo", "Métricas de sucesso"], id: \.self) { q in
                        Button(q) { enviar(texto: q) }
                            .fontePainel(10)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                            .foregroundStyle(PV.mudo)
                            .disabled(perguntasEmVoo > 0)
                    }
                }
            }

            Button(action: gerarIdeia) {
                HStack {
                    if reescrevendo { ProgressView().controlSize(.small) }
                    Text(reescrevendo ? "Gerando idéia…" : "Gerar idéia")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PV.azul)
            .disabled(!podeGerarIdeia)

            HStack(spacing: 8) {
                TextField("Pergunte ou descreva a ideia…", text: $sessao.chatInput)
                    .textFieldStyle(.plain)
                    .fontePainel(13)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PV.campo))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PV.campoBorda, lineWidth: 1))
                    .onSubmit { enviar(texto: nil) }

                Button { enviar(texto: nil) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(PV.azul)
                }
                .disabled(perguntasEmVoo > 0 || chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.cartao))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PV.cartaoBorda, lineWidth: 1))
    }

    /// Palavra “Thinking” com um brilho que atravessa as letras, como no chat do Cursor.
    private struct EfeitoThinking: View {
        private var rotulo: some View {
            Text("Thinking").fontePainel(14, .medium)
        }

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { contexto in
                let ciclo = 1.6
                let fase = contexto.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: ciclo) / ciclo
                rotulo
                    .foregroundStyle(PV.apagado)
                    .overlay {
                        GeometryReader { geo in
                            let largura = geo.size.width
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.92), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: largura * 0.5)
                            .offset(x: -largura * 0.35 + CGFloat(fase) * largura * 1.45)
                        }
                        .mask(rotulo.foregroundStyle(Color.white))
                    }
            }
            .accessibilityLabel("Thinking")
        }
    }

    private func agentBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(msg.text)
                .fontePainel(12)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(PV.interno))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(PV.linhaBorda, lineWidth: 1))

            if !msg.itens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(msg.itens, id: \.self) { item in
                        let marcado = msg.itensUsados.contains(item)
                        Button {
                            alternarItem(item, mensagem: msg.id)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: marcado ? "checkmark" : "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.top, 2)
                                Text(item)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .fontePainel(11)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(marcado ? PV.azulFundo : PV.tag))
                            .foregroundStyle(marcado ? PV.azul : PV.texto)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .fontePainel(12)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(PV.azulFundo))
            .foregroundStyle(PV.texto)
            .frame(maxWidth: 360, alignment: .trailing)
    }

    /// `texto` pronto (atalho). `nil` lê o campo do chat. A idéia vai no prompt, não no balão.
    private func enviar(texto: String?) {
        let ideia = ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitado = (texto ?? chatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digitado.isEmpty, perguntasEmVoo == 0 else { return }
        messages.append(ChatMessage(isAgent: false, text: digitado))
        chatInput = ""
        let historico = messages
        let historias = stories.map { "\($0.title) [\($0.esforco.rawValue)/\($0.lane)]" }
        let repo = AgenteBrainstorm.repoDoProjeto()
        let geracao = conversaGeracao
        perguntasEmVoo += 1
        Task {
            let resp: String
            do {
                resp = try await AgenteBrainstorm.responder(
                    mensagem: digitado, ideia: ideia,
                    historias: historias, historico: historico, repo: repo)
            } catch {
                resp = error.localizedDescription
            }
            await MainActor.run {
                guard geracao == conversaGeracao else { return }
                perguntasEmVoo = max(0, perguntasEmVoo - 1)
                let semSessao = resp.contains("Claude sem sessão")
                precisaLogin = semSessao
                let fala = BrainstormCLI.separarItens(resp)
                let visivel = fala.texto.isEmpty
                    ? (fala.itens.isEmpty ? resp : "Marque com + o que entra na idéia.")
                    : fala.texto
                messages.append(ChatMessage(isAgent: true, text: visivel, itens: fala.itens))
                if semSessao { AgenteBrainstorm.abrirLogin() }
            }
        }
    }

    /// O + marca ou desmarca. A idéia só muda em Gerar idéia.
    private func alternarItem(_ item: String, mensagem id: UUID) {
        guard let indice = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[indice].itensUsados.contains(item) {
            messages[indice].itensUsados.remove(item)
        } else {
            messages[indice].itensUsados.insert(item)
        }
    }

    private var itensSelecionados: [String] {
        var vistos = Set<String>()
        var lista: [String] = []
        for msg in messages {
            for item in msg.itens where msg.itensUsados.contains(item) && vistos.insert(item).inserted {
                lista.append(item)
            }
        }
        return lista
    }

    private var itensNovos: [String] {
        itensSelecionados.filter { !sessao.itensNaIdeia.contains($0) }
    }

    private func textoConversa(_ faixa: ArraySlice<ChatMessage>) -> String {
        faixa.compactMap { msg -> String? in
            if msg.isAgent, msg.itens.isEmpty, msg.text == Self.textoInicial { return nil }
            let quem = msg.isAgent ? "Agente" : "Pessoa"
            return "\(quem): \(msg.text)"
        }.joined(separator: "\n")
    }

    private var podeGerarIdeia: Bool {
        guard !reescrevendo, perguntasEmVoo == 0 else { return false }
        let inicio = min(sessao.mensagensNaIdeia, messages.count)
        let nova = textoConversa(messages[inicio...])
        return !nova.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !itensNovos.isEmpty
    }

    /// Reúne a conversa nova e os itens marcados num esboço. O que já está na caixa permanece e o resto acrescenta.
    private func gerarIdeia() {
        guard podeGerarIdeia else { return }
        let inicio = min(sessao.mensagensNaIdeia, messages.count)
        let fim = messages.count
        let conversa = textoConversa(messages[inicio..<fim])
        let novos = itensNovos
        let base = ideaSummary
        reescrevendo = true
        let geracao = conversaGeracao
        let repo = AgenteBrainstorm.repoDoProjeto()
        Task {
            let resultado: Result<String, Error>
            do {
                resultado = .success(try await AgenteBrainstorm.reescrever(
                    ideia: base, conversa: conversa, itens: novos, repo: repo))
            } catch {
                resultado = .failure(error)
            }
            await MainActor.run {
                guard geracao == conversaGeracao else { return }
                reescrevendo = false
                switch resultado {
                case .success(let texto):
                    let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
                    if limpo.isEmpty {
                        status = "O agente não devolveu a idéia"
                    } else if ideaSummary == base {
                        ideaSummary = limpo
                        sessao.mensagensNaIdeia = max(sessao.mensagensNaIdeia, fim)
                        sessao.itensNaIdeia.formUnion(novos)
                        status = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Esboço da idéia"
                            : "Idéia acrescentada"
                    } else {
                        status = "A idéia foi editada durante a geração; mantive o seu texto"
                    }
                case .failure(let error):
                    let resp = error.localizedDescription
                    let semSessao = resp.contains("Claude sem sessão")
                    precisaLogin = semSessao
                    status = resp
                    if semSessao { AgenteBrainstorm.abrirLogin() }
                }
            }
        }
    }

    /// Zera o chat e a idéia. Os cards ficam.
    private func limparConversa() {
        conversaGeracao += 1
        messages = [ChatMessage(isAgent: true, text: Self.textoInicial)]
        chatInput = ""
        ideaSummary = ""
        perguntasEmVoo = 0
        reescrevendo = false
        precisaLogin = false
        status = "Pronto"
        sessao.mensagensNaIdeia = 0
        sessao.itensNaIdeia = []
    }

    // MARK: - Gerar

    private var gerarBar: some View {
        Button(action: generateStories) {
            HStack {
                if isGenerating { ProgressView().controlSize(.small) }
                Text(isGenerating ? "Gerando histórias…" : "Gerar histórias")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(PV.azul)
        .disabled(ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || reescrevendo)
        .padding(.horizontal, 4)
    }

    // MARK: - Histórias

    private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Histórias")
                    .fontePainel(13, .semibold)
                Text("\(stories.count)")
                    .fontePainel(10)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                if !stories.isEmpty {
                    Text("\(stories.filter(\.approved).count) marcadas")
                        .fontePainel(10)
                        .foregroundStyle(PV.mudo)
                }
                Spacer()
                Button("Adicionar") { novaHistoria() }
                    .fontePainel(11)
            }

            Text("Cards no quadro. Clique para editar. Esforço e lane são as etiquetas do Linear.")
                .fontePainel(11)
                .foregroundStyle(PV.mudo)

            if stories.isEmpty {
                VStack(spacing: 12) {
                    Text("Nenhuma história ainda")
                        .fontePainel(13, .semibold)
                        .foregroundStyle(PV.mudo)
                    Text("Aceite itens no chat ou escreva a idéia, depois gere.")
                        .fontePainel(11)
                        .foregroundStyle(PV.mudo)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(PV.cartao))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PV.cartaoBorda, lineWidth: 1))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach($sessao.stories) { $story in
                        kanbanCard(story: $story)
                    }
                }
            }
        }
    }

    private func kanbanCard(story: Binding<UserStory>) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                editingStory = story.wrappedValue
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(story.wrappedValue.title)
                        .fontePainel(13, .semibold)
                        .foregroundStyle(PV.texto)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 22)
                    Text(story.wrappedValue.description)
                        .fontePainel(11)
                        .foregroundStyle(PV.texto2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        tag(text: "P\(story.wrappedValue.priority)", destaque: false)
                        tag(text: "\(story.wrappedValue.estimate) pts", destaque: false)
                        tag(text: story.wrappedValue.esforco.rotuloTag, destaque: true)
                        tag(text: story.wrappedValue.lane, destaque: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(PV.cartao))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(
                        story.approved.wrappedValue ? PV.verde.opacity(0.55) : PV.cartaoBorda,
                        lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                story.approved.wrappedValue.toggle()
            } label: {
                Image(systemName: story.approved.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(story.approved.wrappedValue ? PV.verde : PV.mudo)
                    .font(.system(size: 16))
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help(story.approved.wrappedValue ? "Desmarcar" : "Marcar")
        }
    }

    private func tag(text: String, destaque: Bool) -> some View {
        Text(text)
            .fontePainel(10, destaque ? .semibold : .regular)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(destaque ? PV.azulFundo : PV.tag))
            .foregroundStyle(destaque ? PV.azul : PV.mudo)
    }

    // MARK: - Rodapé

    private var haMarcadas: Bool { stories.contains(where: \.approved) }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button("Aprovar", action: insertApprovedIntoLinear)
                .buttonStyle(.borderedProminent)
                .tint(PV.verde)
                .disabled(!haMarcadas || isGenerating)
            Button("Remover", action: removerMarcadas)
                .buttonStyle(.bordered)
                .foregroundStyle(PV.vermelho)
                .disabled(!haMarcadas || isGenerating)
            Button("Marcar todas") { for i in stories.indices { stories[i].approved = true } }
                .buttonStyle(.bordered)
            Button("Desmarcar todas") { for i in stories.indices { stories[i].approved = false } }
                .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Text(status)
                .fontePainel(11)
                .foregroundStyle(PV.mudo)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(PV.lateral)
    }

    // MARK: - Ações

    private func generateStories() {
        let trimmed = ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let etiquetas = Self.etiquetasDoProcesso()
        guard !etiquetas.isEmpty else {
            status = "Nenhuma lane com esforço no catálogo"
            return
        }
        isGenerating = true
        status = "Gerando…"
        let geracao = conversaGeracao
        let repo = AgenteBrainstorm.repoDoProjeto()

        Task {
            let resultado: Result<[BrainstormCLI.HistoriaGerada], Error>
            do {
                let lista = try await AgenteBrainstorm.gerarHistorias(ideia: trimmed, etiquetas: etiquetas, repo: repo)
                resultado = .success(lista)
            } catch {
                resultado = .failure(error)
            }
            await MainActor.run {
                isGenerating = false
                switch resultado {
                case .success(let lista):
                    let cards = lista.compactMap { Self.story(de: $0) }
                    guard !cards.isEmpty else {
                        status = "O agente não devolveu histórias da idéia"
                        return
                    }
                    stories = cards
                    status = "\(cards.count) histórias com as etiquetas do processo"
                    guard geracao == conversaGeracao else { return }
                    messages.append(ChatMessage(
                        isAgent: true,
                        text: "Histórias da idéia, cada uma com esforço e lane do catálogo. Marque as que seguem."))
                case .failure(let error):
                    let resp = error.localizedDescription
                    let semSessao = resp.contains("Claude sem sessão")
                    precisaLogin = semSessao
                    status = resp
                    if semSessao { AgenteBrainstorm.abrirLogin() }
                }
            }
        }
    }

    /// Lanes do painel que têm modelo para baixo, medio ou alto. Habilitadas, quando houver.
    private static func etiquetasDoProcesso() -> [BrainstormCLI.EtiquetaLane] {
        let pares = CatalogoAgentes.carregar().compactMap { agente -> (nome: String, esforcos: [String])? in
            guard agente.painel else { return nil }
            let es = BrainstormCLI.niveisEsforco.filter { agente.modelos[$0] != nil }
            guard !es.isEmpty else { return nil }
            return (agente.nome, es)
        }
        let hab = LanesHabilitadas.ler(stateDir: Configuracao.resolver().stateDir)
        return BrainstormCLI.etiquetas(lanes: pares, habilitadas: hab)
    }

    private static func story(de g: BrainstormCLI.HistoriaGerada) -> UserStory? {
        guard let esforco = EsforcoHistoria(rawValue: g.esforco) else { return nil }
        return UserStory(
            title: g.titulo,
            description: g.descricao,
            acceptanceCriteria: g.criterios,
            priority: g.prioridade,
            estimate: g.estimativa,
            esforco: esforco,
            lane: g.lane,
            approved: false)
    }

    private func novaHistoria() {
        editingStory = UserStory(
            title: "",
            description: "",
            acceptanceCriteria: [],
            priority: 3, estimate: 3,
            esforco: .medio, lane: lanes.first ?? "claude",
            approved: false)
    }

    private func removeStory(_ id: UUID) {
        stories.removeAll { $0.id == id }
    }

    private func removerMarcadas() {
        let antes = stories.count
        stories.removeAll(where: \.approved)
        let sairam = antes - stories.count
        status = sairam == 0 ? "Nenhuma marcada" : "\(sairam) card(s) removidos"
    }

    private func insertApprovedIntoLinear() {
        let approved = stories.filter(\.approved)
        guard !approved.isEmpty else {
            status = "Nenhuma aprovada"
            CentralAvisos.compartilhada.info("Nenhuma história aprovada")
            return
        }
        guard !projectId.isEmpty else {
            status = "Cadastre um projeto em Ajustes"
            CentralAvisos.compartilhada.erro("Sem projeto Linear", "Defina o projeto padrão em Ajustes › Projetos.")
            return
        }

        isGenerating = true
        status = "Enviando \(approved.count)…"

        Task {
            let timeId: String
            do {
                timeId = try await Self.timeDoProjeto(projectId)
            } catch {
                await MainActor.run {
                    isGenerating = false
                    status = "Falha no envio"
                    CentralAvisos.compartilhada.erro("Nada foi criado", error.localizedDescription)
                }
                return
            }
            let ids = Self.idsLinear(projetoID: projectId)
            guard let stateTodo = ids.todo, !stateTodo.isEmpty else {
                await MainActor.run {
                    isGenerating = false
                    status = "Cache linear-ids sem estado Todo"
                    CentralAvisos.compartilhada.erro("IDs do Linear incompletos", "Rode o dispatcher uma vez ou confira ~/.transcentia/lanes/linear-ids.")
                }
                return
            }

            var okIds: [UUID] = []
            var falhas: [String] = []
            for s in approved {
                var labelIds: [String] = []
                if let e = ids.esforco[s.esforco.rawValue] { labelIds.append(e) }
                if let l = ids.lanes[s.lane] { labelIds.append(l) }
                if labelIds.count < 2 {
                    falhas.append("\(s.title): faltam IDs de \(s.esforco.rawValue)/\(s.lane)")
                    continue
                }
                let input: [String: Any] = [
                    "title": s.title,
                    "description": s.descricaoLinear,
                    "projectId": projectId,
                    "teamId": timeId,
                    "stateId": stateTodo,
                    "priority": min(max(s.priority, 1), 4),
                    "estimate": s.estimate,
                    "labelIds": labelIds,
                ]
                do {
                    try await Self.criarIssue(input: input)
                    okIds.append(s.id)
                } catch {
                    falhas.append("\(s.title): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                isGenerating = false
                if !okIds.isEmpty {
                    let enviados = Set(okIds)
                    stories.removeAll { enviados.contains($0.id) }
                    status = falhas.isEmpty
                        ? "\(okIds.count) cards no Linear"
                        : "\(okIds.count) ok, \(falhas.count) falha(s)"
                    CentralAvisos.compartilhada.ok(
                        "\(okIds.count) card(s) no Linear",
                        falhas.isEmpty ? nil : falhas.joined(separator: "\n"))
                } else {
                    status = "Falha no envio"
                    CentralAvisos.compartilhada.erro("Nada foi criado", falhas.joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - Linear / proxy

    private struct IdsBrainstorm {
        var todo: String?
        var esforco: [String: String]
        var lanes: [String: String]
    }

    private static func idsLinear(projetoID: String) -> IdsBrainstorm {
        let config = Configuracao.lerArquivo()
        let cacheURL = CaixaDono.caminhoCacheIds(projetoID: projetoID)
        var cache = CaixaDono.lerCacheIds(cacheURL)
        if cache.isEmpty {
            cache = CaixaDono.lerCacheIds(CaixaDono.caminhoCacheIds(projetoID: ""))
        }
        let ids = CaixaDono.idsDoApp(config: config, cache: cache, rotuloDono: "needs:dono")
        let estadosCache = (cache["estados"] as? [String: Any]) ?? [:]
        let todoCfg = (Configuracao.valor("linear.state_todo_id", em: config) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let todo = todoCfg.isEmpty ? (estadosCache["todo"] as? String) : todoCfg
        return IdsBrainstorm(todo: todo, esforco: ids.esforco, lanes: ids.lanes)
    }

    /// O `issueCreate` do Linear exige o time. O projeto padrão aponta para ele.
    private static func timeDoProjeto(_ projetoID: String) async throws -> String {
        let data = try await pedirProxy(op: "time_do_projeto", variaveis: ["id": projetoID])
        let nos = (((data["project"] as? [String: Any])?["teams"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let id = (nos.first?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { throw ErroLinear.resposta("O projeto não tem um time no Linear") }
        return id
    }

    private static func criarIssue(input: [String: Any]) async throws {
        let data = try await pedirProxy(op: "criar_issue", variaveis: ["input": input])
        let criado = data["issueCreate"] as? [String: Any]
        if criado?["success"] as? Bool == false {
            throw ErroLinear.resposta("O Linear não criou o card")
        }
    }

    private static func pedirProxy(op: String, variaveis: [String: Any]) async throws -> [String: Any] {
        let candidatos: [URL] = [
            ScriptsDoBundle.modulosAssinados(),
            Bundle.main.resourceURL?.appendingPathComponent("controle/gasto_lanes"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Developer/tuttidash/gasto_lanes"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("gasto_lanes"),
        ].compactMap { $0 }
        guard let pasta = candidatos.first(where: {
            FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("proxy_linear.py").path)
        }) else {
            throw ErroLinear.resposta("proxy_linear.py não encontrado no bundle")
        }

        let payload = try JSONSerialization.data(withJSONObject: ["op": op, "variaveis": variaveis])
        guard let payloadTexto = String(data: payload, encoding: .utf8) else {
            throw ErroLinear.resposta("JSON inválido")
        }

        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        from proxy_linear import pedir, ErroProxy
        try:
            pedido = json.loads(sys.argv[2])
            data = pedir(pedido["op"], pedido.get("variaveis") or {})
            print(json.dumps({"ok": True, "data": data}, ensure_ascii=False))
        except ErroProxy as e:
            print(json.dumps({"ok": False, "erro": str(e)}, ensure_ascii=False))
            sys.exit(2)
        except Exception as e:
            print(json.dumps({"ok": False, "erro": str(e)}, ensure_ascii=False))
            sys.exit(1)
        """

        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        processo.arguments = ["-c", script, pasta.path, payloadTexto]
        let pipe = Pipe()
        processo.standardOutput = pipe
        processo.standardError = pipe
        try processo.run()
        processo.waitUntilExit()
        let dados = pipe.fileHandleForReading.readDataToEndOfFile()
        let obj = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any]
        if processo.terminationStatus != 0 || obj?["ok"] as? Bool != true {
            let msg = (obj?["erro"] as? String) ?? String(data: dados, encoding: .utf8) ?? "falha no proxy"
            throw ErroLinear.resposta(msg)
        }
        guard let data = obj?["data"] as? [String: Any] else {
            throw ErroLinear.resposta("resposta do proxy sem data")
        }
        return data
    }
}

// MARK: - Agente

/// Lane preferida do revisor (`revisores.pr.lane`), só leitura.
/// A primeira resposta abre uma sessão; a seguinte retoma essa sessão.
/// Sem login no Claude, o OpenCode responde e a pergunta seguinte não espera o Claude de novo.
enum AgenteBrainstorm {
    enum Falha: LocalizedError {
        case semRepo
        case semClaude
        case vazio
        case semLogin
        case saida(Int32, String)

        var errorDescription: String? {
            switch self {
            case .semRepo:
                return "Sem pasta do projeto. Defina o repositório em Ajustes › Projetos."
            case .semClaude:
                return "Nenhum CLI de leitura no PATH (lane do revisor nem opencode)."
            case .vazio:
                return "O agente não devolveu texto."
            case .semLogin:
                return "Claude sem sessão e o OpenCode não respondeu. O Terminal abre o login. Quando terminar, envie de novo."
            case .saida(let c, let detalhe):
                let linha = detalhe.split(separator: "\n").first.map(String.init) ?? detalhe
                return "Agente (código \(c)): \(linha)"
            }
        }
    }

    /// CLI que já respondeu neste processo, e o id da sessão dele nesse repositório.
    /// Chat, reescrita e histórias guardam sessões separadas.
    private struct Memoria {
        var repo: String
        var cli: String
        var sessao: String?
    }

    private static let trava = NSLock()
    private static var memoriaConversa: Memoria?
    private static var memoriaReescrita: Memoria?
    private static var memoriaHistorias: Memoria?
    /// Claude sem login, ou o binário recusou o comando. Não entra nas próximas perguntas.
    private static var claudeFora = false

    static func repoDoProjeto() -> URL? {
        let cru = Configuracao.resolver().projetoPadrao?.repo
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cru.isEmpty else { return nil }
        let caminho = (cru as NSString).expandingTildeInPath
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: caminho, isDirectory: &dir), dir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: caminho, isDirectory: true)
    }

    static func responder(mensagem: String, ideia: String, historias: [String],
                          historico: [ChatMessage], repo: URL?) async throws -> String {
        guard let repo else { throw Falha.semRepo }
        let fala = historico.map { (agente: $0.isAgent, texto: $0.text) }
        let completo = BrainstormCLI.prompt(mensagem: mensagem, ideia: ideia, historias: historias,
                                             historico: fala, retomando: false)
        let curto = BrainstormCLI.prompt(mensagem: mensagem, ideia: ideia, historias: historias,
                                          historico: fala, retomando: true)
        let preferida = cliPreferido()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try responderSync(repo: repo, preferida: preferida,
                                                              completo: completo, curto: curto,
                                                              papel: .conversa))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Agente à parte: só reescreve a idéia. A sessão dele não é a do chat.
    static func reescrever(ideia: String, conversa: String, itens: [String], repo: URL?) async throws -> String {
        guard let repo else { throw Falha.semRepo }
        let pedido = BrainstormCLI.promptReescrita(ideia: ideia, conversa: conversa, itens: itens)
        let preferida = cliPreferido()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let bruto = try responderSync(repo: repo, preferida: preferida,
                                                   completo: pedido, curto: pedido,
                                                   papel: .reescrita)
                    cont.resume(returning: BrainstormCLI.textoReescrito(bruto))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Agente à parte: quebra a idéia em histórias e só aceita pares lane/esforço do catálogo.
    static func gerarHistorias(ideia: String, etiquetas: [BrainstormCLI.EtiquetaLane],
                               repo: URL?) async throws -> [BrainstormCLI.HistoriaGerada] {
        guard let repo else { throw Falha.semRepo }
        let pedido = BrainstormCLI.promptHistorias(ideia: ideia, etiquetas: etiquetas)
        let preferida = cliPreferido()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let bruto = try responderSync(repo: repo, preferida: preferida,
                                                   completo: pedido, curto: pedido,
                                                   papel: .historias)
                    cont.resume(returning: BrainstormCLI.historias(de: bruto, etiquetas: etiquetas))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Uma resposta, um CLI. O outro só entra se o primeiro não tem sessão ou recusou
    /// o comando. Erro depois de rodar não dispara outro agente.
    private static func responderSync(repo: URL, preferida: String, completo: String, curto: String,
                                      papel: BrainstormCLI.Papel) throws -> String {
        let foto = lerMemoria(repo: repo.path, papel: papel)
        let ordem = BrainstormCLI.fila(preferida: preferida, escolhida: foto.cli, claudeFora: foto.claudeFora)
        var ultima: Error = Falha.semClaude
        var pediuLogin = false
        var encerrar = false
        for cli in ordem {
            guard let bin = binario(cli) else { continue }
            if cli == "claude", foto.cli != "claude", claudeDeslogado(bin) {
                marcarClaudeFora()
                pediuLogin = true
                ultima = Falha.semLogin
                continue
            }
            let sessao = foto.cli == cli ? foto.sessao : nil
            do {
                return try umaVez(cli: cli, bin: bin, repo: repo,
                                  prompt: sessao == nil ? completo : curto, sessao: sessao, papel: papel)
            } catch {
                switch classificar(error, tinhaSessao: sessao != nil) {
                case .recomecar:
                    do {
                        return try umaVez(cli: cli, bin: bin, repo: repo, prompt: completo, sessao: nil, papel: papel)
                    } catch {
                        ultima = error
                        if ehSemLogin(error) {
                            pediuLogin = true
                            if cli == "claude" { marcarClaudeFora() }
                            continue
                        }
                        encerrar = true
                    }
                case .proximo:
                    ultima = error
                    if ehSemLogin(error) {
                        pediuLogin = true
                        if cli == "claude" { marcarClaudeFora() }
                    } else if cli == "claude", BrainstormCLI.flagDesconhecida(texto(de: error)) {
                        marcarClaudeFora()
                    }
                case .parar:
                    ultima = error
                    encerrar = true
                }
            }
            if encerrar { break }
        }
        if pediuLogin { abrirLogin() }
        throw pediuLogin ? Falha.semLogin : ultima
    }

    private static func umaVez(cli: String, bin: String, repo: URL, prompt: String, sessao: String?,
                               papel: BrainstormCLI.Papel) throws -> String {
        let saida = try executar(cli: cli, bin: bin, repo: repo, prompt: prompt, sessao: sessao, papel: papel)
        let id = BrainstormCLI.sessaoUtil(saida.sessao) ?? BrainstormCLI.sessaoUtil(sessao)
        lembrar(repo: repo.path, cli: cli, sessao: id, papel: papel)
        return saida.texto
    }

    private static func cliPreferido() -> String {
        let arquivo = Configuracao.lerArquivo()
        let nome = (Configuracao.valor("revisores.pr.lane", em: arquivo) as? String) ?? "claude"
        let agente = CatalogoAgentes.carregar().first { $0.nome == nome }
        let cli = agente?.cli?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cli.isEmpty ? nome : cli
    }

    /// Abre o Terminal num `.command`. Não usa AppleScript: o app não tem permissão para controlar o Terminal.
    static func abrirLogin() {
        let claude = caminhoClaude()
        let script = """
        #!/bin/bash
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        clear
        echo "Login do Claude para o Brainstorm"
        echo "O navegador abre em seguida. Quando acabar, volte ao TuttiDash e envie de novo."
        echo
        exec "\(claude)" auth login --claudeai
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TuttiDash-login-claude.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    private static func caminhoClaude() -> String {
        binario("claude") ?? "\(NSHomeDirectory())/.local/bin/claude"
    }

    private static func binario(_ nome: String) -> String? {
        var dirs = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        for dir in dirs {
            let candidato = (dir as NSString).appendingPathComponent(nome)
            if FileManager.default.isExecutableFile(atPath: candidato) { return candidato }
        }
        return nil
    }

    private static func semSessao(_ texto: String) -> Bool {
        let l = texto.lowercased()
        let marcas = ["not logged in", "please run /login", "unauthorized", "not authenticated",
                      "authentication required", "login required", "run /connect", "no credentials"]
        return marcas.contains { l.contains($0) }
    }

    private static func executar(cli: String, bin: String, repo: URL, prompt: String,
                                 sessao: String?, papel: BrainstormCLI.Papel) throws -> BrainstormCLI.Saida {
        let saidaCodex = cli == "codex"
            ? FileManager.default.temporaryDirectory.appendingPathComponent("brainstorm-codex-\(UUID().uuidString).txt")
            : nil
        defer { if let saidaCodex { try? FileManager.default.removeItem(at: saidaCodex) } }
        guard let chamada = BrainstormCLI.chamada(cli: cli, prompt: prompt, sessao: sessao,
                                                   saidaCodex: saidaCodex?.path, papel: papel) else {
            throw Falha.saida(127, "CLI \(cli) sem modo só leitura no brainstorm")
        }
        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: bin)
        processo.currentDirectoryURL = repo
        processo.arguments = chamada.argumentos
        var ambiente = ProcessInfo.processInfo.environment
        let prefixo = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        ambiente["PATH"] = prefixo + ":" + (ambiente["PATH"] ?? "")
        processo.environment = ambiente
        let entrada = Pipe()
        let saida = Pipe()
        let erros = Pipe()
        processo.standardInput = entrada
        processo.standardOutput = saida
        processo.standardError = erros
        try processo.run()
        let grupo = DispatchGroup()
        var dados = Data()
        var dadosErro = Data()
        grupo.enter()
        DispatchQueue.global(qos: .utility).async {
            dados = saida.fileHandleForReading.readDataToEndOfFile()
            grupo.leave()
        }
        grupo.enter()
        DispatchQueue.global(qos: .utility).async {
            dadosErro = erros.fileHandleForReading.readDataToEndOfFile()
            grupo.leave()
        }
        if let corpo = chamada.stdin?.data(using: .utf8) {
            entrada.fileHandleForWriting.write(corpo)
        }
        try? entrada.fileHandleForWriting.close()
        processo.waitUntilExit()
        grupo.wait()
        let bruto = String(data: dados, encoding: .utf8) ?? ""
        var lido = BrainstormCLI.interpretar(cli: cli, saida: bruto)
        if let saidaCodex, let gravado = try? String(contentsOf: saidaCodex, encoding: .utf8) {
            let limpo = gravado.trimmingCharacters(in: .whitespacesAndNewlines)
            if !limpo.isEmpty {
                lido.texto = limpo
                lido.erro = false
            }
        }
        let erro = String(data: dadosErro, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combinado = [lido.texto, erro].filter { !$0.isEmpty }.joined(separator: "\n")
        if processo.terminationStatus != 0 || lido.erro || semSessao(combinado) {
            if semSessao(combinado) { throw Falha.semLogin }
            throw Falha.saida(processo.terminationStatus, combinado.isEmpty ? "sem saída" : combinado)
        }
        if lido.texto.isEmpty { throw Falha.vazio }
        return lido
    }

    /// true só quando o status deixa claro que não há sessão. Timeout ou saída ambígua não pula o Claude.
    private static func claudeDeslogado(_ bin: String) -> Bool {
        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: bin)
        processo.arguments = ["auth", "status"]
        let pipe = Pipe()
        processo.standardOutput = pipe
        processo.standardError = pipe
        processo.standardInput = FileHandle.nullDevice
        guard (try? processo.run()) != nil else { return false }
        let grupo = DispatchGroup()
        grupo.enter()
        var dados = Data()
        DispatchQueue.global(qos: .utility).async {
            dados = pipe.fileHandleForReading.readDataToEndOfFile()
            grupo.leave()
        }
        if grupo.wait(timeout: .now() + 4) == .timedOut {
            if processo.isRunning { processo.terminate() }
            grupo.wait()
            return false
        }
        if processo.isRunning { processo.waitUntilExit() }
        guard processo.terminationStatus != 0 else { return false }
        let texto = String(data: dados, encoding: .utf8) ?? ""
        let compacto = texto.lowercased().replacingOccurrences(of: " ", with: "")
        return semSessao(texto) || compacto.contains("\"loggedin\":false")
    }

    private static func lerMemoria(repo: String, papel: BrainstormCLI.Papel) -> (cli: String?, sessao: String?, claudeFora: Bool) {
        trava.lock()
        defer { trava.unlock() }
        let guardada = memoria(papel)
        let mesmo = guardada?.repo == repo
        return (mesmo ? guardada?.cli : nil, mesmo ? guardada?.sessao : nil, claudeFora)
    }

    private static func lembrar(repo: String, cli: String, sessao: String?, papel: BrainstormCLI.Papel) {
        trava.lock()
        defer { trava.unlock() }
        let nova = Memoria(repo: repo, cli: cli, sessao: BrainstormCLI.sessaoUtil(sessao))
        switch papel {
        case .conversa: memoriaConversa = nova
        case .reescrita: memoriaReescrita = nova
        case .historias: memoriaHistorias = nova
        }
    }

    private static func memoria(_ papel: BrainstormCLI.Papel) -> Memoria? {
        switch papel {
        case .conversa: return memoriaConversa
        case .reescrita: return memoriaReescrita
        case .historias: return memoriaHistorias
        }
    }

    private static func marcarClaudeFora() {
        trava.lock()
        defer { trava.unlock() }
        claudeFora = true
        if memoriaConversa?.cli == "claude" { memoriaConversa = nil }
        if memoriaReescrita?.cli == "claude" { memoriaReescrita = nil }
        if memoriaHistorias?.cli == "claude" { memoriaHistorias = nil }
    }

    private static func ehSemLogin(_ erro: Error) -> Bool {
        if let falha = erro as? Falha, case .semLogin = falha { return true }
        return semSessao(texto(de: erro))
    }

    private static func texto(de erro: Error) -> String {
        if let falha = erro as? Falha, case .saida(_, let detalhe) = falha { return detalhe }
        return erro.localizedDescription
    }

    private static func classificar(_ erro: Error, tinhaSessao: Bool) -> BrainstormCLI.Seguinte {
        guard let falha = erro as? Falha else {
            let descricao = erro.localizedDescription
            return BrainstormCLI.seguinte(texto: descricao, codigo: nil,
                                           semLogin: semSessao(descricao), tinhaSessao: tinhaSessao)
        }
        switch falha {
        case .semLogin:
            return .proximo
        case .saida(let codigo, let detalhe):
            return BrainstormCLI.seguinte(texto: detalhe, codigo: codigo,
                                           semLogin: semSessao(detalhe), tinhaSessao: tinhaSessao)
        case .vazio, .semRepo, .semClaude:
            return .parar
        }
    }
}

// MARK: - Modelos

struct ChatMessage: Identifiable {
    let id = UUID()
    let isAgent: Bool
    let text: String
    var itens: [String] = []
    var itensUsados: Set<String> = []
}

/// Esforço do card — mesmos nomes do grupo Linear `esforco` / dispatcher.
enum EsforcoHistoria: String, CaseIterable, Identifiable, Hashable {
    case baixo, medio, alto
    var id: String { rawValue }
    var rotuloTag: String {
        switch self {
        case .baixo: return "baixo"
        case .medio: return "medio"
        case .alto: return "alto"
        }
    }
}

struct UserStory: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var description: String
    var acceptanceCriteria: [String]
    var priority: Int
    var estimate: Int
    var esforco: EsforcoHistoria
    var lane: String
    var approved: Bool = false

    /// Texto que vai para o Linear (descrição + ACs).
    var descricaoLinear: String {
        var partes = [description.trimmingCharacters(in: .whitespacesAndNewlines)]
        let acs = acceptanceCriteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !acs.isEmpty {
            partes.append("")
            partes.append("## Critérios de aceitação")
            partes.append(contentsOf: acs.map { "- \($0)" })
        }
        partes.append("")
        partes.append("_Etiquetas do processo: \(esforco.rawValue) · \(lane)_")
        return partes.joined(separator: "\n")
    }
}

// MARK: - Edição

struct EditStorySheet: View {
    var story: UserStory
    var lanes: [String]
    var criando: Bool
    /// `nil` = cancelou; valor = salvou.
    var onSave: (UserStory?) -> Void
    var onRemove: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var acText: String
    @State private var priority: Int
    @State private var estimate: Int
    @State private var esforco: EsforcoHistoria
    @State private var lane: String

    init(story: UserStory, lanes: [String], criando: Bool, onSave: @escaping (UserStory?) -> Void, onRemove: @escaping () -> Void) {
        self.story = story
        self.lanes = lanes
        self.criando = criando
        self.onSave = onSave
        self.onRemove = onRemove
        _title = State(initialValue: story.title)
        _description = State(initialValue: story.description)
        _acText = State(initialValue: story.acceptanceCriteria.joined(separator: "\n"))
        _priority = State(initialValue: story.priority)
        _estimate = State(initialValue: story.estimate)
        _esforco = State(initialValue: story.esforco)
        _lane = State(initialValue: story.lane)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(criando ? "Nova história" : "Editar história")
                .fontePainel(16, .semibold)

            TextField("Título", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading) {
                Text("Descrição")
                    .fontePainel(11)
                    .foregroundStyle(PV.mudo)
                TextEditor(text: $description)
                    .fontePainel(12)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PV.campo))
            }

            VStack(alignment: .leading) {
                Text("Critérios de aceitação (um por linha)")
                    .fontePainel(11)
                    .foregroundStyle(PV.mudo)
                TextEditor(text: $acText)
                    .fontePainel(12)
                    .frame(minHeight: 60)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PV.campo))
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Prioridade").fontePainel(11).foregroundStyle(PV.mudo)
                    Stepper(value: $priority, in: 1...4) { Text("P\(priority)") }
                }
                VStack(alignment: .leading) {
                    Text("Estimativa").fontePainel(11).foregroundStyle(PV.mudo)
                    Stepper(value: $estimate, in: 1...20) { Text("\(estimate) pts") }
                }
                VStack(alignment: .leading) {
                    Text("Esforço").fontePainel(11).foregroundStyle(PV.mudo)
                    Picker("", selection: $esforco) {
                        ForEach(EsforcoHistoria.allCases) { e in
                            Text(e.rotuloTag).tag(e)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading) {
                    Text("Lane").fontePainel(11).foregroundStyle(PV.mudo)
                    Picker("", selection: $lane) {
                        ForEach(lanes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                Spacer()
            }

            Text("As etiquetas esforço e lane são as mesmas do Linear (grupo esforco + grupo lane).")
                .fontePainel(10)
                .foregroundStyle(PV.apagado)

            HStack {
                if !criando {
                    Button("Remover") { onRemove() }
                        .foregroundStyle(PV.vermelho)
                }
                Button("Cancelar") { onSave(nil) }
                Spacer()
                Button("Salvar") {
                    let acs = acText.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var updated = story
                    updated.title = title
                    updated.description = description
                    updated.acceptanceCriteria = acs
                    updated.priority = priority
                    updated.estimate = estimate
                    updated.esforco = esforco
                    updated.lane = lane
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
                .tint(PV.azul)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}
