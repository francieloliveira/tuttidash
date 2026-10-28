import AppKit
import SwiftUI
import GastoCore

/// App de barra de menus. Arranca como accessory (só a pílula). Com o painel aberto,
/// JanelaPainel pede .regular (Dock e Cmd-Tab) e volta a .accessory ao fechar (FRA-553).
/// Lê o ledger da ferramenta `gasto`,
/// os logs e o estado das lanes. A janela de Ajustes grava o config e a lista `enabled`.
/// O botão desativar do notch só chama `lanes_ctl.py disable` e não cria `PAUSE`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let modelo = ModeloNotch()
    private var controlador: ControladorNotch?
    private var barra: ControladorBarra?
    private var itemResumo: NSMenuItem?
    private var itemUso: NSMenuItem?
    private var itemRetomar: NSMenuItem?
    private var timer: Timer?
    private let fila = DispatchQueue(label: "tuttidash.carregar", qos: .utility)
    private let carregador = Carregador()
    private var carregando = false
    /// Toggle de lane no meio de uma leitura: a leitura em curso ainda não viu o arquivo novo.
    private var leituraPendente = false
    private let coletorUso = ColetorUso()
    private var timerUso: Timer?
    private var coletandoUso = false
    /// Última leitura do disco das lanes, para remontar o painel quando o uso das contas chega.
    private var entradaPainel = EntradaPainel.vazia
    private var execucoesPainel: [Execucao] = []
    private var ordinaisPainel: [String: Int] = [:]
    /// Dados e hora do último `MontadorPainel.montar` (FRA-582): com os mesmos dados, não remonta.
    private var ultimaMontagem: (dados: DadosPainel, em: Date)?
    /// `--foto <arquivo.png>`: depois da primeira leitura, desenha a própria janela num PNG
    /// (conferência de layout sem precisar de permissão de gravação de tela) e segue rodando.
    private var caminhoFoto: URL?
    /// «Atualizar agora» no cabeçalho: avisa quando a leitura termina.
    private var avisarAoAtualizar = false

    // Intervalos (dados 30 s, uso 120 s: endpoints limitados por IP) vivem em `PoliticaAtualizacao`.

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Configuracao.copiarPastaAntiga()
        Self.migrarPreferenciasLanekeeper()
        Self.migrarPreferencias()
        // Agentes passam a viver dentro do app (SMAppService); reverte sozinho se falhar.
        // Se uma tentativa já foi revertida, não tenta de novo a cada abertura (evita bootout repetido).
        if !UserDefaults.standard.bool(forKey: "agentesSMAppServiceRevertido") { Task.detached(priority: .utility) {
            let a = AgentesDoApp(registro: RegistroSMAppService())
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TranscentIA/tuttidash-agentes.log")
            for l in AgentesDoApp.todos {
                let r = a.migrar(l)
                if case .revertido = r { UserDefaults.standard.set(true, forKey: "agentesSMAppServiceRevertido") }
                let linha = "\(Date()) \(l.novo): \(r) status=\(a.registro.status(l.plist))\n"
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(linha.utf8)); try? h.close() }
                else { try? linha.write(to: log, atomically: true, encoding: .utf8) }
            }
        } }
        if PrimeiraAbertura.precisa() {
            JanelaPrimeiraAbertura.compartilhada.mostrar { [weak self] in self?.atualizar(); self?.atualizarUso() }
        }
        let args = ProcessInfo.processInfo.arguments
        let fixo = args.contains("--expandido") || ProcessInfo.processInfo.environment["NOTCH_GASTO_EXPANDIDO"] == "1"

        modelo.abrirCard = { [weak self] card in
            // workspace vem da API do Linear (Ajustes › Integrações), gravado em linear.workspace_url
            guard let base = self?.modelo.config.workspaceLinear else {
                CentralAvisos.compartilhada.erro(String(localized: "Linear não conectado"), String(localized: "Conecte o Linear em Ajustes › Contas para abrir os cards."))
                self?.abrirConfig(); return
            }
            if let url = EnderecosPainel.issueLinear(workspace: base, card: card),
               NSWorkspace.shared.open(url) {
                CentralAvisos.compartilhada.info(String(localized: "Abrindo \(card) no Linear"))
            } else {
                CentralAvisos.compartilhada.erro(String(localized: "Não deu para abrir \(card)"), String(localized: "O endereço do card não abriu no navegador."))
            }
        }
        modelo.abrirEndereco = { url in
            guard url.scheme == "https", url.host == "github.com" else { return }
            if NSWorkspace.shared.open(url) {
                CentralAvisos.compartilhada.info(String(localized: "Abrindo o pull request"))
            } else {
                CentralAvisos.compartilhada.erro(String(localized: "Não deu para abrir o pull request"), String(localized: "O endereço não abriu no navegador."))
            }
        }
        modelo.abrirConfig = { [weak self] in self?.abrirConfig() }
        modelo.copiar = { texto in
            NSPasteboard.general.clearContents()
            let ok = NSPasteboard.general.setString(texto, forType: .string)
            if ok { CentralAvisos.compartilhada.ok(String(localized: "Copiado"), String(localized: "Cole no Terminal para usar.")) }
            else { CentralAvisos.compartilhada.erro(String(localized: "Não deu para copiar"), String(localized: "A área de transferência recusou o texto.")) }
        }
        modelo.atualizarAgora = { [weak self] in
            guard let self else { return }
            self.avisarAoAtualizar = true
            self.atualizar(); self.atualizarUso()
        }
        modelo.abrirPainel = { [weak self] in
            guard let self else { return }
            JanelaPainel.compartilhada.mostrar(modelo: self.modelo)
        }
        modelo.desativarLane = { [weak self] lane in self?.desativar(lane) }
        modelo.ativarLane = { [weak self] lane in self?.ativar(lane) }
        NavegacaoPainel.compartilhada.aoSalvar = { [weak self] in self?.atualizar() }

        if let i = args.firstIndex(of: "--foto-painel"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                let pagina = args.firstIndex(of: "--foto-pagina").flatMap { j in
                    j + 1 < args.count ? PaginaPainel(rawValue: args[j + 1]) : nil
                } ?? .dashboard
                let secao = args.firstIndex(of: "--foto-secao").flatMap { j in
                    j + 1 < args.count ? IdSecaoAjustes(rawValue: args[j + 1]) : nil
                }
                // FRA-531: `--foto-aviso` mostra um aviso de exemplo na foto (só para o PR).
                if args.contains("--foto-aviso") {
                    CentralAvisos.compartilhada.ok(String(localized: "Salvo: Aviso em (% do teto)"))
                }
                JanelaPainel.compartilhada.fotografar(url, pagina: pagina, secao: secao)
            }
        }
        if let i = args.firstIndex(of: "--foto"), i + 1 < args.count {
            caminhoFoto = URL(fileURLWithPath: args[i + 1])
        }
        if args.contains("--painel") || args.contains("--foto-painel") { modelo.abrirPainel() }
        // FRA-522: a pílula vive na barra de menus; a pílula antiga sobre o notch só com a opção ligada.
        if PreferenciaNotch.mostrar() { ligarNotch(fixo: fixo) }
        criarItemStatus()

        atualizar()
        timer = Timer.scheduledTimer(withTimeInterval: modelo.politica.intervaloDados, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.atualizar() }
        }
        timer?.tolerance = 5

        atualizarUso()
        timerUso = Timer.scheduledTimer(withTimeInterval: modelo.politica.intervaloUso, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.atualizarUso() }
        }
        timerUso?.tolerance = 15
    }

    /// Fechar a janela do painel deixa a pílula. Não é «Sair».
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        PoliticaDock.aoFecharPainel().destino == .encerrar
    }

    /// Clique no Dock com a janela minimizada (não conta como visível): o painel volta.
    /// Em accessory não há ícone no Dock; reabrir o app não força o painel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSApp.activationPolicy() == .regular {
            modelo.abrirPainel()
        }
        return true
    }

    // MARK: Dados

    /// Ao abrir o painel: atualiza se a última leitura tem mais de 5 s.
    func atualizarSeAntigo() {
        if let em = modelo.atualizadoEm, Date().timeIntervalSince(em) < 5 { return }
        atualizar()
    }

    /// Limites das contas: um GET por conta com credencial (nada é gravado nas credenciais).
    func atualizarUso() {
        guard !coletandoUso else { return }
        coletandoUso = true
        modelo.medindoUso = true
        let cfg = modelo.config
        let coletor = coletorUso
        Task { [weak self] in
            let usos = await coletor.coletar(config: cfg)
            await MainActor.run {
                guard let self else { return }
                self.coletandoUso = false
                self.modelo.medindoUso = false
                self.modelo.usoEm = Date()
                let tinhaAlerta = self.modelo.alertaUso != nil
                if self.modelo.usos != usos { self.modelo.usos = usos }
                self.atualizarMenuUso(usos)
                if tinhaAlerta != (self.modelo.alertaUso != nil) { self.controlador?.pilulaMudou() }
                let snapshotMudou = self.publicarPainel()
                self.atualizarMenuLanes()
                if snapshotMudou { self.controlador?.painelMudou() }
            }
        }
    }

    func atualizar() {
        guard !carregando else { leituraPendente = true; return }
        carregando = true
        modelo.atualizando = true
        let carregador = self.carregador
        fila.async { [weak self] in
            let cfg = Configuracao.resolver()
            let res = carregador.carregar(config: cfg)
            let resumo = Agregador.resumir(execucoes: res.execucoes, estado: res.estado,
                                           teto: cfg.tetoSemanalUSD, avisoPct: cfg.avisoPct)
            let logDispatcher = cfg.logsDir.deletingLastPathComponent().appendingPathComponent("lanes-dispatcher.log")
            let entrada = LeitorPainelDisco.ler(pasta: cfg.stateDir, logDispatcher: logDispatcher, logsDir: cfg.logsDir)
            let ledgerExiste = res.ledgerExiste, logsExiste = res.logsDirExiste
            let retomadas = res.retomadas
            let execucoes = res.execucoes
            let ordinais = res.ordinais
            Task { @MainActor in
                guard let self else { return }
                self.carregando = false
                self.modelo.atualizando = false
                if self.avisarAoAtualizar {
                    self.avisarAoAtualizar = false
                    CentralAvisos.compartilhada.ok(String(localized: "Dados atualizados"))
                }
                self.modelo.config = cfg
                self.modelo.ledgerExiste = ledgerExiste
                self.modelo.logsDirExiste = logsExiste
                if self.modelo.resumo != resumo { self.modelo.resumo = resumo }
                if self.modelo.retomadas != retomadas { self.modelo.retomadas = retomadas }
                self.entradaPainel = entrada
                self.execucoesPainel = execucoes
                self.ordinaisPainel = ordinais
                let snapshotMudou = self.publicarPainel()
                self.atualizarMenuLanes()
                self.atualizarMenuRetomar(retomadas)
                self.modelo.atualizadoEm = Date()
                self.atualizarMenu(resumo)
                self.fotografarSePedido()
                // a altura do painel pode mudar com os dados
                if snapshotMudou {
                    Task { @MainActor [weak self] in self?.controlador?.painelMudou() }
                }
                if self.leituraPendente {
                    self.leituraPendente = false
                    self.atualizar()
                }
            }
        }
    }

    private func fotografarSePedido() {
        guard let url = caminhoFoto else { return }
        caminhoFoto = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.controlador?.fotografar(url)
        }
    }

    // MARK: Barra de menus

    private func ligarNotch(fixo: Bool = false) {
        guard controlador == nil else { return }
        let c = ControladorNotch(modelo: modelo, fixo: fixo)
        c.aoExpandir = { [weak self] in self?.atualizarSeAntigo() }
        controlador = c
    }

    @objc private func acaoNotch(_ item: NSMenuItem) {
        let ligar = !UserDefaults.standard.bool(forKey: PreferenciaNotch.chave)
        UserDefaults.standard.set(ligar, forKey: PreferenciaNotch.chave)
        item.state = ligar ? .on : .off
        if ligar { ligarNotch() } else { controlador?.janela.orderOut(nil); controlador = nil }
    }

    private func criarItemStatus() {
        let menu = NSMenu()
        let resumo = NSMenuItem(title: "Lendo o gasto…", action: nil, keyEquivalent: "")
        resumo.isEnabled = false
        menu.addItem(resumo)
        let uso = NSMenuItem(title: "Lendo os limites das contas…", action: nil, keyEquivalent: "")
        uso.isEnabled = false
        menu.addItem(uso)
        itemUso = uso
        let retomar = NSMenuItem(title: "", action: #selector(acaoRetomar), keyEquivalent: "")
        retomar.target = self
        retomar.isHidden = true
        menu.addItem(retomar)
        itemRetomar = retomar
        menu.addItem(.separator())
        let painel = NSMenuItem(title: "Abrir painel", action: #selector(acaoPainel), keyEquivalent: "p")
        painel.target = self
        menu.addItem(painel)
        let atualizar = NSMenuItem(title: "Atualizar agora", action: #selector(acaoAtualizar), keyEquivalent: "r")
        atualizar.target = self
        menu.addItem(atualizar)
        let config = NSMenuItem(title: "Ajustes…", action: #selector(acaoConfig), keyEquivalent: ",")
        config.target = self
        menu.addItem(config)
        let tela = NSMenuItem(title: "Usar a tela principal em vez do notch", action: #selector(acaoTela), keyEquivalent: "")
        tela.target = self
        tela.state = ControladorNotch.usarTelaPrincipal ? .on : .off
        tela.toolTip = "Padrão: notch do MacBook (se houver). Ligado: topo da tela principal (a da barra de menus)."
        menu.addItem(tela)
        let notch = NSMenuItem(title: "Mostrar também a pílula antiga no notch", action: #selector(acaoNotch), keyEquivalent: "")
        notch.target = self
        notch.state = UserDefaults.standard.bool(forKey: PreferenciaNotch.chave) ? .on : .off
        menu.addItem(notch)
        menu.addItem(.separator())
        let sair = NSMenuItem(title: "Sair", action: #selector(acaoSair), keyEquivalent: "q")
        sair.target = self
        menu.addItem(sair)
        barra = ControladorBarra(modelo: modelo, menu: menu)
        // `--abrir-barra`: abre o painel da pílula sozinho (conferência e screenshot).
        if ProcessInfo.processInfo.arguments.contains("--abrir-barra") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.barra?.alternar()
            }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--foto-barra"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            let url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.barra?.fotografarPainel(url)
            }
        }
        itemResumo = resumo
    }

    /// Lista as lanes ligadas no menu da barra, com o nome claro (Grok CLI, não `grok`).
    /// O ponto do título é o mesmo «aceso» da pílula: lane ligada. Não grava `enabled`.
    private func atualizarMenuLanes() {
        guard let menu = barra?.menu, let uso = itemUso else { return }
        let tag = 522
        for item in menu.items where item.tag == tag { menu.removeItem(item) }
        var indice = menu.index(of: uso) + 1
        guard indice > 0 else { return }
        let linhas = ResumoBarra.linhasMenu(modelo.snapshot)
        if linhas.isEmpty {
            guard modelo.snapshot != nil else { return }
            let item = NSMenuItem(title: "Nenhuma lane ligada", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.tag = tag
            menu.insertItem(item, at: indice)
            return
        }
        for linha in linhas {
            let item = NSMenuItem(title: "● \(linha.texto)", action: #selector(acaoAbrirBarra), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.toolTip = linha.rodando ? "Lane ligada, com card rodando" : "Lane ligada"
            menu.insertItem(item, at: indice)
            indice += 1
        }
    }

    @objc private func acaoAbrirBarra() { barra?.alternar() }

    private func atualizarMenu(_ r: Resumo) {
        var t = "Semana \(r.numeroSemana): \(Formato.usd(r.gastoSemana))"
        if let teto = r.teto { t += " de \(Formato.usd(teto))" } else { t += " · sem teto definido" }
        if r.desconhecidasSemana > 0 { t += " + \(r.desconhecidasSemana) desconh." }
        itemResumo?.title = t
    }

    private func atualizarMenuUso(_ usos: [UsoConta]) {
        guard !usos.isEmpty else {
            itemUso?.title = modelo.config.usoContas ? "Limites das contas: sem dado"
                                                     : "Limites das contas: desligado na config"
            return
        }
        let partes = usos.map { u -> String in
            guard let j = u.critica else { return "\(nomeConta(u)) sem dado" }
            return "\(nomeConta(u)) \(Formato.pct(j.pct)) (\(j.rotulo))"
        }
        itemUso?.title = "Limites: " + partes.joined(separator: " · ")
    }

    /// Só a lane parada mais nova; o painel mostra as outras.
    private func atualizarMenuRetomar(_ retomadas: [Retomada]) {
        guard let r = retomadas.first else {
            itemRetomar?.isHidden = true
            return
        }
        itemRetomar?.title = "Copiar para retomar \(r.card) (\(r.lane), \(r.rotulo))"
        itemRetomar?.toolTip = r.comando
        itemRetomar?.isHidden = false
    }

    @objc private func acaoRetomar() {
        if let r = modelo.retomadas.first { modelo.copiar(r.comando) }
    }

    /// Remonta o retrato com a última leitura e o uso das contas. Não grava estado.
    /// FRA-582: com os mesmos dados e dentro de `PoliticaAtualizacao.validadePainel`, o snapshot
    /// publicado continua valendo e o montador não roda. Devolve `true` só quando o snapshot mudou.
    private func publicarPainel() -> Bool {
        let dados = DadosPainel(entrada: entradaPainel, execucoes: execucoesPainel, usos: modelo.usos,
                                taxaUsdBrl: modelo.config.taxaUsdBrl, ordinais: ordinaisPainel)
        let agora = Date()
        if let ultima = ultimaMontagem, ultima.dados == dados,
           PoliticaAtualizacao.painelVale(montadoEm: ultima.em, agora: agora) {
            return false
        }
        let snap = MontadorPainel.montar(entrada: dados.entrada, execucoes: dados.execucoes, usos: dados.usos,
                                        agora: agora, taxaUsdBrl: dados.taxaUsdBrl, ordinais: dados.ordinais)
        ultimaMontagem = (dados, agora)
        let mudou = modelo.snapshot != snap
        if mudou { modelo.snapshot = snap }
        if modelo.laneEmFoco == nil { modelo.laneEmFoco = snap.laneSugerida }
        return mudou
    }

    /// Desativa a lane pelo `lanes_ctl.py`. Não escreve `enabled` e não cria PAUSE.
    private func desativar(_ lane: String) {
        let alerta = NSAlert()
        alerta.messageText = "Desativar a lane \(lane)?"
        alerta.informativeText = "O dispatcher para de dar cards a esta lane. Só voltar a ligar com lanes_ctl.py enable."
        alerta.addButton(withTitle: "Cancelar")
        alerta.addButton(withTitle: "Desativar")
        NSApp.activate(ignoringOtherApps: true)
        guard alerta.runModal() == .alertSecondButtonReturn else { return }
        let script = modelo.config.stateDir.appendingPathComponent("lanes_ctl.py").path
        guard FileManager.default.fileExists(atPath: script) else {
            modelo.avisoCtl = "Não achei o lanes_ctl.py. Nada foi alterado."
            return
        }
        modelo.avisoCtl = "Desativando \(lane)…"
        modelo.lanesEmAcao.insert(lane)
        Task.detached { [weak self] in
            let resultado = AcaoDesativar.executar(lane: lane, script: script) { pedido in
                let processo = Process()
                processo.executableURL = URL(fileURLWithPath: pedido.executavel)
                processo.arguments = pedido.argumentos
                do { try processo.run() } catch { return 1 }
                processo.waitUntilExit()
                return processo.terminationStatus
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelo.lanesEmAcao.remove(lane)
                if !resultado.executou {
                    self.modelo.avisoCtl = "Lane inválida. Nada foi alterado."
                } else if resultado.codigo == 0 {
                    self.modelo.avisoCtl = "Lane \(lane) desativada."
                } else {
                    self.modelo.avisoCtl = "lanes_ctl saiu com código \(resultado.codigo)."
                }
                self.atualizar()
            }
        }
    }

    /// Reativa a lane pelo `lanes_ctl.py enable <lane>`. Sem confirmação (ação reversível).
    private func ativar(_ lane: String) {
        let script = modelo.config.stateDir.appendingPathComponent("lanes_ctl.py").path
        guard FileManager.default.fileExists(atPath: script) else {
            modelo.avisoCtl = "Não achei o lanes_ctl.py. Nada foi alterado."
            return
        }
        modelo.avisoCtl = "Ativando \(lane)…"
        modelo.lanesEmAcao.insert(lane)
        Task.detached { [weak self] in
            let processo = Process()
            processo.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            processo.arguments = [script, "enable", lane]
            do { try processo.run() } catch {
                await MainActor.run {
                    self?.modelo.lanesEmAcao.remove(lane)
                    self?.modelo.avisoCtl = "Não foi possível ativar \(lane)."
                }
                return
            }
            processo.waitUntilExit()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelo.lanesEmAcao.remove(lane)
                if processo.terminationStatus == 0 {
                    self.modelo.avisoCtl = "Lane \(lane) ativada."
                } else {
                    self.modelo.avisoCtl = "lanes_ctl saiu com código \(processo.terminationStatus)."
                }
                self.atualizar()
            }
        }
    }

    @objc private func acaoPainel() { modelo.abrirPainel() }
    @objc private func acaoAtualizar() { atualizar(); atualizarUso() }
    @objc private func acaoConfig() { abrirConfig() }
    @objc private func acaoSair() { PresencaApp.sair() }
    @objc private func acaoTela(_ item: NSMenuItem) {
        ControladorNotch.usarTelaPrincipal.toggle()
        item.state = ControladorNotch.usarTelaPrincipal ? .on : .off
        controlador?.posicionar()
    }

    /// Logo do TuttiDash (template) para a barra de menus; o anel fica de reserva (FRA-523).
    static func iconeBarra() -> NSImage {
        if let u = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
           let img = NSImage(contentsOf: u) {
            img.size = NSSize(width: img.size.width, height: img.size.height)
            img.isTemplate = true
            return img
        }
        return iconeAnel()
    }

    /// MIGRAÇÃO (FRA-523): copia as preferências do bundle `app.lanekeeper.mac`, uma vez.
    static func migrarPreferenciasLanekeeper(padrao: UserDefaults = .standard,
                                             antigo: UserDefaults? = UserDefaults(suiteName: Legado.servicoCofreAntigo)) {
        let marca = "migrouDeLanekeeper"
        guard !padrao.bool(forKey: marca) else { return }
        for (k, v) in antigo?.persistentDomain(forName: Legado.servicoCofreAntigo) ?? [:] where padrao.object(forKey: k) == nil {
            padrao.set(v, forKey: k)
        }
        padrao.set(true, forKey: marca)
    }

    /// Anel pequeno (template) para a barra de menus.
    static func iconeAnel() -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let trilha = NSBezierPath()
            trilha.appendArc(withCenter: c, radius: 5.6, startAngle: 0, endAngle: 360)
            trilha.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            trilha.stroke()
            let arco = NSBezierPath()
            arco.appendArc(withCenter: c, radius: 5.6, startAngle: 90, endAngle: 90 - 300, clockwise: true)
            arco.lineWidth = 2.2
            arco.lineCapStyle = .round
            NSColor.black.setStroke()
            arco.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// MIGRAÇÃO (FRA-299): traz `usarTelaPrincipal` do bundle antigo (`Legado.bundleAntigo`), uma vez.
    static func migrarPreferencias(padrao: UserDefaults = .standard,
                                   antigo: UserDefaults? = UserDefaults(suiteName: Legado.bundleAntigo)) {
        let chave = "usarTelaPrincipal"
        guard padrao.object(forKey: chave) == nil, let v = antigo?.object(forKey: chave) as? Bool else { return }
        padrao.set(v, forKey: chave)
    }

    // MARK: Ajustes (FRA-296): janela SwiftUI que grava o config.json pelo GastoCore

    /// FRA-524: Ajustes ficam na janela principal, no item "Ajustes" da barra lateral.
    func abrirConfig() {
        NavegacaoPainel.compartilhada.aoSalvar = { [weak self] in self?.atualizar() }
        NavegacaoPainel.compartilhada.abrirAjustes()
        JanelaPainel.compartilhada.mostrar(modelo: modelo)
    }
}

/// Tudo o que `MontadorPainel.montar` recebe, menos o relógio (FRA-582).
private struct DadosPainel: Equatable {
    var entrada: EntradaPainel
    var execucoes: [Execucao]
    var usos: [UsoConta]
    var taxaUsdBrl: Double?
    var ordinais: [String: Int]
}
