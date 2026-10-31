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

// MARK: - Página

/// Uma seção de Ajustes (FRA-531). O título e a busca ficam no cabeçalho da janela
/// (`CabecalhoPainel`): aqui só entram os grupos, para não repetir o cabeçalho duas vezes.
/// Em «Avançado» cada grupo começa recolhido e a chave técnica aparece embaixo do campo.
struct PaginaAjustes: View {
    let secao: SecaoAjustes
    @StateObject private var estado = EstadoAjustes()
    @ObservedObject private var nav = NavegacaoPainel.compartilhada
    @State private var abertos: Set<String> = []
    private var aoSalvar: () -> Void { NavegacaoPainel.compartilhada.aoSalvar }

    private var buscando: Bool {
        !nav.busca.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.e3) {
            if buscando {
                ResultadosBusca(termo: nav.busca, estado: estado, aoSalvar: aoSalvar)
            } else {
                Form {
                    ForEach(secao.grupos) { g in grupo(g) }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
            }
            rodape
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .id(secao.id)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var rodape: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10.5))
            Text(String(localized: "As mudanças são gravadas na hora. Nos campos de texto, aperte Enter para gravar."))
                .font(PV.fonte(11.5))
        }
        .foregroundStyle(PV.apagado)
        .padding(.horizontal, 30)
        .padding(.bottom, DS.e2)
    }

    @ViewBuilder
    private func grupo(_ g: GrupoAjustes) -> some View {
        let aberto = !g.recolhido || abertos.contains(g.id)
        if g.recolhido {
            Section {
                LinhaGrupoRecolhivel(grupo: g, aberto: aberto, estado: estado, aoSalvar: aoSalvar) {
                    comAnimacao(DS.suave) {
                        if abertos.contains(g.id) { abertos.remove(g.id) } else { abertos.insert(g.id) }
                    }
                }
                if aberto { conteudo(g) }
            }
        } else {
            Section {
                conteudo(g)
            } header: {
                CabecalhoGrupo(grupo: g, estado: estado, aoSalvar: aoSalvar)
            }
        }
    }

    /// Campos e blocos do grupo, na ordem do catálogo. Os blocos entram no mesmo cartão
    /// (`embutido`): o cabeçalho do grupo é o único título da seção.
    @ViewBuilder
    private func conteudo(_ g: GrupoAjustes) -> some View {
        ForEach(g.campos) { c in
            LinhaCampoAjuste(campo: c, estado: estado, aoSalvar: aoSalvar, mostrarChave: secao.mostraChaves)
        }
        ForEach(Array(g.blocos.enumerated()), id: \.offset) { _, b in bloco(b) }
    }

    @ViewBuilder
    private func bloco(_ b: BlocoAjustes) -> some View {
        switch b {
        case .lanesHabilitadas: SecaoLanesHabilitadas(embutido: true)
        case .modeloLanes: SecaoModeloLanes(modelo: estado.modelo, aoSalvar: aoSalvar, embutido: true)
        case .projetos: SecaoProjetos(estado: EstadoProjetos(modelo: estado.modelo), embutido: true)
        case .contas: SecaoContas(modelo: estado.modelo, aoSalvar: aoSalvar, embutido: true)
        case .quemCuida: SecaoGestaoLanes(estado: EstadoGestaoLanes(modelo: estado.modelo), aoSalvar: aoSalvar, embutido: true)
        case .agentesSegundoPlano: SecaoAgendas(estado: EstadoAgendas(modelo: estado.modelo), embutido: true)
        case .linear: AbaLinear(estado: EstadoLinear(modelo: estado.modelo), aoSalvar: aoSalvar, embutido: true)
        case .jobsAgendados: BlocoJobs(modelo: estado.modelo)
        case .linearLeitura: BlocoLinearLeitura(modelo: estado.modelo)
        case .manifestos: BlocoManifestos()
        case .ferramentas: SecaoFerramentas(embutido: true)
        case .revisaoAtual: BlocoRevisaoAtual(modelo: estado.modelo)
        }
    }
}

// MARK: - Cabeçalhos dos grupos

/// Cabeçalho de um grupo aberto: título, explicação e «Restaurar padrão» quando há campos.
private struct CabecalhoGrupo: View {
    let grupo: GrupoAjustes
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.e3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(grupo.nome).font(PV.fonte(15, .semibold)).foregroundStyle(PV.texto)
                if let ajuda = grupo.ajuda {
                    Text(ajuda).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.e4)
            if !grupo.campos.isEmpty {
                Button { estado.restaurar(grupo.campos, aoSalvar: aoSalvar) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "Restaurar padrão"))
                    }
                    .font(PV.fonte(11.5))
                    .foregroundStyle(PV.mudo)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Volta os campos deste grupo ao padrão"))
            }
        }
        .padding(.bottom, 3)
    }
}

/// Linha de um grupo de «Avançado»: abre e fecha com animação. O clique fica só na
/// parte do título, para não disparar junto com o botão «Restaurar padrão».
private struct LinhaGrupoRecolhivel: View {
    let grupo: GrupoAjustes
    let aberto: Bool
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void
    var alternar: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.e3) {
            Button(action: alternar) {
                HStack(alignment: .center, spacing: DS.e3) {
                    ZStack {
                        Circle().fill(PV.campo).frame(width: 24, height: 24)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(aberto ? PV.azul : PV.mudo)
                            .rotationEffect(.degrees(aberto ? 90 : 0))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grupo.nome).font(PV.fonte(13.5, .semibold)).foregroundStyle(PV.texto)
                        if let ajuda = grupo.ajuda {
                            Text(ajuda).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                                .lineLimit(aberto ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: DS.e4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(grupo.nome)
            .accessibilityAddTraits(.isButton)

            if aberto && !grupo.campos.isEmpty {
                Button(String(localized: "Restaurar padrão")) { estado.restaurar(grupo.campos, aoSalvar: aoSalvar) }
                    .buttonStyle(.link)
                    .font(PV.fonte(11.5))
            } else if !grupo.campos.isEmpty {
                Text(String(localized: "\(grupo.campos.count) opções"))
                    .font(PV.fonte(11)).foregroundStyle(PV.apagado)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Subtítulo dentro de um cartão de grupo (ex.: «Contas de uso» dentro de «Lanes ligadas»).
struct SubtituloAjuste: View {
    var texto: String
    var ajuda: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(texto).font(PV.fonte(12.5, .semibold)).foregroundStyle(PV.texto2)
            if let ajuda {
                Text(ajuda).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 1)
    }
}

// MARK: - Busca

/// Campo de busca dos Ajustes (nome, explicação ou chave).
struct CampoBuscaAjustes: View {
    @Binding var texto: String
    var largura: CGFloat = 260
    var altura: CGFloat = 32
    @FocusState private var foco: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(foco ? PV.azul : PV.mudo)
            TextField(String(localized: "Buscar nos Ajustes"), text: $texto)
                .textFieldStyle(.plain).focused($foco)
            if !texto.isEmpty {
                Button { texto = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PV.apagado) }
                    .buttonStyle(.plain).help(String(localized: "Limpar busca"))
            }
        }
        .font(PV.fonte(13))
        .padding(.horizontal, 10).frame(width: largura, height: altura)
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
                Section {
                    HStack(spacing: DS.e3) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(PV.apagado)
                        Text(String(localized: "Nada encontrado para «\(termo)»."))
                            .font(PV.fonte(13)).foregroundStyle(PV.mudo)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(r) { item in
                        VStack(alignment: .leading, spacing: DS.e2) {
                            Button {
                                NavegacaoPainel.compartilhada.busca = ""
                                NavegacaoPainel.compartilhada.abrirAjustes(item.secao)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("\(secoes[item.secao] ?? "") › \(item.grupo)")
                                        .font(PV.fonte(11.5))
                                }
                                .foregroundStyle(PV.azul)
                            }
                            .buttonStyle(.plain)
                            LinhaCampoAjuste(campo: item.campo, estado: estado, aoSalvar: aoSalvar,
                                            mostrarChave: item.secao == .avancado)
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    HStack {
                        Text(String(localized: "\(r.count) resultado(s)"))
                            .font(PV.fonte(15, .semibold)).foregroundStyle(PV.texto)
                        Spacer()
                    }
                    .padding(.bottom, 3)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Linha de campo

/// Campo com rótulo e ajuda à esquerda e o controle alinhado à direita, numa coluna só.
/// Mostra ✓ ao gravar e ! no erro. Campos de texto têm a moldura do app, para ficar claro
/// que são editáveis (no formulário nativo eles se confundiam com o valor em leitura).
struct LinhaCampoAjuste: View {
    let campo: CampoAjuste
    @ObservedObject var estado: EstadoAjustes
    var aoSalvar: () -> Void
    var mostrarChave = false

    @FocusState private var focado: Bool

    private var texto: Binding<String> {
        Binding(get: { estado.textos[campo.chave] ?? campo.padrao },
                set: { estado.textos[campo.chave] = $0 })
    }

    private var ajuda: String {
        [campo.ajuda.isEmpty ? nil : campo.ajuda, campo.faixa].compactMap { $0 }.joined(separator: " · ")
    }

    private var pendente: Bool { estado.pendente(campo) }

    private var ehNumero: Bool {
        if case .numero = campo.tipo { return true }
        return false
    }

    private var ehCaminho: Bool {
        if case .caminho = campo.tipo { return true }
        return false
    }

    private var fonteCampo: Font {
        if ehCaminho { return .system(size: 11.5, design: .monospaced) }
        if ehNumero { return .system(size: 12.5, design: .monospaced) }
        return PV.fonte(12.5)
    }

    private let larguraControle: CGFloat = 272
    private let larguraColuna: CGFloat = 296

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: DS.e4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(campo.rotulo)
                        .font(PV.fonte(13)).foregroundStyle(PV.texto)
                        .fixedSize(horizontal: false, vertical: true)
                    if !ajuda.isEmpty {
                        Text(ajuda).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if mostrarChave {
                        Text(verbatim: campo.chave)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PV.apagado).textSelection(.enabled)
                    }
                }
                Spacer(minLength: DS.e4)
                HStack(spacing: DS.e2) {
                    controle
                    IndicadorAcao(estado: estado.retorno[campo.chave] ?? .ocioso)
                }
                .frame(width: larguraColuna, alignment: .trailing)
            }
            if pendente {
                Text(String(localized: "Não gravado ainda. Aperte Enter para gravar."))
                    .font(PV.fonte(11.5)).foregroundStyle(PV.ambar)
                    .transition(.opacity)
            }
            if let e = estado.erros[campo.chave] {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(PV.fonte(11.5)).foregroundStyle(PV.vermelho)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
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
                .labelsHidden()
                .frame(width: larguraControle, alignment: .trailing)
        case let .escolha(ops):
            let lista = ops.contains(texto.wrappedValue) ? ops : [texto.wrappedValue] + ops
            Picker(campo.rotulo, selection: Binding(
                get: { texto.wrappedValue },
                set: { texto.wrappedValue = $0; estado.aplicar(campo, aoSalvar: aoSalvar) })) {
                ForEach(lista, id: \.self) { Text(campo.nomeValor($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: larguraControle, alignment: .trailing)
        default:
            TextField(campo.rotulo, text: texto,
                      prompt: Text(campo.padrao.isEmpty ? String(localized: "padrão") : campo.padrao))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(fonteCampo)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .frame(width: larguraControle, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PV.campo))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focado ? PV.azul.opacity(0.75) : PV.campoBorda, lineWidth: 1))
                .focused($focado)
                .onSubmit { estado.aplicar(campo, aoSalvar: aoSalvar) }
                .animation(DS.anim(DS.suave), value: focado)
        }
    }
}

// MARK: - Blocos só de leitura

/// Agendas que o app instala (agendas.jobs): só leitura, o resto sai de Intervalos.
struct BlocoJobs: View {
    let modelo: ModeloAjustes
    var body: some View {
        VStack(alignment: .leading, spacing: DS.e2) {
            SubtituloAjuste(texto: String(localized: "Serviços agendados"))
            ForEach(GerenciadorAgendas(config: modelo.dados).trabalhos) { t in
                HStack(alignment: .firstTextBaseline, spacing: DS.e3) {
                    Text(t.nome).font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                    Spacer(minLength: DS.e3)
                    Text(String(localized: "padrão a cada \(t.intervaloPadrao) s"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PV.mudo)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BlocoLinearLeitura: View {
    let modelo: ModeloAjustes
    private func nome(_ k: String) -> String {
        switch k {
        case "linear.workspace_url": return String(localized: "Endereço do workspace")
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
        VStack(alignment: .leading, spacing: DS.e2) {
            ForEach(CatalogoAjustes.chavesLinearLeitura, id: \.self) { k in
                HStack(alignment: .firstTextBaseline, spacing: DS.e3) {
                    Text(nome(k)).font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                    Spacer(minLength: DS.e3)
                    Text(valor(k))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PV.mudo)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 2)
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
        VStack(spacing: DS.e2) {
            ForEach(agentes, id: \.nome) { a in
                HStack(spacing: DS.e3) {
                    Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(PV.mudo)
                    Text(ClarezaCota.titulo(nome: a.nome, rotulo: a.rotulo))
                        .font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                    Spacer(minLength: DS.e3)
                    Button(String(localized: "Abrir manifesto")) {
                        if let u = url(a.nome) { NSWorkspace.shared.open(u) }
                    }
                    .font(PV.fonte(11.5))
                    .disabled(url(a.nome) == nil)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 2)
    }
}
