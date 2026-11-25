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
    /// Projeto do contexto desta tela (id do Linear). Vazio = o principal da config.
    /// A escolha é da tela: guardada no app, não na config, e não troca o projeto que o
    /// dispatcher trabalha (Ajustes › Projetos é quem diz isso).
    @Published var projetoEscolhido = ""
    /// Repositório do contexto quando o projeto tem mais de um (FRA-711): o slug vai no
    /// card como etiqueta `repo:<slug>`; vazio = o repositório principal do projeto.
    @Published var repositorioEscolhido = ""
    @Published var editingStory: UserStory?
    /// Perguntas cuja resposta ainda não voltou.
    @Published var perguntasEmVoo = 0
    /// O agente de reescrita está compondo a idéia.
    @Published var reescrevendo = false
    @Published var precisaLogin = false
    /// Por que os cards vão sair sem o norte (nil = norte ativo). Não trava a tela.
    @Published var avisoNorte: String?
    /// Quantas mensagens do chat já entraram no esboço. O que vier depois acrescenta.
    @Published var mensagensNaIdeia = 0
    /// Itens marcados que já foram para o esboço.
    @Published var itensNaIdeia: Set<String> = []

    static let chaveProjeto = "brainstorm.projeto"
    static let chaveRepositorio = "brainstorm.repo"

    private init() {
        messages = [ChatMessage(isAgent: true, text: Self.textoInicial)]
        projetoEscolhido = UserDefaults.standard.string(forKey: Self.chaveProjeto) ?? ""
        repositorioEscolhido = UserDefaults.standard.string(forKey: Self.chaveRepositorio) ?? ""
    }

    /// Contexto escolhido nesta tela. Fica guardado para a próxima abertura; projeto
    /// que saiu do cadastro volta a cair no principal.
    func escolherProjeto(_ id: String) {
        projetoEscolhido = id
        UserDefaults.standard.set(id, forKey: Self.chaveProjeto)
        // O slug era do projeto anterior: trocar de projeto também volta ao principal.
        escolherRepositorio("")
    }

    /// Repositório do contexto dentro do projeto (slug). Vazio = o principal.
    func escolherRepositorio(_ slug: String) {
        repositorioEscolhido = slug
        UserDefaults.standard.set(slug, forKey: Self.chaveRepositorio)
    }
}

/// Tela nativa de Brainstorm no painel do TuttiDash.
/// Fluxo: chat (itens) → idéia reescrita → histórias → Linear.
struct PaginaBrainstorm: View {
    var modelo: ModeloNotch
    @ObservedObject private var sessao = SessaoBrainstorm.compartilhada
    /// Troca à espera de confirmação: o que está na tela é do contexto anterior.
    @State private var trocaPendente: TrocaContexto?

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
    /// Projetos do cadastro. A tela escolhe entre eles sem mexer no principal.
    private var projetos: [ProjetoCadastro] { modelo.config.projetos }
    /// Contexto do Brainstorm: é este projeto que dá o repositório, o norte e o
    /// projeto do Linear onde os cards nascem.
    private var projetoAtual: ProjetoCadastro? {
        ProjetosConfig.contexto(projetos, escolhido: sessao.projetoEscolhido)
    }
    /// Repositórios que viram etiqueta `repo:<slug>` (só valem os do projeto atual).
    private var repositorios: [RepositorioCadastro] {
        (projetoAtual?.repos ?? []).filter { RepositorioCadastro.slugValido($0.slug) }
    }
    /// Repositório do contexto quando o projeto tem mais de um; `nil` = o principal.
    /// Não usa `contexto`: ele é que monta o contexto a partir daqui (laço infinito).
    private var repositorioAtual: RepositorioCadastro? {
        guard repositorios.count > 1 else { return nil }
        return repositorios.first { $0.slug == sessao.repositorioEscolhido }
    }
    /// O que os agentes leem e o que vai na etiqueta do card.
    private var contexto: ContextoBrainstorm {
        ContextoBrainstorm(projeto: projetoAtual, repositorio: repositorioAtual)
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
                    if let aviso = sessao.avisoNorte {
                        Label(aviso, systemImage: "exclamationmark.triangle")
                            .fontePainel(11.5)
                            .foregroundStyle(TemaPainel.amarelo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    passosFluxo
                    avisosDoContexto
                    // Chat e ideia lado a lado: a conversa alimenta a caixa da direita,
                    // e a página deixa de empilhar dois blocos que ficavam quase vazios.
                    HStack(alignment: .top, spacing: 14) {
                        chatSection
                        VStack(spacing: 14) {
                            ideaSection
                            gerarBar
                        }
                        .frame(width: 460)
                    }
                    storiesSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            .background(Color.clear)

            if !stories.isEmpty {
                footerBar
            }
        }
        .task(id: projetoAtual?.projetoID ?? "") {
            // Confere o norte do projeto do contexto ao abrir e ao trocar de projeto
            // (busca a main); não trava a tela.
            guard let p = projetoAtual else { sessao.avisoNorte = nil; return }
            let e = await Task.detached { NorteProjeto.estado(p, buscar: true) }.value
            sessao.avisoNorte = NorteProjeto.avisoBrainstorm(e)
        }
        .alert("Trocar o contexto do Brainstorm?", isPresented: trocandoContexto) {
            Button("Cancelar", role: .cancel) { trocaPendente = nil }
            Button("Trocar", role: .destructive) {
                if let t = trocaPendente { aplicarTroca(t) }
            }
        } message: {
            Text(mensagemTrocaContexto)
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
            seletorProjeto
            seletorRepositorio
            Button { limparConversa() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 9.5, weight: .semibold))
                    Text("Limpar tudo")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Aurora.vermelho.opacity(0.9))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Aurora.vermelho.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("Zera o chat e a ideia. Os cards ficam.")
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    // MARK: - Contexto (projeto e repositório)

    /// Troca pedida na tela, à espera de confirmação: o que está em cima é do contexto anterior.
    private enum TrocaContexto: Equatable {
        case projeto(ProjetoCadastro)
        /// `nil` = voltar ao repositório principal.
        case repositorio(RepositorioCadastro?)
    }

    /// O que o contexto não entrega. Some quando está tudo no lugar: nada trava a tela,
    /// mas o dono sabe por que o card não anda.
    @ViewBuilder
    private var avisosDoContexto: some View {
        if let p = projetoAtual {
            if contexto.repo.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("Contexto \(p.nome) sem pasta: o chat e as histórias precisam do repositório. Defina em Ajustes › Projetos.",
                      systemImage: "folder.badge.questionmark")
                    .fontePainel(11.5)
                    .foregroundStyle(TemaPainel.amarelo)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !p.ativo {
                Label("Contexto em \(p.nome), que está parado: os cards saem no Linear, mas o dispatcher não pega eles até o projeto ser ligado.",
                      systemImage: "pause.circle")
                    .fontePainel(11.5)
                    .foregroundStyle(TemaPainel.amarelo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Projeto do contexto: o repositório lido pelo agente, o norte dos cards e o
    /// projeto do Linear onde eles nascem. Só esta tela muda; o dispatcher continua
    /// no principal de Ajustes › Projetos.
    private var seletorProjeto: some View {
        Menu {
            if projetos.isEmpty {
                Text("Nenhum projeto em Ajustes › Projetos")
            } else {
                ForEach(projetos) { p in
                    Button { pedirTroca(.projeto(p)) } label: {
                        if p.projetoID == projetoAtual?.projetoID {
                            Label(rotuloProjeto(p), systemImage: "checkmark")
                        } else {
                            Text(rotuloProjeto(p))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 9, weight: .semibold))
                Text(projetoAtual?.nome ?? "Sem projeto")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Aurora.azul)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Aurora.azul.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Aurora.azul.opacity(0.28), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Projeto do contexto: o norte e o projeto do Linear dos cards. Não troca o principal que o dispatcher trabalha.")
    }

    /// Repositório do card quando o projeto tem mais de um (FRA-711). O slug vai na
    /// etiqueta `repo:<slug>` do card; é assim que o dispatcher escolhe a pasta.
    @ViewBuilder
    private var seletorRepositorio: some View {
        if contexto.temEscolhaDeRepositorio {
            Menu {
                Button { pedirTroca(.repositorio(nil)) } label: {
                    if repositorioAtual == nil {
                        Label("principal (sem etiqueta)", systemImage: "checkmark")
                    } else {
                        Text("principal (sem etiqueta)")
                    }
                }
                ForEach(repositorios, id: \.slug) { r in
                    Button { pedirTroca(.repositorio(r)) } label: {
                        if r.slug == repositorioAtual?.slug {
                            Label(r.slug, systemImage: "checkmark")
                        } else {
                            Text(r.slug)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox").font(.system(size: 9, weight: .semibold))
                    Text(repositorioAtual.map { "repo:\($0.slug)" } ?? "repo principal")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 150, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Aurora.violeta)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Aurora.violeta.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Aurora.violeta.opacity(0.28), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Repositório deste contexto: a pasta que o agente lê e a etiqueta repo:<slug> do card. Sem escolha, vale o principal.")
        }
    }

    /// Nome no menu: diz quem é o principal (dispatcher) e quem está parado.
    private func rotuloProjeto(_ p: ProjetoCadastro) -> String {
        var partes = [p.nome]
        if p.projetoID == ProjetosConfig.padrao(projetos)?.projetoID { partes.append("principal") }
        if !p.ativo { partes.append("parado") }
        return partes.joined(separator: " · ")
    }

    private var mensagemTrocaContexto: String {
        switch trocaPendente {
        case .projeto(let p):
            let de = projetoAtual?.nome ?? "o projeto atual"
            var tem = [String]()
            if !stories.isEmpty { tem.append("\(stories.count) história(s)") }
            if !ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tem.append("a idéia") }
            if messages.count > 1 { tem.append("o chat") }
            let oQue = tem.isEmpty ? "O que está nesta tela" : tem.joined(separator: ", ")
            return "\(oQue) é de \(de). Ao trocar para \(p.nome), o chat, a idéia e o quadro são zerados para não mandar card para o projeto errado."
        case .repositorio(let r):
            let de = repositorioAtual?.slug ?? "o principal"
            let para = r?.slug ?? "o principal"
            return "As \(stories.count) história(s) do quadro foram geradas a partir do repositório \(de). Ao trocar para \(para), o quadro é zerado para não mandar card ao repositório errado. O chat e a idéia ficam."
        case nil:
            return ""
        }
    }

    private var trocandoContexto: Binding<Bool> {
        Binding(get: { trocaPendente != nil },
                set: { if !$0 { trocaPendente = nil } })
    }

    /// Troca de projeto zera tudo; troca de repositório zera o quadro. Sem nada a perder, troca direto.
    private func pedirTroca(_ troca: TrocaContexto) {
        switch troca {
        case .projeto(let p):
            guard p.projetoID != projetoAtual?.projetoID else { return }
            let vazio = stories.isEmpty
                && ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && messages.count <= 1
            if vazio { aplicarTroca(troca) } else { trocaPendente = troca }
        case .repositorio(let r):
            guard r?.slug != repositorioAtual?.slug else { return }
            if stories.isEmpty { aplicarTroca(troca) } else { trocaPendente = troca }
        }
    }

    private func aplicarTroca(_ troca: TrocaContexto) {
        switch troca {
        case .projeto(let p):
            sessao.escolherProjeto(p.projetoID)
            limparConversa()
            stories = []
            status = "Contexto: \(p.nome)"
        case .repositorio(let r):
            sessao.escolherRepositorio(r?.slug ?? "")
            stories = []
            status = r.map { "Repositório: \($0.slug)" } ?? "Repositório: o principal"
        }
        trocaPendente = nil
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Aurora.apagado)
    }

    private func passo(_ n: Int, _ titulo: String) -> some View {
        let ativo = passoAtual >= n
        return HStack(spacing: 6) {
            Text("\(n)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(ativo ? Aurora.tinta : Aurora.mudo)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ativo ? AnyShapeStyle(Aurora.gradienteBotao)
                                                : AnyShapeStyle(Color.white.opacity(0.07))))
            Text(titulo)
                .font(.system(size: 11.5, weight: ativo ? .semibold : .regular, design: .rounded))
                .foregroundStyle(ativo ? Aurora.texto : Aurora.mudo)
        }
    }

    // MARK: - Ideia

    private var ideaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                RotuloSecao(titulo: "Idéia", icone: "sparkles", cor: Aurora.acento)
                Spacer()
                if reescrevendo {
                    EfeitoThinking()
                } else {
                    Text(status)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Aurora.apagado)
                        .lineLimit(1)
                }
            }
            Text("Gerar idéia no chat reúne a conversa e os itens marcados. Continuar o chat e gerar de novo acrescenta. A caixa continua editável.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Aurora.mudo)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $sessao.ideaSummary)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Aurora.texto)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 92)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(14)
        .vidroAurora(raio: 16)
    }

    // MARK: - Chat (auxiliar)

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RotuloSecao(titulo: "Chat", icone: "bubble.left.and.bubble.right", cor: Aurora.azul)
                Spacer(minLength: 8)
                Button { AgenteBrainstorm.abrirLogin() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Entrar no Claude")
                    }
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                .tint(precisaLogin ? Aurora.ambar : Aurora.azul)
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
                        Button { enviar(texto: q) } label: {
                            Text(q)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Aurora.texto2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.05)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        }
                        .buttonStyle(Pressionavel())
                        .disabled(perguntasEmVoo > 0)
                    }
                }
            }

            Button(action: gerarIdeia) {
                HStack(spacing: 7) {
                    if reescrevendo { ProgressView().controlSize(.small) }
                    Text(reescrevendo ? "Gerando idéia…" : "Gerar idéia")
                }
            }
            .buttonStyle(EstiloBotaoPrincipal())
            .disabled(!podeGerarIdeia)

            HStack(spacing: 8) {
                TextField("", text: $sessao.chatInput,
                          prompt: Text("Pergunte ou descreva a ideia…").foregroundColor(Aurora.mudo))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                    .tint(Aurora.acento)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.black.opacity(0.24)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .onSubmit { enviar(texto: nil) }

                Button { enviar(texto: nil) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Aurora.tinta)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Aurora.gradienteBotao))
                }
                .buttonStyle(Pressionavel())
                .disabled(perguntasEmVoo > 0 || chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Enviar mensagem")
                .accessibilityLabel("Enviar mensagem")
            }
        }
        .padding(14)
        .vidroAurora(raio: 16)
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
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Aurora.texto2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

            if !msg.itens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(msg.itens, id: \.self) { item in
                        let marcado = msg.itensUsados.contains(item)
                        Button {
                            alternarItem(item, mensagem: msg.id)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: marcado ? "checkmark" : "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.top, 2)
                                Text(item)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(marcado ? Aurora.acento.opacity(0.14) : Color.white.opacity(0.04)))
                            .foregroundStyle(marcado ? Aurora.acento : Aurora.texto2)
                        }
                        .buttonStyle(.plain)
                        .help(marcado ? "Tirar da idéia" : "Incluir na idéia")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Aurora.azul.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Aurora.azul.opacity(0.25), lineWidth: 1))
            .foregroundStyle(Aurora.texto)
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
        let contexto = self.contexto
        let geracao = conversaGeracao
        perguntasEmVoo += 1
        Task {
            let resp: String
            do {
                resp = try await AgenteBrainstorm.responder(
                    mensagem: digitado, ideia: ideia,
                    historias: historias, historico: historico, contexto: contexto)
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
        let contexto = self.contexto
        Task {
            let resultado: Result<String, Error>
            do {
                resultado = .success(try await AgenteBrainstorm.reescrever(
                    ideia: base, conversa: conversa, itens: novos, contexto: contexto))
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
            HStack(spacing: 7) {
                if isGenerating { ProgressView().controlSize(.small) }
                Text(isGenerating ? "Gerando histórias…" : "Gerar histórias")
            }
        }
        .buttonStyle(EstiloBotaoPrincipal())
        .disabled(ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || reescrevendo)
    }

    // MARK: - Histórias

    private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RotuloSecao(titulo: "Histórias", icone: "rectangle.stack", cor: Aurora.violeta)
                Text("\(stories.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Aurora.texto2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                if !stories.isEmpty {
                    Text("\(stories.filter(\.approved).count) marcadas")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(Aurora.verde)
                }
                Spacer()
                Button { novaHistoria() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("Adicionar")
                    }
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
            }

            Text("Cards no quadro. Clique para editar. Esforço e lane são as etiquetas do Linear.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Aurora.mudo)

            if stories.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Aurora.apagado)
                    Text("Nenhuma história ainda")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Aurora.texto2)
                    Text("Aceite itens no chat ou escreva a idéia, depois gere.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 132)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.025)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                    ForEach($sessao.stories) { $story in
                        kanbanCard(story: $story)
                    }
                }
            }
        }
        .padding(14)
        .vidroAurora(raio: 16)
    }

    private func kanbanCard(story: Binding<UserStory>) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                editingStory = story.wrappedValue
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(story.wrappedValue.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Aurora.texto)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 22)
                    Text(story.wrappedValue.description)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Aurora.mudo)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !story.wrappedValue.faltando.isEmpty {
                        Text("Falta: " + story.wrappedValue.faltando.map(\.rawValue).joined(separator: ", "))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Aurora.vermelho)
                    }
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
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(story.approved.wrappedValue ? 0.055 : 0.03)))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(
                        !story.wrappedValue.faltando.isEmpty ? Aurora.vermelho.opacity(0.55)
                            : (story.approved.wrappedValue ? Aurora.verde.opacity(0.45)
                                                           : Color.white.opacity(0.07)),
                        lineWidth: 1)
                )
            }
            .buttonStyle(Pressionavel())

            Button {
                story.approved.wrappedValue.toggle()
            } label: {
                Image(systemName: story.approved.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(story.approved.wrappedValue ? Aurora.verde : Aurora.apagado)
                    .font(.system(size: 15))
                    .padding(8)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(story.approved.wrappedValue ? "Desmarcar card" : "Marcar para o Linear")
            .accessibilityLabel(story.approved.wrappedValue ? "Desmarcar card" : "Marcar card")
        }
    }

    private func tag(text: String, destaque: Bool) -> some View {
        EtiquetaAurora(texto: text, cor: destaque ? Aurora.azul : Aurora.mudo)
    }

    // MARK: - Rodapé

    private var haMarcadas: Bool { stories.contains(where: \.approved) }
    /// Card marcado sem objetivo, aceite ou fora de escopo trava o «Aprovar» (decisão do dono).
    private var marcadasIncompletas: Int { stories.filter { $0.approved && !$0.faltando.isEmpty }.count }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button { insertApprovedIntoLinear() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10, weight: .semibold))
                    Text("Aprovar")
                }
            }
            .buttonStyle(EstiloBotaoPrincipal(compacto: true))
            .disabled(!haMarcadas || isGenerating || marcadasIncompletas > 0)
            .help(marcadasIncompletas > 0
                  ? "\(marcadasIncompletas) card(s) marcado(s) sem objetivo, aceite ou fora de escopo. Abra e complete."
                  : "Cria os cards marcados no Linear.")
            Button { removerMarcadas() } label: {
                Text("Remover").foregroundStyle(Aurora.vermelho.opacity(0.9))
            }
            .buttonStyle(EstiloBotaoSecundario(compacto: true))
            .disabled(!haMarcadas || isGenerating)
            Button { for i in stories.indices { stories[i].approved = true } } label: {
                Text("Marcar todas")
            }
            .buttonStyle(EstiloBotaoSecundario(compacto: true))
            .disabled(stories.isEmpty)
            Button { for i in stories.indices { stories[i].approved = false } } label: {
                Text("Desmarcar todas")
            }
            .buttonStyle(EstiloBotaoSecundario(compacto: true))
            .disabled(!haMarcadas)
            Spacer(minLength: 8)
            if marcadasIncompletas > 0 {
                PilulaAurora(titulo: "\(marcadasIncompletas) incompleto(s)", cor: Aurora.vermelho, compacta: true)
            }
            Text(status)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Aurora.mudo)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) { Rectangle().fill(Aurora.hair).frame(height: 1) }
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
        let contexto = self.contexto

        Task {
            let resultado: Result<[BrainstormCLI.HistoriaGerada], Error>
            do {
                let lista = try await AgenteBrainstorm.gerarHistorias(ideia: trimmed, etiquetas: etiquetas,
                                                                      contexto: contexto)
                resultado = .success(lista)
            } catch {
                resultado = .failure(error)
            }
            await MainActor.run {
                isGenerating = false
                // «Limpar tudo» no meio da geração não pode repovoar o quadro nem o chat:
                // a resposta desta conversa já não vale. Antes os cards voltavam depois do limpo.
                guard geracao == conversaGeracao else { return }
                switch resultado {
                case .success(let lista):
                    let cards = lista.compactMap { Self.story(de: $0) }
                    guard !cards.isEmpty else {
                        status = "O agente não devolveu histórias da idéia"
                        return
                    }
                    stories = cards
                    let semNorte = AgenteBrainstorm.repoDo(contexto).map {
                        CardBrainstorm.contexto(repo: $0, norte: contexto.norte).norte == nil
                    } ?? true
                    status = semNorte
                        ? "\(cards.count) histórias. Projeto sem norte: crie em Ajustes › Projetos."
                        : "\(cards.count) histórias ancoradas no norte"
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
            approved: false,
            objetivo: g.objetivo,
            norteServido: g.norteServido,
            prova: g.prova,
            foraDeEscopo: g.foraDeEscopo,
            arquivos: g.arquivos,
            dependencias: g.dependencias)
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
        guard let projeto = projetoAtual else {
            status = "Cadastre um projeto em Ajustes"
            CentralAvisos.compartilhada.erro("Sem projeto Linear",
                                             "Cadastre a pasta e o projeto do Linear em Ajustes › Projetos.")
            return
        }
        let projetoID = projeto.projetoID
        let nomeProjeto = projeto.nome
        // Repositório escolhido: vira a etiqueta `repo:<slug>` do card (FRA-711).
        let slug = contexto.slug
        let onde = slug.isEmpty ? nomeProjeto : "\(nomeProjeto) · \(slug)"

        isGenerating = true
        status = "Enviando \(approved.count) para \(onde)…"

        Task {
            let ids: IdsBrainstorm
            do {
                ids = try await Self.idsGarantidos(
                    projetoID: projetoID, lanes: Set(approved.map(\.lane)).sorted(),
                    repos: slug.isEmpty ? [] : [slug])
            } catch {
                await MainActor.run {
                    isGenerating = false
                    status = "Falha no envio"
                    CentralAvisos.compartilhada.erro("Nada foi criado", error.localizedDescription)
                }
                return
            }
            let stateTodo = ids.todo
            guard !stateTodo.isEmpty else {
                await MainActor.run {
                    isGenerating = false
                    status = "Linear sem estado Todo"
                    CentralAvisos.compartilhada.erro("IDs do Linear incompletos",
                                                     "O time do projeto não tem o estado Todo. Confira as colunas no Linear.")
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
                if !slug.isEmpty {
                    // Sem a etiqueta o card cairia no repositório principal: melhor não criar.
                    guard let repoID = ids.repos[slug] else {
                        falhas.append("\(s.title): a etiqueta repo:\(slug) não existe no Linear")
                        continue
                    }
                    labelIds.append(repoID)
                }
                let input: [String: Any] = [
                    "title": s.title,
                    "description": s.descricaoLinear,
                    "projectId": projetoID,
                    "teamId": ids.time,
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
                        ? "\(okIds.count) cards no Linear · \(onde)"
                        : "\(okIds.count) ok, \(falhas.count) falha(s) · \(onde)"
                    CentralAvisos.compartilhada.ok(
                        "\(okIds.count) card(s) no Linear",
                        falhas.isEmpty ? "Projeto: \(onde)" : falhas.joined(separator: "\n"))
                } else {
                    status = "Falha no envio"
                    CentralAvisos.compartilhada.erro("Nada foi criado", falhas.joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - Linear / proxy

    private struct IdsBrainstorm {
        var todo: String
        /// Time do projeto: o `issueCreate` do Linear exige um time.
        var time: String
        var esforco: [String: String]
        var lanes: [String: String]
        /// Id da etiqueta `repo:<slug>` por slug (FRA-711).
        var repos: [String: String]
    }

    /// IDs do estado Todo, do esforço e das lanes, mais o time do projeto. Usa a mesma regra do
    /// dispatcher (`linear_ids.garantir`): cache do projeto, depois a API pelo nome, e cria o que
    /// não existir. Antes o app lia só o cache: uma lane sem id (ou um projeto novo, sem cache)
    /// fazia o envio inteiro parar em «Falha no envio».
    private static func idsGarantidos(projetoID: String, lanes: [String],
                                      repos: [String] = []) async throws -> IdsBrainstorm {
        let pasta = try pastaDoProxy()
        let payload = try JSONSerialization.data(withJSONObject: ["projeto": projetoID, "lanes": lanes,
                                                                  "repos": repos])
        guard let payloadTexto = String(data: payload, encoding: .utf8) else {
            throw ErroLinear.resposta("JSON inválido")
        }
        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        import linear_ids, proxy_linear, config
        try:
            pedido = json.loads(sys.argv[2])
            projeto = pedido.get("projeto") or ""
            dono = config.obter("linear.owner_label", "needs:dono") or "needs:dono"
            ids = linear_ids.garantir(config.obter, proxy_linear.executar_consulta, dono=dono,
                                      lanes=pedido.get("lanes") or [], repos=pedido.get("repos") or [],
                                      project_id=projeto)
            time = linear_ids.time_do_projeto(proxy_linear.executar_consulta, projeto)
            print(json.dumps({"ok": True, "time": time, "ids": ids}, ensure_ascii=False))
        except Exception as e:
            print(json.dumps({"ok": False, "erro": str(e)}, ensure_ascii=False))
            sys.exit(1)
        """
        let obj = try executarPython(script, pasta: pasta, argumento: payloadTexto)
        guard let raiz = obj["ids"] as? [String: Any] else {
            throw ErroLinear.resposta("resposta sem os ids do Linear")
        }
        let estados = raiz["estados"] as? [String: Any] ?? [:]
        return IdsBrainstorm(todo: (estados["todo"] as? String) ?? "",
                             time: (obj["time"] as? String) ?? "",
                             esforco: raiz["esforco"] as? [String: String] ?? [:],
                             lanes: raiz["lanes"] as? [String: String] ?? [:],
                             repos: raiz["repos"] as? [String: String] ?? [:])
    }

    private static func criarIssue(input: [String: Any]) async throws {
        let data = try await pedirProxy(op: "criar_issue", variaveis: ["input": input])
        let criado = data["issueCreate"] as? [String: Any]
        if criado?["success"] as? Bool == false {
            throw ErroLinear.resposta("O Linear não criou o card")
        }
    }

    private static func pedirProxy(op: String, variaveis: [String: Any]) async throws -> [String: Any] {
        let pasta = try pastaDoProxy()
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

        let obj = try executarPython(script, pasta: pasta, argumento: payloadTexto)
        guard let data = obj["data"] as? [String: Any] else {
            throw ErroLinear.resposta("resposta do proxy sem data")
        }
        return data
    }

    /// Pasta com os módulos do plano de controle (`proxy_linear.py` é o marcador).
    private static func pastaDoProxy() throws -> URL {
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
        return pasta
    }

    /// Roda um script Python com a pasta dos módulos e um JSON de argumento. O script devolve
    /// `{"ok": true, ...}` ou `{"ok": false, "erro": "..."}` — o erro vai para a tela.
    private static func executarPython(_ script: String, pasta: URL, argumento: String) throws -> [String: Any] {
        let processo = Process()
        processo.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        processo.arguments = ["-c", script, pasta.path, argumento]
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
        return obj ?? [:]
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

    /// Pasta do contexto: o repositório escolhido, senão o principal do projeto.
    /// `nil` = contexto sem pasta, ou pasta que não existe neste Mac.
    static func repoDo(_ contexto: ContextoBrainstorm) -> URL? {
        let cru = contexto.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cru.isEmpty else { return nil }
        let caminho = (cru as NSString).expandingTildeInPath
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: caminho, isDirectory: &dir), dir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: caminho, isDirectory: true)
    }

    static func responder(mensagem: String, ideia: String, historias: [String],
                          historico: [ChatMessage], contexto: ContextoBrainstorm) async throws -> String {
        guard let repo = repoDo(contexto) else { throw Falha.semRepo }
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
    static func reescrever(ideia: String, conversa: String, itens: [String],
                           contexto: ContextoBrainstorm) async throws -> String {
        guard let repo = repoDo(contexto) else { throw Falha.semRepo }
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
    /// O norte e o mapa são os do projeto do contexto.
    static func gerarHistorias(ideia: String, etiquetas: [BrainstormCLI.EtiquetaLane],
                               contexto: ContextoBrainstorm) async throws -> [BrainstormCLI.HistoriaGerada] {
        guard let repo = repoDo(contexto) else { throw Falha.semRepo }
        let ctx = CardBrainstorm.contexto(repo: repo, norte: contexto.norte)
        let pedido = BrainstormCLI.promptHistorias(ideia: ideia, etiquetas: etiquetas, norte: ctx.norte, mapa: ctx.mapa)
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

    /// Rascunho do norte no wizard de projeto. Lê o repositório do próprio projeto (não o do
    /// Brainstorm) e não abre o login sozinho: sem conta, o wizard oferece login, Ollama ou
    /// escrever à mão. Resposta sem nenhuma seção reconhecida vira `Falha.vazio`.
    static func rascunharNorte(nome: String, repo: URL, respostas: String) async throws -> NorteRascunho.Rascunho {
        let leitura = NorteRascunho.lerRepositorio(repo)
        let pedido = NorteRascunho.prompt(nome: nome, leitura: leitura, respostas: respostas)
        let preferida = cliPreferido()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let bruto = try responderSync(repo: repo, preferida: preferida, completo: pedido, curto: pedido,
                                                  papel: .norte, abrirLoginSeFaltar: false)
                    guard let r = NorteRascunho.ler(bruto) else { throw Falha.vazio }
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// `Falha.semLogin`: nenhum CLI do Brainstorm tem conta configurada.
    static func ehFaltaDeConta(_ erro: Error) -> Bool { ehSemLogin(erro) }

    /// Uma resposta, um CLI. O outro só entra se o primeiro não tem sessão ou recusou
    /// o comando. Erro depois de rodar não dispara outro agente.
    private static func responderSync(repo: URL, preferida: String, completo: String, curto: String,
                                      papel: BrainstormCLI.Papel, abrirLoginSeFaltar: Bool = true) throws -> String {
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
        if pediuLogin, abrirLoginSeFaltar { abrirLogin() }
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
        case .norte: break  // o norte não retoma sessão
        }
    }

    private static func memoria(_ papel: BrainstormCLI.Papel) -> Memoria? {
        switch papel {
        case .conversa: return memoriaConversa
        case .reescrita: return memoriaReescrita
        case .historias: return memoriaHistorias
        case .norte: return nil
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
    // Contrato do card (PRD do norte, fase 2).
    var objetivo: String = ""
    var norteServido: String = ""
    var prova: String = ""
    var foraDeEscopo: [String] = []
    var arquivos: [String] = []
    var dependencias: [String] = []

    /// O que falta para aprovar. Vazio = completo.
    var faltando: [CardBrainstorm.Falta] {
        CardBrainstorm.faltando(objetivo: objetivo, aceite: acceptanceCriteria, foraDeEscopo: foraDeEscopo)
    }

    /// Texto que vai para o Linear: o único que o agente da lane lê.
    var descricaoLinear: String {
        CardBrainstorm.corpo(objetivo: objetivo, norteServido: norteServido, historia: description,
                             aceite: acceptanceCriteria, prova: prova, foraDeEscopo: foraDeEscopo,
                             arquivos: arquivos, dependencias: dependencias,
                             esforco: esforco.rawValue, lane: lane)
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
    @State private var objetivo: String
    @State private var norte: String
    @State private var prova: String
    @State private var foraText: String
    @State private var arquivosText: String
    @State private var dependeText: String

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
        _objetivo = State(initialValue: story.objetivo)
        _norte = State(initialValue: story.norteServido)
        _prova = State(initialValue: story.prova)
        _foraText = State(initialValue: story.foraDeEscopo.joined(separator: "\n"))
        _arquivosText = State(initialValue: story.arquivos.joined(separator: "\n"))
        _dependeText = State(initialValue: story.dependencias.joined(separator: "\n"))
    }

    private static func linhas(_ t: String) -> [String] {
        t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var faltando: [CardBrainstorm.Falta] {
        CardBrainstorm.faltando(objetivo: objetivo, aceite: Self.linhas(acText), foraDeEscopo: Self.linhas(foraText))
    }

    /// Rótulo do campo; obrigatório vazio fica em vermelho.
    private func rotulo(_ texto: String, obrigatorio: CardBrainstorm.Falta? = nil) -> some View {
        let falta = obrigatorio.map { faltando.contains($0) } ?? false
        return Text(obrigatorio == nil ? texto : texto + " *")
            .fontePainel(11, falta ? .semibold : .regular)
            .foregroundStyle(falta ? PV.vermelho : PV.mudo)
    }

    private func editor(_ texto: Binding<String>, altura: CGFloat) -> some View {
        TextEditor(text: texto)
            .fontePainel(12)
            .frame(minHeight: altura)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(PV.campo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(criando ? "Nova história" : "Editar história")
                .fontePainel(16, .semibold)

            TextField("Título", text: $title)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading) {
                        rotulo("Objetivo (1 a 3 frases: o resultado)", obrigatorio: .objetivo)
                        editor($objetivo, altura: 40)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Norte servido (trecho do norte que o card move)")
                        editor($norte, altura: 40)
                    }
                    VStack(alignment: .leading) {
                        rotulo("História (Como … quero … para …)")
                        editor($description, altura: 50)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Aceite observável (um por linha)", obrigatorio: .aceite)
                        editor($acText, altura: 50)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Prova (suíte do mapa ou como verificar)")
                        TextField("", text: $prova).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Fora de escopo (um por linha)", obrigatorio: .foraDeEscopo)
                        editor($foraText, altura: 40)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Arquivos / módulos prováveis (um por linha)")
                        editor($arquivosText, altura: 36)
                    }
                    VStack(alignment: .leading) {
                        rotulo("Depende de (um por linha)")
                        editor($dependeText, altura: 28)
                    }
                }
            }
            .frame(maxHeight: 420)

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

            Text(faltando.isEmpty
                 ? "As etiquetas esforço e lane são as mesmas do Linear (grupo esforco + grupo lane)."
                 : "* obrigatório para aprovar: " + faltando.map(\.rawValue).joined(separator: ", ") + ".")
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
                    updated.objetivo = objetivo.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.norteServido = norte.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.prova = prova.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.foraDeEscopo = Self.linhas(foraText)
                    updated.arquivos = Self.linhas(arquivosText)
                    updated.dependencias = Self.linhas(dependeText)
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
        .frame(minWidth: 560)
    }
}
