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
        let passos: [String]
        do { passos = try CaixaDono.mutacoes(decisao, item: item, ids: arquivo.ids) } catch {
            erros[item.card] = error.localizedDescription
            return
        }
        guard let token = TokenLinear().ler() else {
            erros[item.card] = ErroLinear.semToken.localizedDescription
            return
        }
        erros[item.card] = nil
        enviando.insert(item.card)
        let conta = { () -> Bool in if case .responder(_, liberar: false) = decisao { return false }; return true }()
        if conta { respondidas.insert(item.perguntaId) }
        Task {
            do {
                try await CaixaDono.executar(passos, cliente: HTTPClienteLinear(), token: token)
                enviando.remove(item.card)
                CentralAvisos.compartilhada.ok(String(localized: "\(item.card): decisão enviada"))
            } catch {
                enviando.remove(item.card)
                respondidas.remove(item.perguntaId)
                erros[item.card] = error.localizedDescription
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
                Text(String(localized: "Respostas em aberto · \(caixa.abertas)")).font(PV.fonte(15, .semibold))
                if caixa.itens.isEmpty {
                    Text(String(localized: "Nada esperando por você agora."))
                        .font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
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
                    Text(String(localized: "Quando um card precisar de você, a pendência e as decisões aparecem aqui."))
                        .font(PV.fonte(13)).foregroundStyle(PV.mudo)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(14)
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
                HStack {
                    Text(item.card).font(PV.fonte(13.5, .semibold)).foregroundStyle(PV.texto)
                    Spacer()
                    if caixa.enviando.contains(item.card) {
                        ProgressView().controlSize(.small)
                    } else if respondida {
                        Text(String(localized: "enviado")).font(PV.fonte(11)).foregroundStyle(PV.verde)
                    }
                }
                Text(item.titulo).font(PV.fonte(12)).foregroundStyle(PV.texto2).lineLimit(1)
                Text(meta(item)).font(PV.fonte(11)).foregroundStyle(PV.mudo).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? PV.azulFundo : PV.interno))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sel ? PV.azul.opacity(0.6) : PV.linhaBorda, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
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
        VStack(alignment: .leading, spacing: 12) {
            Text("\(item.card) · \(item.titulo)").font(PV.fonte(15, .semibold)).lineLimit(2)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Pendência")).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                Text(item.pendencia.isEmpty ? (item.motivo.isEmpty ? String(localized: "Sem resumo ainda: veja o card no Linear.") : item.motivo)
                                            : item.pendencia)
                    .font(PV.fonte(13.5)).fixedSize(horizontal: false, vertical: true)
                if !item.pendencia.isEmpty && !item.motivo.isEmpty {
                    Text(String(localized: "Motivo: \(item.motivo)")).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !item.opcoes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Decisões sugeridas")).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    ForEach(item.opcoes) { op in
                        VStack(alignment: .leading, spacing: 3) {
                            botaoOpcao(op, item: item, recomendada: op.letra == item.recomenda).disabled(ocupado)
                            Text(String(localized: "O que acontece: \(oQueAcontece(.opcao(op, comentario: ""), item))"))
                                .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 12)
                        }
                    }
                    if !item.porque.isEmpty {
                        Text(String(localized: "Por que \(item.recomenda): \(item.porque)")).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    }
                }
            }
            TextField(String(localized: "Responder no card…"), text: $resposta, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack(spacing: 8) {
                Button(String(localized: "Responder")) { caixa.decidir(.responder(resposta, liberar: false), item: item); resposta = "" }
                    .disabled(resposta.trimmingCharacters(in: .whitespaces).isEmpty || ocupado)
                    .help(oQueAcontece(.responder(resposta, liberar: false), item))
                Button(String(localized: "Responder e liberar")) { caixa.decidir(.responder(resposta, liberar: true), item: item); resposta = "" }
                    .disabled(ocupado)
                    .help(oQueAcontece(.responder(resposta, liberar: true), item))
                Button(String(localized: "Liberar")) { caixa.decidir(.liberar, item: item) }.disabled(ocupado)
                    .help(oQueAcontece(.liberar, item))
                Spacer()
                if let u = URL(string: item.url), !item.url.isEmpty {
                    Button(String(localized: "Abrir no Linear")) { NSWorkspace.shared.open(u) }
                }
                Button(String(localized: "Cancelar o card…"), role: .destructive) { confirmarCancelar = true }.disabled(ocupado)
            }
            if let e = caixa.erros[item.card] {
                Text(e).font(PV.fonte(12)).foregroundStyle(PV.vermelho)
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
            HStack {
                Text("\(op.letra)) \(op.texto)").font(PV.fonte(13)).foregroundStyle(PV.texto)
                    .multilineTextAlignment(.leading)
                Spacer()
                if recomendada { Text(String(localized: "recomendada")).font(PV.fonte(11)).foregroundStyle(PV.verde) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(recomendada ? PV.azulFundo : PV.botao))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recomendada ? PV.azul.opacity(0.6) : PV.botaoBorda, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressionavel())
    }
}
