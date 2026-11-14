import AppKit
import SwiftUI
import UserNotifications
import GastoCore

/// Caixa do dono (PRD de 29/10): lê o `caixa-dono.json` que o vigia grava, conta as respostas em
/// aberto, avisa no macOS uma vez por pergunta nova e envia as decisões ao Linear.
@MainActor
final class EstadoCaixa: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let compartilhada = EstadoCaixa()

    @Published private(set) var arquivo: ArquivoCaixa = .vazio
    /// false enquanto o vigia não gravou a caixa: o sino cai no contador antigo do log.
    @Published private(set) var arquivoExiste = false
    /// Perguntas respondidas pelo app que o vigia ainda não tirou do arquivo.
    @Published private(set) var respondidas: Set<String> = []
    @Published private(set) var enviando: Set<String> = []
    @Published private(set) var erros: [String: String] = [:]
    @Published var selecionado: String?

    private let url = CaixaDono.arquivo()
    private var dataArquivo: Date?
    private var relogio: Timer?
    private let chaveVistas = "caixa.vistas"
    /// Fora de um `.app` (swift run, binário solto) a central de avisos aborta o processo.
    private let temBundle = Bundle.main.bundleIdentifier != nil
    /// Perguntas cujo aviso já foi pedido nesta execução (evita pedir de novo a cada 3 s).
    private var avisoPedido: Set<String> = []

    var abertas: Int { CaixaDono.abertas(arquivo.itens, respondidas: respondidas) }

    /// Catálogo, config e cache de modelos, lidos quando a caixa muda (não a cada desenho da tela).
    private var agentes: [String: CatalogoAgentes.ModeloAgente] = [:]
    private var dadosConfig: [String: Any] = [:]
    private var cacheModelos: CacheModelos = .vazio

    private func carregarContexto() {
        agentes = Dictionary(CatalogoAgentes.carregar().map { ($0.nome, $0) }, uniquingKeysWith: { a, _ in a })
        dadosConfig = Configuracao.lerArquivo()
        cacheModelos = ListaModelos.ler(ListaModelos.arquivoCache())
    }

    /// «opus · high»: o que a lane roda neste peso, pela mesma regra do dispatcher.
    /// Peso vazio = `lanes.effort_default` da config (como o dispatcher).
    func vaiRodar(_ lane: String, _ peso: String) -> String? {
        guard let agente = agentes[lane] else { return nil }
        let padrao = (Configuracao.valor("lanes.effort_default", em: dadosConfig) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "medio"
        let r = ModeloLane.resolver(lane: lane, peso: peso.isEmpty ? padrao : peso,
                                    config: ModeloLane.ler(ModeloLane.bruto(lane: lane, em: dadosConfig)),
                                    padrao: ModeloLane.padrao(agente), cache: cacheModelos, agente: agente)
        let modelo = r.modelo.isEmpty ? "o modelo padrão do CLI" : r.modelo
        return r.esforco.isEmpty ? modelo : "\(modelo) · \(r.esforco)"
    }
    var itens: [ItemCaixa] { arquivo.itens }

    func iniciar() {
        guard relogio == nil else { return }
        if temBundle { UNUserNotificationCenter.current().delegate = self }
        recarregar()
        relogio = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recarregar() }
        }
    }

    /// Lê o arquivo só quando ele mudou (data de modificação).
    func recarregar() {
        let data = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard data != dataArquivo else { return }
        dataArquivo = data
        arquivoExiste = data != nil
        carregarContexto()
        let novo = CaixaDono.ler(url)
        arquivo = novo
        let atuais = Set(novo.itens.map(\.perguntaId))
        respondidas = respondidas.intersection(atuais)
        if let s = selecionado, !novo.itens.contains(where: { $0.card == s }) { selecionado = nil }
        if selecionado == nil { selecionado = novo.itens.first?.card }
        avisarNovas()
    }

    func decidir(_ decisao: CaixaDono.Decisao, item: ItemCaixa) {
        // Um envio por card: o segundo clique enquanto o primeiro está no ar repetia as mutações.
        guard !enviando.contains(item.card) else { return }
        let conta = { () -> Bool in if case .responder(_, liberar: false) = decisao { return false }; return true }()
        // FRA-601: o identifier da tela vai ao Linear. Os ids de etiqueta saem da config e do
        // cache do vigia, não do caixa-dono.json. O token é o mesmo item do FRA-568.
        let cfg = Configuracao.resolver()
        let bruto = Configuracao.lerArquivo()
        let nome = cfg.rotuloDono?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rotulo = nome.isEmpty ? "needs:dono" : nome
        let ids = CaixaDono.idsDoApp(config: bruto,
                                    cache: CaixaDono.lerCacheIds(CaixaDono.caminhoCacheIds(home: cfg.home, projetoID: cfg.projetoPadrao?.projetoID ?? "")),
                                    rotuloDono: rotulo)
        // `security` sai da MainActor: ler o token aqui travava a interface (FRA-608).
        Task.detached {
            let token = TokenLinear().ler()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let token else {
                    self.erros[item.card] = ErroLinear.semToken.localizedDescription
                    return
                }
                self.erros[item.card] = nil
                self.enviando.insert(item.card)
                if conta { self.respondidas.insert(item.perguntaId) }
                Task {
                    do {
                        let cliente = HTTPClienteLinear()
                        let resolucao = try await CaixaDono.resolver(identifier: item.card, rotuloDono: rotulo, cliente: cliente, token: token)
                        let passos = try CaixaDono.mutacoes(decisao, item: item, resolucao: resolucao, ids: ids, rotuloDono: rotulo)
                        if !passos.isEmpty { try await CaixaDono.executar(passos, cliente: cliente, token: token) }
                        self.enviando.remove(item.card)
                        CentralAvisos.compartilhada.ok(String(localized: "\(item.card): decisão enviada"))
                    } catch {
                        self.enviando.remove(item.card)
                        self.respondidas.remove(item.perguntaId)
                        self.erros[item.card] = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: aviso do macOS

    private func avisarNovas() {
        guard temBundle else { return }
        let vistas = Set(UserDefaults.standard.stringArray(forKey: chaveVistas) ?? [])
        let novas = CaixaDono.novas(arquivo.itens, vistas: vistas.union(avisoPedido), respondidas: respondidas)
        guard !novas.isEmpty else { return }
        avisoPedido.formUnion(novas.map(\.perguntaId))
        let central = UNUserNotificationCenter.current()
        let chave = chaveVistas
        central.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            // Só conta como visto o aviso que saiu: autorizado depois, os pendentes ainda avisam.
            guard ok else { return }
            var gravadas = Set(UserDefaults.standard.stringArray(forKey: chave) ?? [])
            gravadas.formUnion(novas.map(\.perguntaId))
            UserDefaults.standard.set(Array(gravadas.suffix(500)), forKey: chave)
            for item in novas {
                let c = UNMutableNotificationContent()
                c.title = String(localized: "\(item.card) espera você")
                c.body = item.pendencia.isEmpty ? (item.motivo.isEmpty ? item.titulo : item.motivo) : item.pendencia
                c.sound = .default
                central.add(UNNotificationRequest(identifier: item.perguntaId, content: c, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let card = response.notification.request.identifier.split(separator: ":").first.map(String.init)
        Task { @MainActor in
            NavegacaoPainel.compartilhada.pagina = .esperando
            if let card { EstadoCaixa.compartilhada.selecionado = card }
            if let m = JanelaPainel.compartilhada.modeloAtual { JanelaPainel.compartilhada.mostrar(modelo: m) }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Página «Esperando você»: lista à esquerda, a decisão à direita.
struct PaginaEsperando: View {
    @ObservedObject private var caixa = EstadoCaixa.compartilhada
    @State private var resposta = ""
    @State private var confirmarCancelar = false

    private var atual: ItemCaixa? { caixa.itens.first { $0.card == caixa.selecionado } ?? caixa.itens.first }

    private func oQueAcontece(_ d: CaixaDono.Decisao, _ item: ItemCaixa) -> String {
        CaixaDono.consequencia(d, item: item, vaiRodar: caixa.vaiRodar)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    RotuloSecao(titulo: "Respostas em aberto", icone: "tray.full", cor: Aurora.ambar)
                    Text("\(caixa.abertas)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Aurora.ambar)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Aurora.ambar.opacity(0.15)))
                    Spacer(minLength: 0)
                }
                if caixa.itens.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(Aurora.verde.opacity(0.8))
                        Text(String(localized: "Nada esperando por você agora."))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Aurora.mudo)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
                ForEach(caixa.itens) { item in linhaLista(item) }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 320, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .cartaoVivo()

            Group {
                if let item = atual { detalhe(item) } else {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Aurora.apagado)
                        Text(String(localized: "Quando um card precisar de você, a pendência e as decisões aparecem aqui."))
                            .font(.system(size: 12.5, design: .rounded))
                            .foregroundStyle(Aurora.mudo)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cartaoVivo()
        }
        .onAppear { caixa.iniciar() }
    }

    private func linhaLista(_ item: ItemCaixa) -> some View {
        let sel = item.card == atual?.card
        let respondida = caixa.respondidas.contains(item.perguntaId)
        return Button { caixa.selecionado = item.card; resposta = "" } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.card)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Aurora.texto)
                    Spacer()
                    if caixa.enviando.contains(item.card) {
                        ProgressView().controlSize(.small)
                    } else if respondida {
                        PilulaAurora(titulo: "enviado", cor: Aurora.verde, compacta: true)
                    }
                }
                Text(item.titulo)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Aurora.texto2)
                    .lineLimit(1)
                Text(meta(item))
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Aurora.apagado)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(sel ? Aurora.acento.opacity(0.12) : Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(sel ? Aurora.acento.opacity(0.40) : Color.white.opacity(0.05), lineWidth: 1))
            .overlay(alignment: .leading) {
                if sel {
                    Capsule().fill(Aurora.acento).frame(width: 3, height: 22).padding(.leading, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
        .accessibilityAddTraits(sel ? .isSelected : AccessibilityTraits())
    }

    private func meta(_ item: ItemCaixa) -> String {
        var partes: [String] = []
        if !item.esforco.isEmpty { partes.append(item.esforco) }
        if let d = item.desde { partes.append(String(localized: "espera desde \(d.formatted(date: .omitted, time: .shortened))")) }
        let quem: String
        switch item.origem {
        case "lane": quem = String(localized: "a lane chamou")
        case "triagem": quem = String(localized: "a triagem chamou")
        case "gestor": quem = String(localized: "o gestor chamou")
        default: quem = String(localized: "etiqueta posta à mão")
        }
        partes.append(quem)
        return partes.joined(separator: " · ")
    }

    @ViewBuilder
    private func detalhe(_ item: ItemCaixa) -> some View {
        let ocupado = caixa.enviando.contains(item.card) || caixa.respondidas.contains(item.perguntaId)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Text(item.card)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Aurora.tinta)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Aurora.gradienteBotao))
                Text(item.titulo)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                RotuloSecao(titulo: "Pendência", icone: "questionmark.circle")
                Text(item.pendencia.isEmpty ? (item.motivo.isEmpty ? String(localized: "Sem resumo ainda: veja o card no Linear.") : item.motivo)
                                            : item.pendencia)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Aurora.texto2)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.pendencia.isEmpty && !item.motivo.isEmpty {
                    Text(String(localized: "Motivo: \(item.motivo)"))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Aurora.apagado)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !item.opcoes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RotuloSecao(titulo: "Decisões sugeridas", icone: "list.bullet")
                    ForEach(item.opcoes) { op in
                        VStack(alignment: .leading, spacing: 4) {
                            botaoOpcao(op, item: item, recomendada: op.letra == item.recomenda).disabled(ocupado)
                            Text(String(localized: "O que acontece: \(oQueAcontece(.opcao(op, comentario: ""), item))"))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Aurora.apagado)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 12)
                        }
                    }
                    if !item.porque.isEmpty {
                        Text(String(localized: "Por que \(item.recomenda): \(item.porque)"))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Aurora.mudo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            TextField(String(localized: "Responder no card…"), text: $resposta, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Aurora.texto)
                .lineLimit(2...5)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.24)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            HStack(spacing: 8) {
                Button { caixa.decidir(.responder(resposta, liberar: false), item: item); resposta = "" } label: {
                    Text(String(localized: "Responder"))
                }
                .buttonStyle(EstiloBotaoPrincipal(compacto: true))
                .disabled(resposta.trimmingCharacters(in: .whitespaces).isEmpty || ocupado)
                .help(oQueAcontece(.responder(resposta, liberar: false), item))

                Button { caixa.decidir(.responder(resposta, liberar: true), item: item); resposta = "" } label: {
                    Text(String(localized: "Responder e liberar"))
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                .disabled(ocupado)
                .help(oQueAcontece(.responder(resposta, liberar: true), item))

                Button { caixa.decidir(.liberar, item: item) } label: {
                    Text(String(localized: "Liberar"))
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                .disabled(ocupado)
                .help(oQueAcontece(.liberar, item))

                Spacer()

                if let u = URL(string: item.url), !item.url.isEmpty {
                    Button { NSWorkspace.shared.open(u) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 9.5, weight: .semibold))
                            Text(String(localized: "Abrir no Linear"))
                        }
                    }
                    .buttonStyle(EstiloBotaoSecundario(compacto: true))
                }
                Button(role: .destructive) { confirmarCancelar = true } label: {
                    Text(String(localized: "Cancelar o card…"))
                        .foregroundStyle(Aurora.vermelho.opacity(0.9))
                }
                .buttonStyle(EstiloBotaoSecundario(compacto: true))
                .disabled(ocupado)
            }
            if let e = caixa.erros[item.card] {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10))
                    Text(e)
                }
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Aurora.vermelho)
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog(String(localized: "Cancelar \(item.card)?"), isPresented: $confirmarCancelar) {
            Button(String(localized: "Cancelar o card e limpar as pendências"), role: .destructive) { caixa.decidir(.cancelar, item: item) }
        } message: {
            Text(oQueAcontece(.cancelar, item))
        }
    }

    private func botaoOpcao(_ op: OpcaoCaixa, item: ItemCaixa, recomendada: Bool) -> some View {
        Button { caixa.decidir(.opcao(op, comentario: resposta), item: item); resposta = "" } label: {
            HStack(spacing: 10) {
                Text(op.letra)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(recomendada ? Aurora.tinta : Aurora.texto2)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(recomendada
                                              ? AnyShapeStyle(Aurora.gradienteBotao)
                                              : AnyShapeStyle(Color.white.opacity(0.08))))
                Text(op.texto)
                    .font(.system(size: 12.5, weight: recomendada ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(Aurora.texto)
                    .multilineTextAlignment(.leading)
                Spacer()
                if recomendada {
                    PilulaAurora(titulo: "recomendada", cor: Aurora.verde, compacta: true)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(recomendada ? Aurora.acento.opacity(0.10) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(recomendada ? Aurora.acento.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
    }
}
