import AppKit
import SwiftUI
import GastoCore

/// Janela de Ajustes (FRA-296): substitui abrir o config.json no editor de texto.
@MainActor
final class JanelaAjustes {
    static let compartilhada = JanelaAjustes()
    private var janela: NSWindow?

    /// FRA-524: a janela separada foi aposentada. Abre a janela principal em Ajustes.
    func mostrar(aoSalvar: @escaping () -> Void) {
        NavegacaoPainel.compartilhada.aoSalvar = aoSalvar
        NavegacaoPainel.compartilhada.abrirAjustes()
        if let m = JanelaPainel.compartilhada.modeloAtual { JanelaPainel.compartilhada.mostrar(modelo: m); return }
        mostrarAntiga(aoSalvar: aoSalvar)
    }

    /// Só quando a janela principal ainda não tem modelo (não acontece no app em uso).
    private func mostrarAntiga(aoSalvar: @escaping () -> Void) {
        if janela == nil {
            let host = NSHostingController(rootView: TelaAjustes(aoSalvar: aoSalvar))
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Ajustes")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 480))
            w.center()
            janela = w
        }
        NSApp.activate(ignoringOtherApps: true)
        janela?.makeKeyAndOrderFront(nil)
    }
}

final class EstadoAjustes: ObservableObject {
    let modelo = ModeloAjustes()
    @Published var textos: [String: String] = [:]
    @Published var erros: [String: String] = [:]
    @Published var salvo: String?
    /// ✓ ao lado do campo recém-gravado, ! no erro (FRA-531).
    @Published var retorno: [String: EstadoAcao] = [:]
    private var gravados: [String: String] = [:]

    /// O texto do campo mudou e ainda não foi gravado (só campos de texto).
    func pendente(_ c: CampoAjuste) -> Bool {
        switch c.tipo { case .booleano, .escolha: return false; default: break }
        guard let t = textos[c.chave], let g = gravados[c.chave] else { return false }
        return t != g
    }

    private func marcar(_ chaves: [String], _ e: EstadoAcao) {
        for k in chaves { retorno[k] = e }
        guard case .ok = e else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + MaquinaAcao.tempoOk) { [weak self] in
            for k in chaves { if case .ok = self?.retorno[k] { self?.retorno[k] = nil } }
        }
    }

    init() {
        recarregar()
    }

    func recarregar() {
        for c in CatalogoAjustes.abas().flatMap(\.campos) + CatalogoAjustes.secoes().flatMap(\.campos) {
            textos[c.chave] = modelo.texto(c)
            gravados[c.chave] = textos[c.chave]
        }
    }

    func restaurar(_ campos: [CampoAjuste], aoSalvar: () -> Void) {
        do {
            try modelo.restaurar(campos)
            for c in campos where c.chave.hasPrefix("agendas.") && c.chave.hasSuffix("_s") {
                try? GerenciadorAgendas(config: modelo.dados).intervaloMudou(chave: c.chave)
            }
            for c in campos { erros[c.chave] = nil }
            recarregar()
            salvo = String(localized: "Padrão restaurado em \(modelo.arquivo.path)")
            marcar(campos.map(\.chave), .ok("", em: Date()))
            Task { @MainActor in CentralAvisos.compartilhada.ok(String(localized: "Padrão restaurado"), String(localized: "\(campos.count) campo(s) voltaram ao padrão.")) }
            aoSalvar()
        } catch {
            salvo = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            let m = MaquinaAcao.motivo(error)
            Task { @MainActor in CentralAvisos.compartilhada.erro(String(localized: "Não deu para restaurar o padrão"), m) }
        }
    }

    func aplicar(_ c: CampoAjuste, aoSalvar: () -> Void) {
        let t = textos[c.chave] ?? ""
        do {
            try modelo.definir(c, t)
            erros[c.chave] = nil
            if c.chave.hasPrefix("agendas.") {
                try GerenciadorAgendas(config: modelo.dados).intervaloMudou(chave: c.chave)
            }
            salvo = String(localized: "Salvo em \(modelo.arquivo.path)")
            gravados[c.chave] = t
            marcar([c.chave], .ok("", em: Date()))
            let rotulo = c.rotulo
            Task { @MainActor in CentralAvisos.compartilhada.ok(String(localized: "Salvo: \(rotulo)")) }
            aoSalvar()
        } catch ModeloAjustes.Erro.invalido(let m) {
            erros[c.chave] = m
            marcar([c.chave], .erro(m, em: Date()))
        } catch {
            erros[c.chave] = String(localized: "Não foi possível gravar: \(error.localizedDescription)")
            marcar([c.chave], .erro(erros[c.chave] ?? "", em: Date()))
            let m = erros[c.chave] ?? ""
            Task { @MainActor in CentralAvisos.compartilhada.erro(String(localized: "Não deu para gravar"), m) }
        }
    }
}

struct TelaAjustes: View {
    var aoSalvar: () -> Void
    @StateObject private var estado = EstadoAjustes()
    private let abas = CatalogoAjustes.abas()

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                ForEach(abas) { aba in
                    if aba.linear {
                        AbaLinear(estado: EstadoLinear(modelo: estado.modelo), aoSalvar: aoSalvar)
                            .tabItem { Label(aba.nome, systemImage: aba.simbolo) }
                    } else {
                    Form {
                        if let nota = aba.nota { Text(nota).foregroundStyle(.secondary) }
                        if aba.agendas { SecaoAgendas(estado: EstadoAgendas(modelo: estado.modelo)) }
                        if aba.contas { SecaoContas(modelo: estado.modelo, aoSalvar: aoSalvar) }
                        if aba.lanesHabilitadas { SecaoLanesHabilitadas() }
                        if aba.modelosLane { SecaoModeloLanes(modelo: estado.modelo, aoSalvar: aoSalvar) }
                        if aba.projetos { SecaoProjetos(estado: EstadoProjetos(modelo: estado.modelo)) }
                        if aba.gestaoLanes { SecaoGestaoLanes(estado: EstadoGestaoLanes(modelo: estado.modelo), aoSalvar: aoSalvar) }
                        ForEach(aba.campos) { c in LinhaCampo(campo: c, estado: estado, aoSalvar: aoSalvar) }
                    }
                    .formStyle(.grouped)
                    .tabItem { Label(aba.nome, systemImage: aba.simbolo) }
                    }
                }
            }
            Text(estado.salvo ?? String(localized: "As mudanças são gravadas ao confirmar cada campo."))
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 600, minHeight: 440)
    }
}

struct LinhaCampo: View {
    let campo: CampoAjuste
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void

    private var texto: Binding<String> {
        Binding(get: { estado.textos[campo.chave] ?? campo.padrao },
                set: { estado.textos[campo.chave] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch campo.tipo {
            case .booleano:
                Toggle(campo.rotulo, isOn: Binding(
                    get: { texto.wrappedValue == "true" },
                    set: { texto.wrappedValue = $0 ? "true" : "false"; estado.aplicar(campo, aoSalvar: aoSalvar) }))
            case let .escolha(ops):
                Picker(campo.rotulo, selection: Binding(
                    get: { texto.wrappedValue },
                    set: { texto.wrappedValue = $0; estado.aplicar(campo, aoSalvar: aoSalvar) })) {
                    ForEach(ops, id: \.self) { Text($0).tag($0) }
                }
            default:
                TextField(campo.rotulo, text: texto, prompt: Text(campo.padrao))
                    .onSubmit { estado.aplicar(campo, aoSalvar: aoSalvar) }
            }
            if let e = estado.erros[campo.chave] {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
