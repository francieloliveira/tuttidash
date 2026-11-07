import AppKit
import SwiftUI
import GastoCore

/// Tela nativa de Brainstorm no painel do TuttiDash.
/// Fluxo: ideia → histórias com etiquetas do processo (esforço + lane) → Linear.
struct PaginaBrainstorm: View {
    var modelo: ModeloNotch

    @State private var messages: [ChatMessage] = [
        ChatMessage(isAgent: true, text: "Descreva a ideia. Eu respondo curto: o furo e uma proposta.")
    ]
    @State private var chatInput: String = ""
    @State private var ideaSummary: String = ""
    @State private var stories: [UserStory] = []
    @State private var isGenerating = false
    @State private var status: String = "Pronto"
    @State private var projectId: String = ""
    @State private var projectName: String = ""
    @State private var editingStory: UserStory? = nil
    @State private var chatAberto = true
    /// Perguntas cuja resposta ainda não voltou. A pílula mostra esse número.
    @State private var perguntasEmVoo = 0
    @State private var precisaLogin = false

    private let esforcos = EsforcoHistoria.allCases
    private var lanes: [String] { Agentes.ordemPainelLanes }

    init(modelo: ModeloNotch) {
        self.modelo = modelo
        let cfg = Configuracao.resolver()
        if let p = cfg.projetoPadrao {
            _projectId = State(initialValue: p.projetoID)
            _projectName = State(initialValue: p.nome)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    passosFluxo
                    ideaSection
                    chatSection
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
        .sheet(item: $editingStory) { story in
            EditStorySheet(story: story, lanes: lanes) { updated in
                if let updated, let index = stories.firstIndex(where: { $0.id == updated.id }) {
                    stories[index] = updated
                }
                editingStory = nil
            }
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
                    .font(PV.fonte(11))
                    .foregroundStyle(PV.mudo)
                    .lineLimit(1)
            }
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
                .font(PV.fonte(10, .bold))
                .foregroundStyle(ativo ? Color.white : PV.mudo)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ativo ? PV.azul : PV.tag))
            Text(titulo)
                .font(PV.fonte(12, ativo ? .semibold : .regular))
                .foregroundStyle(ativo ? PV.texto : PV.mudo)
        }
    }

    // MARK: - Ideia

    private var ideaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("1 · Ideia")
                    .font(PV.fonte(13, .semibold))
                    .foregroundStyle(PV.mudo)
                Spacer()
                Text(status)
                    .font(PV.fonte(10))
                    .foregroundStyle(PV.apagado)
            }
            Text("Escreva o resultado desejado. O agente só ajuda a refinar — a ideia final é esta caixa.")
                .font(PV.fonte(11))
                .foregroundStyle(PV.mudo)

            TextEditor(text: $ideaSummary)
                .font(PV.fonte(13))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(PV.campo))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PV.campoBorda, lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["Explorar riscos", "Quais fluxos principais?", "Simplificar escopo", "Métricas de sucesso"], id: \.self) { q in
                        Button(q) {
                            let ideia = ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !ideia.isEmpty else {
                                status = "Escreva a ideia antes"
                                return
                            }
                            enviar(texto: "\(q)\n\nIdeia: \(ideia)")
                        }
                        .font(PV.fonte(10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                        .foregroundStyle(PV.mudo)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.cartao))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PV.cartaoBorda, lineWidth: 1))
    }

    // MARK: - Chat (auxiliar)

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    comAnimacao { chatAberto.toggle() }
                } label: {
                    HStack {
                        Text("Conversar com o agente")
                            .font(PV.fonte(13, .semibold))
                            .foregroundStyle(PV.mudo)
                        Image(systemName: chatAberto ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PV.apagado)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Button("Entrar no Claude") { AgenteBrainstorm.abrirLogin() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(precisaLogin ? PV.ambar : PV.azul)
            }

            if chatAberto {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { msg in
                            HStack {
                                if msg.isAgent {
                                    agentBubble(msg.text)
                                    Spacer(minLength: 24)
                                } else {
                                    Spacer(minLength: 24)
                                    userBubble(msg.text)
                                }
                            }
                        }
                        if perguntasEmVoo > 0 {
                            HStack {
                                PilulaWorking(quantidade: perguntasEmVoo)
                                Spacer(minLength: 24)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)

                HStack(spacing: 8) {
                    TextField("Pergunte para refinar a ideia…", text: $chatInput)
                        .textFieldStyle(.plain)
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
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(PV.cartao))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PV.cartaoBorda, lineWidth: 1))
    }

    /// Espera do chat, no formato da pílula do Cursor: cápsula escura, borda fina,
    /// «::», a palavra Working e quantas perguntas estão no ar. O mesmo corpo do texto.
    private struct PilulaWorking: View {
        var quantidade: Int

        var body: some View {
            HStack(spacing: 6) {
                Text("::")
                    .foregroundStyle(PV.apagado)
                Text("Working")
                    .foregroundStyle(PV.texto)
                Text("\(quantidade)")
                    .foregroundStyle(PV.mudo)
                    .monospacedDigit()
            }
            .font(PV.fonte(12))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(PV.campo))
            .overlay(Capsule().strokeBorder(PV.campoBorda, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    private func agentBubble(_ text: String) -> some View {
        Text(text)
            .font(PV.fonte(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(PV.interno))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PV.linhaBorda, lineWidth: 1))
            .frame(maxWidth: 360, alignment: .leading)
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(PV.fonte(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(PV.azulFundo))
            .foregroundStyle(PV.texto)
            .frame(maxWidth: 360, alignment: .trailing)
    }

    /// `texto` pronto (atalho já inclui a ideia). `nil` lê o campo do chat.
    private func enviar(texto: String?) {
        let ideia = ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitado = (texto ?? chatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digitado.isEmpty, perguntasEmVoo == 0 else { return }
        let pedido = texto == nil && !ideia.isEmpty && !digitado.contains(ideia)
            ? "\(digitado)\n\nIdeia: \(ideia)"
            : digitado
        chatAberto = true
        messages.append(ChatMessage(isAgent: false, text: pedido))
        chatInput = ""
        if ideia.isEmpty, pedido.count > 12 { ideaSummary = pedido }
        let historico = messages
        let historias = stories.map { "\($0.title) [\($0.esforco.rawValue)/\($0.lane)]" }
        let repo = AgenteBrainstorm.repoDoProjeto()
        perguntasEmVoo += 1
        Task {
            let resp: String
            do {
                resp = try await AgenteBrainstorm.responder(
                    mensagem: pedido, ideia: ideia.isEmpty ? ideaSummary : ideia,
                    historias: historias, historico: historico, repo: repo)
            } catch {
                resp = error.localizedDescription
            }
            await MainActor.run {
                perguntasEmVoo = max(0, perguntasEmVoo - 1)
                let semSessao = resp.contains("Claude sem sessão")
                precisaLogin = semSessao
                messages.append(ChatMessage(isAgent: true, text: resp))
                if semSessao { AgenteBrainstorm.abrirLogin() }
            }
        }
    }

    // MARK: - Gerar

    private var gerarBar: some View {
        Button(action: generateStories) {
            HStack {
                if isGenerating { ProgressView().controlSize(.small) }
                Text(isGenerating ? "Gerando histórias…" : "2 · Gerar histórias")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(PV.azul)
        .disabled(ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
        .padding(.horizontal, 4)
    }

    // MARK: - Histórias

    private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Histórias")
                    .font(PV.fonte(13, .semibold))
                Text("\(stories.count)")
                    .font(PV.fonte(10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                if !stories.isEmpty {
                    Text("\(stories.filter(\.approved).count) aprovadas")
                        .font(PV.fonte(10))
                        .foregroundStyle(PV.mudo)
                }
                Spacer()
                if !stories.isEmpty {
                    Button("Adicionar") { addManualStory() }
                        .font(PV.fonte(11))
                }
            }

            Text("Etiquetas do processo: esforço + lane — as mesmas que o dispatcher lê no Linear.")
                .font(PV.fonte(11))
                .foregroundStyle(PV.mudo)

            if stories.isEmpty {
                VStack(spacing: 12) {
                    Text("Nenhuma história ainda")
                        .font(PV.fonte(13, .semibold))
                        .foregroundStyle(PV.mudo)
                    Text("Refine a ideia acima e gere, ou carregue um exemplo com etiquetas coerentes.")
                        .font(PV.fonte(11))
                        .foregroundStyle(PV.mudo)
                        .multilineTextAlignment(.center)
                    Button {
                        let exemplo = "Criar tela de Brainstorm para discutir ideias com agente e gerar cards no Linear"
                        stories = storiesFromIdea(exemplo)
                        ideaSummary = exemplo
                        status = "Exemplo com \(stories.count) histórias"
                        messages.append(ChatMessage(isAgent: true, text: "Exemplo carregado. Revise esforço e lane antes de aprovar."))
                    } label: {
                        Text("Carregar exemplo").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PV.azul)
                }
                .padding(20)
                .frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(PV.cartao))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PV.cartaoBorda, lineWidth: 1))
            } else {
                ForEach($stories) { $story in
                    storyCard(story: $story)
                }
            }
        }
    }

    private func storyCard(story: Binding<UserStory>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(story.wrappedValue.title)
                    .font(PV.fonte(13, .semibold))
                Spacer()
                Button {
                    story.approved.wrappedValue.toggle()
                } label: {
                    Image(systemName: story.approved.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(story.approved.wrappedValue ? PV.verde : PV.mudo)
                        .font(.system(size: 18))
                }
                .help(story.approved.wrappedValue ? "Desaprovar" : "Aprovar para o Linear")
            }

            Text(story.wrappedValue.description)
                .font(PV.fonte(11))
                .foregroundStyle(PV.texto2)
                .lineLimit(3)

            if !story.wrappedValue.acceptanceCriteria.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Critérios de aceitação")
                        .font(PV.fonte(9))
                        .foregroundStyle(PV.mudo)
                    ForEach(story.wrappedValue.acceptanceCriteria.prefix(3), id: \.self) { ac in
                        Text("• \(ac)")
                            .font(PV.fonte(10))
                            .foregroundStyle(PV.texto2)
                    }
                }
            }

            HStack(spacing: 4) {
                tag(text: "P\(story.wrappedValue.priority)", destaque: false)
                tag(text: "\(story.wrappedValue.estimate) pts", destaque: false)
                tag(text: story.wrappedValue.esforco.rotuloTag, destaque: true)
                tag(text: story.wrappedValue.lane, destaque: true)
            }

            HStack(spacing: 10) {
                Picker("Esforço", selection: story.esforco) {
                    ForEach(esforcos) { e in
                        Text(e.rotuloTag).tag(e)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 110)

                Picker("Lane", selection: story.lane) {
                    ForEach(lanes, id: \.self) { nome in
                        Text(nome).tag(nome)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)

                Spacer(minLength: 4)
                Button("Editar") { editingStory = story.wrappedValue }
                    .font(PV.fonte(10))
                Button("Remover") { removeStory(story.id) }
                    .font(PV.fonte(10))
                    .foregroundStyle(PV.vermelho)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(PV.cartao))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            story.approved.wrappedValue ? PV.verde.opacity(0.45) : PV.cartaoBorda, lineWidth: 1))
    }

    private func tag(text: String, destaque: Bool) -> some View {
        Text(text)
            .font(PV.fonte(10, destaque ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(destaque ? PV.azulFundo : PV.tag))
            .foregroundStyle(destaque ? PV.azul : PV.mudo)
    }

    // MARK: - Rodapé

    private var footerBar: some View {
        HStack {
            Button("Aprovar todas") { for i in stories.indices { stories[i].approved = true } }
                .buttonStyle(.bordered)
            Button("Desmarcar") { for i in stories.indices { stories[i].approved = false } }
                .buttonStyle(.bordered)
            Spacer()
            Text(status)
                .font(PV.fonte(11))
                .foregroundStyle(PV.mudo)
                .lineLimit(1)
            Button(action: insertApprovedIntoLinear) {
                Text("3 · Enviar aprovadas ao Linear")
            }
            .buttonStyle(.borderedProminent)
            .tint(PV.verde)
            .disabled(stories.filter(\.approved).isEmpty || isGenerating)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(PV.lateral)
    }

    // MARK: - Ações

    private func generateStories() {
        let trimmed = ideaSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        status = "Gerando…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.stories = self.storiesFromIdea(trimmed)
            self.isGenerating = false
            self.status = "\(self.stories.count) histórias — revise esforço e lane"
            self.messages.append(ChatMessage(isAgent: true, text: "Histórias prontas. Confira esforço e lane (etiquetas do processo) antes de aprovar."))
        }
    }

    private func storiesFromIdea(_ idea: String) -> [UserStory] {
        let lanePadrao = lanes.first ?? "claude"
        let geradas: [UserStory] = [
            UserStory(
                title: "Interface de chat para refinar a ideia",
                description: "Como quem planeja\nEu quero conversar com um agente\nPara que a ideia fique clara antes de virar card",
                acceptanceCriteria: ["Chat opcional colapsável", "Resumo da ideia editável", "Atalhos de refinamento"],
                priority: 3, estimate: 5,
                esforco: .medio, lane: lanePadrao),
            UserStory(
                title: "Geração de user stories com etiquetas do processo",
                description: "Como Product Owner\nEu quero histórias com esforço e lane\nPara que o dispatcher consiga assumir o card",
                acceptanceCriteria: ["Cada história tem esforço baixo|medio|alto", "Cada história tem lane do catálogo", "Sem etiquetas inventadas fora do processo"],
                priority: 3, estimate: 5,
                esforco: .medio, lane: lanePadrao),
            UserStory(
                title: "Revisão e aprovação antes do Linear",
                description: "Como usuário\nEu quero editar e aprovar história a história\nPara que só o que foi validado entre na fila",
                acceptanceCriteria: ["Aprovação explícita (não automática)", "Edição de esforço e lane", "Remover/adicionar histórias"],
                priority: 2, estimate: 3,
                esforco: .baixo, lane: lanePadrao),
            UserStory(
                title: "Envio ao Linear em Todo com labelIds",
                description: "Como time\nEu quero criar issues com estado Todo e etiquetas resolvidas\nPara que o card entre no fluxo sem ajuste manual",
                acceptanceCriteria: ["stateId Todo do cache", "labelIds de esforço + lane", "Descrição inclui critérios de aceitação"],
                priority: 4, estimate: 5,
                esforco: .alto, lane: lanePadrao),
        ]
        let base = idea.lowercased()
        if base.contains("brainstorm") || base.contains("ideia") || base.contains("linear") {
            return geradas
        }
        return geradas.enumerated().map { i, story in
            var s = story
            if i == 0 {
                let trecho = idea.trimmingCharacters(in: .whitespacesAndNewlines)
                s.title = "Implementar: " + String(trecho.prefix(48))
                s.description = "Como time\nEu quero \(trecho)\nPara que o valor chegue às lanes"
            }
            return s
        }
    }

    private func addManualStory() {
        stories.insert(UserStory(
            title: "Nova história",
            description: "Como [usuário]\nEu quero [ação]\nPara que [benefício].",
            acceptanceCriteria: ["Critério 1"],
            priority: 2, estimate: 3,
            esforco: .medio, lane: lanes.first ?? "claude",
            approved: false), at: 0)
    }

    private func removeStory(_ id: UUID) {
        stories.removeAll { $0.id == id }
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
                    "stateId": stateTodo,
                    "priority": s.priority,
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

    private static func criarIssue(input: [String: Any]) async throws {
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

        let payload = try JSONSerialization.data(withJSONObject: input)
        guard let payloadTexto = String(data: payload, encoding: .utf8) else {
            throw ErroLinear.resposta("JSON inválido")
        }

        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        from proxy_linear import pedir, ErroProxy
        try:
            data = pedir("criar_issue", {"input": json.loads(sys.argv[2])})
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
    private struct Memoria {
        var repo: String
        var cli: String
        var sessao: String?
    }

    private static let trava = NSLock()
    private static var memoria: Memoria?
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
                                                              completo: completo, curto: curto))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Uma resposta, um CLI. O outro só entra se o primeiro não tem sessão ou recusou
    /// o comando. Erro depois de rodar não dispara outro agente.
    private static func responderSync(repo: URL, preferida: String, completo: String, curto: String) throws -> String {
        let foto = lerMemoria(repo: repo.path)
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
                                  prompt: sessao == nil ? completo : curto, sessao: sessao)
            } catch {
                switch classificar(error, tinhaSessao: sessao != nil) {
                case .recomecar:
                    do {
                        return try umaVez(cli: cli, bin: bin, repo: repo, prompt: completo, sessao: nil)
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

    private static func umaVez(cli: String, bin: String, repo: URL, prompt: String, sessao: String?) throws -> String {
        let saida = try executar(cli: cli, bin: bin, repo: repo, prompt: prompt, sessao: sessao)
        let id = BrainstormCLI.sessaoUtil(saida.sessao) ?? BrainstormCLI.sessaoUtil(sessao)
        lembrar(repo: repo.path, cli: cli, sessao: id)
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
                                 sessao: String?) throws -> BrainstormCLI.Saida {
        let saidaCodex = cli == "codex"
            ? FileManager.default.temporaryDirectory.appendingPathComponent("brainstorm-codex-\(UUID().uuidString).txt")
            : nil
        defer { if let saidaCodex { try? FileManager.default.removeItem(at: saidaCodex) } }
        guard let chamada = BrainstormCLI.chamada(cli: cli, prompt: prompt, sessao: sessao,
                                                   saidaCodex: saidaCodex?.path) else {
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

    private static func lerMemoria(repo: String) -> (cli: String?, sessao: String?, claudeFora: Bool) {
        trava.lock()
        defer { trava.unlock() }
        let mesmo = memoria?.repo == repo
        return (mesmo ? memoria?.cli : nil, mesmo ? memoria?.sessao : nil, claudeFora)
    }

    private static func lembrar(repo: String, cli: String, sessao: String?) {
        trava.lock()
        defer { trava.unlock() }
        memoria = Memoria(repo: repo, cli: cli, sessao: BrainstormCLI.sessaoUtil(sessao))
    }

    private static func marcarClaudeFora() {
        trava.lock()
        defer { trava.unlock() }
        claudeFora = true
        if memoria?.cli == "claude" { memoria = nil }
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
    /// `nil` = cancelou; valor = salvou.
    var onSave: (UserStory?) -> Void

    @State private var title: String
    @State private var description: String
    @State private var acText: String
    @State private var priority: Int
    @State private var estimate: Int
    @State private var esforco: EsforcoHistoria
    @State private var lane: String

    init(story: UserStory, lanes: [String], onSave: @escaping (UserStory?) -> Void) {
        self.story = story
        self.lanes = lanes
        self.onSave = onSave
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
            Text("Editar história")
                .font(PV.fonte(16, .semibold))

            TextField("Título", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading) {
                Text("Descrição")
                    .font(PV.fonte(11))
                    .foregroundStyle(PV.mudo)
                TextEditor(text: $description)
                    .font(PV.fonte(12))
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PV.campo))
            }

            VStack(alignment: .leading) {
                Text("Critérios de aceitação (um por linha)")
                    .font(PV.fonte(11))
                    .foregroundStyle(PV.mudo)
                TextEditor(text: $acText)
                    .font(PV.fonte(12))
                    .frame(minHeight: 60)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(PV.campo))
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Prioridade").font(PV.fonte(11)).foregroundStyle(PV.mudo)
                    Stepper(value: $priority, in: 1...5) { Text("P\(priority)") }
                }
                VStack(alignment: .leading) {
                    Text("Estimativa").font(PV.fonte(11)).foregroundStyle(PV.mudo)
                    Stepper(value: $estimate, in: 1...20) { Text("\(estimate) pts") }
                }
                VStack(alignment: .leading) {
                    Text("Esforço").font(PV.fonte(11)).foregroundStyle(PV.mudo)
                    Picker("", selection: $esforco) {
                        ForEach(EsforcoHistoria.allCases) { e in
                            Text(e.rotuloTag).tag(e)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading) {
                    Text("Lane").font(PV.fonte(11)).foregroundStyle(PV.mudo)
                    Picker("", selection: $lane) {
                        ForEach(lanes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                Spacer()
            }

            Text("As etiquetas esforço e lane são as mesmas do Linear (grupo esforco + grupo lane).")
                .font(PV.fonte(10))
                .foregroundStyle(PV.apagado)

            HStack {
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
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}
