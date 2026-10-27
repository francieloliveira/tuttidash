import AppKit
import SwiftUI
import GastoCore

/// FRA-524: navegação da janela principal. O ⌘, e os outros atalhos de Ajustes abrem a
/// janela principal já no item "Ajustes" (antes abriam a janela separada).
@MainActor
final class NavegacaoPainel: ObservableObject {
    static let compartilhada = NavegacaoPainel()
    @Published var pagina: PaginaPainel = .dashboard
    @Published var secao: IdSecaoAjustes = .geral
    /// Busca nos Ajustes (vale para todas as seções).
    @Published var busca = ""
    var aoSalvar: () -> Void = {}

    func abrirAjustes(_ s: IdSecaoAjustes? = nil) {
        if let s { secao = s }
        pagina = .ajustes
    }
}

/// Uma seção de Ajustes (FRA-531): cabeçalho com o que a seção faz, busca, e os grupos.
/// Em «Avançado» cada grupo começa recolhido e a chave técnica aparece embaixo do campo.
struct PaginaAjustes: View {
    let secao: SecaoAjustes
    @StateObject private var estado = EstadoAjustes()
    @ObservedObject private var nav = NavegacaoPainel.compartilhada
    @State private var abertos: Set<String> = []
    private var aoSalvar: () -> Void { NavegacaoPainel.compartilhada.aoSalvar }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.e4) {
            HStack(alignment: .center, spacing: DS.e3) {
                IconeCartao(simbolo: secao.simbolo, tamanho: 40, tamanhoIcone: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(secao.nome).font(PV.fonte(20, .semibold)).foregroundStyle(PV.texto)
                    Text(secao.subtitulo).font(PV.fonte(13)).foregroundStyle(PV.mudo)
                }
                Spacer(minLength: DS.e4)
                CampoBuscaAjustes(texto: $nav.busca)
            }
            .padding(.horizontal, DS.e5).padding(.top, DS.e3)

            if nav.busca.trimmingCharacters(in: .whitespaces).isEmpty {
                Form {
                    ForEach(secao.grupos) { g in grupo(g) }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
            } else {
                ResultadosBusca(termo: nav.busca, estado: estado, aoSalvar: aoSalvar)
            }
            Text(String(localized: "As mudanças são gravadas na hora. Nos campos de texto, aperte Enter para gravar."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DS.e5 + 4).padding(.bottom, DS.e3)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .id(secao.id)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private func temTitulo(_ b: BlocoAjustes) -> Bool { b == .quemCuida || b == .modeloLanes || b == .lanesHabilitadas }

    @ViewBuilder
    private func grupo(_ g: GrupoAjustes) -> some View {
        let aberto = !g.recolhido || abertos.contains(g.id)
        if g.recolhido {
            Section {
                linhaRecolhivel(g, aberto: aberto)
                if aberto {
                    ForEach(g.campos) { c in LinhaCampoAjuste(campo: c, estado: estado, aoSalvar: aoSalvar, mostrarChave: secao.mostraChaves) }
                }
            }
            if aberto { ForEach(Array(g.blocos.enumerated()), id: \.offset) { _, b in bloco(b) } }
        } else if g.campos.isEmpty && g.blocos.contains(where: temTitulo) {
            ForEach(Array(g.blocos.enumerated()), id: \.offset) { _, b in bloco(b) }
        } else if g.campos.isEmpty {
            Section {} header: { cabecalho(g, recolhivel: false, aberto: true) }
            ForEach(Array(g.blocos.enumerated()), id: \.offset) { _, b in bloco(b) }
        } else {
            Section {
                ForEach(g.campos) { c in LinhaCampoAjuste(campo: c, estado: estado, aoSalvar: aoSalvar, mostrarChave: secao.mostraChaves) }
            } header: { cabecalho(g, recolhivel: false, aberto: true) }
            ForEach(Array(g.blocos.enumerated()), id: \.offset) { _, b in bloco(b) }
        }
    }

    /// Linha clicável de um grupo de «Avançado»: abre e fecha com animação.
    private func linhaRecolhivel(_ g: GrupoAjustes, aberto: Bool) -> some View {
        HStack(alignment: .center, spacing: DS.e3) {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(PV.mudo)
                .rotationEffect(.degrees(aberto ? 90 : 0))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.nome).font(PV.fonte(13.5, .semibold)).foregroundStyle(PV.texto)
                if let a = g.ajuda { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(aberto ? nil : 1) }
            }
            Spacer()
            if aberto && !g.campos.isEmpty {
                Button(String(localized: "Restaurar padrão")) { estado.restaurar(g.campos, aoSalvar: aoSalvar) }
                    .buttonStyle(.link)
            } else if !g.campos.isEmpty {
                Text(String(localized: "\(g.campos.count) opções")).font(.caption).foregroundStyle(PV.apagado)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            comAnimacao(DS.suave) { if abertos.contains(g.id) { abertos.remove(g.id) } else { abertos.insert(g.id) } }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(g.nome)
    }

    private func cabecalho(_ g: GrupoAjustes, recolhivel: Bool, aberto: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if recolhivel {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(PV.mudo)
                    .rotationEffect(.degrees(aberto ? 90 : 0))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(g.nome).font(.headline).foregroundStyle(.white)
                if let a = g.ajuda, !recolhivel { Text(a).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !g.campos.isEmpty && aberto {
                Button(String(localized: "Restaurar padrão")) { estado.restaurar(g.campos, aoSalvar: aoSalvar) }
                    .buttonStyle(.link)
                    .help(String(localized: "Volta os campos deste grupo ao padrão"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard recolhivel else { return }
            comAnimacao(DS.suave) { if abertos.contains(g.id) { abertos.remove(g.id) } else { abertos.insert(g.id) } }
        }
        .accessibilityAddTraits(recolhivel ? .isButton : [])
    }

    @ViewBuilder
    private func bloco(_ b: BlocoAjustes) -> some View {
        switch b {
        case .lanesHabilitadas: SecaoLanesHabilitadas()
        case .modeloLanes: SecaoModeloLanes(modelo: estado.modelo, aoSalvar: aoSalvar)
        case .projetos: SecaoProjetos(estado: EstadoProjetos(modelo: estado.modelo))
        case .contas: SecaoContas(modelo: estado.modelo, aoSalvar: aoSalvar)
        case .quemCuida: SecaoGestaoLanes(estado: EstadoGestaoLanes(modelo: estado.modelo), aoSalvar: aoSalvar)
        case .agentesSegundoPlano: SecaoAgendas(estado: EstadoAgendas(modelo: estado.modelo))
        case .linear: AbaLinear(estado: EstadoLinear(modelo: estado.modelo), aoSalvar: aoSalvar, embutido: true)
        case .jobsAgendados: BlocoJobs(modelo: estado.modelo)
        case .linearLeitura: BlocoLinearLeitura(modelo: estado.modelo)
        case .manifestos: BlocoManifestos()
        }
    }
}

/// Campo de busca dos Ajustes (nome, explicação ou chave).
struct CampoBuscaAjustes: View {
    @Binding var texto: String
    @FocusState private var foco: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(PV.mudo)
            TextField(String(localized: "Buscar nos Ajustes"), text: $texto)
                .textFieldStyle(.plain).focused($foco)
            if !texto.isEmpty {
                Button { texto = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PV.apagado) }
                    .buttonStyle(.plain).help(String(localized: "Limpar busca"))
            }
        }
        .font(PV.fonte(13))
        .padding(.horizontal, 10).frame(width: 260, height: 32)
        .background(RoundedRectangle(cornerRadius: DS.raioP + 1).fill(PV.campo))
        .overlay(RoundedRectangle(cornerRadius: DS.raioP + 1).strokeBorder(foco ? PV.azul.opacity(0.7) : PV.campoBorda, lineWidth: 1))
        .animation(DS.anim(DS.suave), value: foco)
    }
}

/// Resultado da busca: o campo já editável, com a seção e o grupo onde ele mora.
struct ResultadosBusca: View {
    let termo: String
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void

    var body: some View {
        let r = CatalogoAjustes.buscar(termo)
        let secoes = Dictionary(uniqueKeysWithValues: CatalogoAjustes.secoes().map { ($0.id, $0.nome) })
        Form {
            if r.isEmpty {
                Section { Text(String(localized: "Nada encontrado para «\(termo)».")).foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(r) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                NavegacaoPainel.compartilhada.busca = ""
                                NavegacaoPainel.compartilhada.abrirAjustes(item.secao)
                            } label: {
                                Text("\(secoes[item.secao] ?? "") › \(item.grupo)").font(.caption).foregroundStyle(PV.azul)
                            }
                            .buttonStyle(.plain)
                            LinhaCampoAjuste(campo: item.campo, estado: estado, aoSalvar: aoSalvar, mostrarChave: item.secao == .avancado)
                        }
                    }
                } header: {
                    Text(String(localized: "\(r.count) resultado(s)")).font(.headline).foregroundStyle(.white)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }
}

/// Campo com rótulo, valor em pt-BR, faixa válida e ajuda curta. Mostra ✓ ao gravar e ! no erro.
struct LinhaCampoAjuste: View {
    let campo: CampoAjuste
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void
    var mostrarChave = false

    private var texto: Binding<String> {
        Binding(get: { estado.textos[campo.chave] ?? campo.padrao },
                set: { estado.textos[campo.chave] = $0 })
    }

    private var ajuda: String {
        [campo.ajuda.isEmpty ? nil : campo.ajuda, campo.faixa].compactMap { $0 }.joined(separator: " · ")
    }

    private var pendente: Bool { estado.pendente(campo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.e2) {
                controle
                IndicadorAcao(estado: estado.retorno[campo.chave] ?? .ocioso)
            }
            if pendente {
                Text(String(localized: "Não gravado ainda. Aperte Enter para gravar."))
                    .font(.caption).foregroundStyle(PV.ambar)
                    .transition(.opacity)
            }
            if !ajuda.isEmpty { Text(ajuda).font(.caption).foregroundStyle(.secondary) }
            if mostrarChave { Text(verbatim: campo.chave).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(PV.apagado).textSelection(.enabled) }
            if let e = estado.erros[campo.chave] { Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PV.vermelho) }
        }
        .animation(DS.anim(DS.suave), value: pendente)
        .animation(DS.anim(DS.suave), value: estado.retorno[campo.chave])
    }

    @ViewBuilder
    private var controle: some View {
        switch campo.tipo {
        case .booleano:
            Toggle(campo.rotulo, isOn: Binding(
                get: { texto.wrappedValue == "true" },
                set: { texto.wrappedValue = $0 ? "true" : "false"; estado.aplicar(campo, aoSalvar: aoSalvar) }))
                .toggleStyle(.switch)
        case let .escolha(ops):
            let lista = ops.contains(texto.wrappedValue) ? ops : [texto.wrappedValue] + ops
            Picker(campo.rotulo, selection: Binding(
                get: { texto.wrappedValue },
                set: { texto.wrappedValue = $0; estado.aplicar(campo, aoSalvar: aoSalvar) })) {
                ForEach(lista, id: \.self) { Text(campo.nomeValor($0)).tag($0) }
            }
        default:
            TextField(campo.rotulo, text: texto, prompt: Text(campo.padrao.isEmpty ? String(localized: "padrão") : campo.padrao))
                .onSubmit { estado.aplicar(campo, aoSalvar: aoSalvar) }
        }
    }
}

/// Agendas que o app instala (agendas.jobs): só leitura, o resto sai de Intervalos.
struct BlocoJobs: View {
    let modelo: ModeloAjustes
    var body: some View {
        Section(String(localized: "Serviços agendados")) {
            ForEach(GerenciadorAgendas(config: modelo.dados).trabalhos) { t in
                LabeledContent(t.nome, value: String(localized: "padrão a cada \(t.intervaloPadrao) s"))
            }
        }
    }
}

struct BlocoLinearLeitura: View {
    let modelo: ModeloAjustes
    private func nome(_ k: String) -> String {
        switch k {
        case "linear.workspace_url": return String(localized: "Endereço do workspace")
        case "linear.team_name": return String(localized: "Time")
        case "linear.project_name": return String(localized: "Projeto")
        case "linear.state_in_progress_name": return String(localized: "Coluna Em andamento")
        case "linear.state_in_review_name": return String(localized: "Coluna Em revisão")
        case "linear.owner_label": return String(localized: "Etiqueta do dono")
        case "linear.alert_labels": return String(localized: "Etiquetas de alerta")
        case "linear.blocking_labels": return String(localized: "Etiquetas que bloqueiam")
        case "linear.diary_doc_id": return String(localized: "Documento do diário")
        default: return String(localized: "Serviço no Chaveiro")
        }
    }
    private func valor(_ k: String) -> String {
        guard let v = Configuracao.valor(k, em: modelo.dados) else { return String(localized: "não definido") }
        if let l = v as? [Any] { return l.map { "\($0)" }.joined(separator: ", ") }
        return "\(v)"
    }
    var body: some View {
        Section {
            ForEach(CatalogoAjustes.chavesLinearLeitura, id: \.self) { k in
                LabeledContent(nome(k)) { Text(valor(k)).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            }
        }
    }
}

/// Manifestos de agents.d: só leitura, com botão para abrir o arquivo.
struct BlocoManifestos: View {
    private let agentes = CatalogoAgentes.carregar()
    private func url(_ nome: String) -> URL? {
        CatalogoAgentes.diretorios().map { $0.appendingPathComponent("\(nome).json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    var body: some View {
        Section {
            ForEach(agentes, id: \.nome) { a in
                HStack {
                    Text(ClarezaCota.titulo(nome: a.nome, rotulo: a.rotulo))
                    Spacer()
                    Button(String(localized: "Abrir manifesto")) { if let u = url(a.nome) { NSWorkspace.shared.open(u) } }
                        .disabled(url(a.nome) == nil)
                }
            }
        }
    }
}
