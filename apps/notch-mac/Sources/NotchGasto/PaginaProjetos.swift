import SwiftUI
import GastoCore

/// Página Projetos do painel.
///
/// Uma linha por projeto reúne o que antes estava espalhado em três listas
/// (portfólio, cadastro e instalação). A linha mostra o resumo do projeto e a
/// instalação abre nela mesma; o cadastro completo abre num popup. O ciclo e o
/// resumo da instalação ficam na coluna da direita.
struct PaginaProjetos: View {
    @ObservedObject var modelo: ModeloNotch
    @StateObject private var estado = EstadoProjetos(modelo: ModeloAjustes())
    @StateObject private var instalar = EstadoInstalacao()
    @State private var popup: PopupProjeto?
    /// Projeto com a instalação aberta (uma por vez, para a lista seguir curta).
    @State private var expandido: String?

    private var projetos: [ProjetoCadastro] { estado.projetos }
    private var linhas: [LinhaCadastro] { estado.linhas.filter { !$0.nova } }
    private var hb: EstadoLanes.Heartbeat? { modelo.resumo?.heartbeat }
    private var atual: String? { hb?.project }
    private var ativos: Int { projetos.filter(\.ativo).count }
    private var principal: ProjetoCadastro? { ProjetosConfig.padrao(projetos) }
    /// Só projeto que instala algo precisa de estado: ler «nenhuma» rodaria `git` a
    /// cada desenho só para descobrir a versão do repositório.
    private var itens: [String: InstalarProjeto.Item] {
        let comInstalacao = projetos.filter { $0.instalacao.classe != .nenhuma }
        return Dictionary(InstalarProjeto.itens(comInstalacao).map { ($0.id, $0) },
                          uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let itens = itens
            VStack(alignment: .leading, spacing: 13) {
                resumo
                HStack(alignment: .top, spacing: 13) {
                    cartaoProjetos(itens: itens)
                    VStack(spacing: 12) {
                        cartaoCiclo
                        cartaoInstalacao(itens: itens)
                    }
                    .frame(width: 380)
                }
            }
            .padding(.top, 10)
        }
        .task {
            // As versões não dependem do Linear/GitHub: começam antes das listas
            // (que podem demorar) para o seletor de instalar já abrir preenchido.
            instalar.carregarVersoesIniciais(projetos)
            await estado.carregarListas()
            await estado.conferirProvaRemota()
            await estado.conferirNorte()
        }
        .sheet(item: $popup) { item in
            if let i = estado.indice(item.id) {
                let nova = estado.linhas[i].nova
                EditorProjetoPopup(
                    linha: $estado.linhas[i],
                    estado: estado,
                    titulo: nova ? String(localized: "Novo projeto") : String(localized: "Editar projeto"),
                    subtitulo: nova
                        ? String(localized: "Escolha o projeto do Linear, o repositório do GitHub e a pasta deste Mac.")
                        : String(localized: "As mudanças valem no próximo ciclo das lanes."),
                    fechar: { fecharPopup(item.id) },
                    cancelar: { fecharPopup(item.id) })
            }
        }
    }

    // MARK: - Topo

    /// O que antes era uma faixa de cinco números grandes vira uma linha: os mesmos
    /// dados já aparecem nas linhas e no cartão do ciclo.
    private var resumo: some View {
        faixaPagina {
            Text(Formato.plural(projetos.count, "cadastrado", "cadastrados"))
                .fontePainel(12.5, .semibold).foregroundStyle(PV.texto2)
            PontoFaixa()
            Text(Formato.plural(ativos, "ligado", "ligados"))
                .fontePainel(12.5, .semibold)
                .foregroundStyle(ativos > 0 ? Aurora.verde : PV.mudo)
            if let principal {
                PontoFaixa()
                Text("principal \(principal.nome)").fontePainel(12.5).foregroundStyle(PV.texto2)
                    .lineLimit(1).truncationMode(.middle)
            }
            if hb?.agenda != true {
                PontoFaixa()
                Text("agenda desligada").fontePainel(12).foregroundStyle(PV.mudo)
                    .help(String(localized: "A agenda multi-projeto está desligada: o dispatcher fica no projeto principal."))
            }
        } direita: {
            BotaoAdicionar { adicionar() }
        }
    }

    // MARK: - Lista

    private func cartaoProjetos(itens: [String: InstalarProjeto.Item]) -> some View {
        cartaoPagina("Todos os projetos") {
            VStack(alignment: .leading, spacing: 0) {
                if let erro = estado.erro {
                    Label(erro, systemImage: "exclamationmark.triangle.fill")
                        .fontePainel(11.5).foregroundStyle(Aurora.vermelho)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                }
                if let aviso = estado.aviso {
                    Label(aviso, systemImage: "checkmark.circle")
                        .fontePainel(11.5).foregroundStyle(PV.mudo)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                }
                if linhas.isEmpty {
                    vazio
                } else {
                    ForEach(linhas) { linha in
                        if linha.id != linhas.first?.id { Divider().overlay(PV.divisor) }
                        linhaDeProjeto(linha, item: itens[(linha.salvo ?? linha.rascunho).projetoID])
                    }
                }
                Text(String(localized: "As lanes pegam cards só de projetos ligados. Com mais de um ligado, vale o principal; os outros esperam a vez."))
                    .fontePainel(11.5).foregroundStyle(PV.mudo)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private var vazio: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "Nenhum projeto ainda.")).fontePainel(13, .semibold).foregroundStyle(PV.texto)
            Text(String(localized: "Adicione o primeiro: escolha o projeto do Linear e o repositório do GitHub em que as lanes vão trabalhar."))
                .fontePainel(12).foregroundStyle(PV.mudo)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func linhaDeProjeto(_ linha: LinhaCadastro, item: InstalarProjeto.Item?) -> some View {
        let p = linha.salvo ?? linha.rascunho
        LinhaProjetoScreen(
            estado: estado,
            instalar: instalar,
            modelo: modelo,
            projeto: p,
            linhaID: linha.id,
            item: item,
            noCiclo: atual == p.projetoID,
            aberto: expandido == p.projetoID,
            alternarInstalacao: {
                comAnimacao(DS.suave) { expandido = expandido == p.projetoID ? nil : p.projetoID }
            },
            editar: {
                estado.abrirEditor(linha.id)
                popup = PopupProjeto(id: linha.id)
            })
    }

    // MARK: - Coluna da direita

    private var cartaoCiclo: some View {
        let rodando = modelo.snapshot?.lanes.filter { $0.estado == .rodando }.count ?? 0
        let fila = modelo.snapshot?.filaPronta.count ?? 0
        let nome = hb?.projectName ?? projetos.first { $0.projetoID == atual }?.nome
        return cartaoPagina("Ciclo atual") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(hb?.agenda == true ? Aurora.verde : PV.mudo)
                        .frame(width: 6, height: 6)
                    Text(nome ?? String(localized: "sem leitura neste ciclo"))
                        .fontePainel(13, .semibold).foregroundStyle(PV.texto)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if hb?.agenda == true {
                        SeloPV(texto: String(localized: "agenda"), cor: Aurora.verde)
                    }
                }
                HStack(spacing: 8) {
                    stat("Rodando", "\(rodando)", cor: rodando > 0 ? Aurora.verde : PV.texto)
                    stat("Fila", "\(fila)", cor: fila > 0 ? Aurora.azul : PV.texto)
                    stat("Ligados", "\(ativos)", cor: PV.texto2)
                }
                Text(hb?.agenda == true
                     ? String(localized: "A agenda alterna os projetos ligados; a lane em andamento manda.")
                     : String(localized: "A agenda multi-projeto está desligada: o dispatcher fica no projeto principal."))
                    .fontePainel(11.5).foregroundStyle(PV.mudo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cartaoInstalacao(itens: [String: InstalarProjeto.Item]) -> some View {
        let lista = Array(itens.values)
        let noAr = lista.filter { $0.estado.situacao == "rodando" }.count
        let instalados = lista.filter { $0.estado.situacao == "instalado" }.count
        let travados = lista.filter { !$0.estado.bloqueio.isEmpty }.count
        return cartaoPagina("Instalação") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    stat("Serviços no ar", "\(noAr)", cor: noAr > 0 ? Aurora.verde : PV.texto)
                        .help(String(localized: "Projetos de serviço com o processo de pé."))
                    stat("Artefatos", "\(instalados)", cor: instalados > 0 ? Aurora.verde : PV.texto)
                        .help(String(localized: "Projetos de artefato instalados no destino."))
                    stat("Travados", "\(travados)", cor: travados > 0 ? Aurora.ambar : PV.texto)
                        .help(String(localized: "Projetos com a instalação travada por uma lane em andamento."))
                }
                if lista.isEmpty {
                    Text(String(localized: "Nenhum projeto instala serviço ou artefato: a entrega é o commit/tag."))
                        .fontePainel(11.5).foregroundStyle(PV.mudo)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(localized: "A configuração fica no cadastro do projeto (⋯ › Editar)."))
                        .fontePainel(11).foregroundStyle(PV.apagado)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Ações

    private func adicionar() {
        estado.adicionar()
        if let nova = estado.linhas.last(where: \.nova) { popup = PopupProjeto(id: nova.id) }
    }

    /// Fecha o popup descartando o que não foi salvo (salvar já atualizou a linha).
    private func fecharPopup(_ id: UUID) {
        estado.cancelar(id)
        popup = nil
        instalar.carregarVersoesIniciais(estado.projetos, soFaltando: true)
    }

}

// MARK: - Linha de um projeto

/// Uma linha do projeto: resumo do portfólio, o liga/desliga e as ações. A
/// instalação (situação, versão e botões) abre logo abaixo, sem sair da linha.
private struct LinhaProjetoScreen: View {
    @ObservedObject var estado: EstadoProjetos
    @ObservedObject var instalar: EstadoInstalacao
    let modelo: ModeloNotch
    let projeto: ProjetoCadastro
    let linhaID: UUID
    let item: InstalarProjeto.Item?
    let noCiclo: Bool
    let aberto: Bool
    var alternarInstalacao: () -> Void
    var editar: () -> Void

    @State private var confirmarRemocao = false

    private var principal: Bool {
        ProjetosConfig.mostrarPrincipal(estado.projetos)
            && ProjetosConfig.padrao(estado.projetos)?.projetoID == projeto.projetoID
    }
    private var posicao: Int { estado.indice(linhaID) ?? 0 }
    private var rodando: Int { modelo.snapshot?.lanes.filter { $0.estado == .rodando }.count ?? 0 }
    private var fila: Int { modelo.snapshot?.filaPronta.count ?? 0 }

    private var local: String {
        let repo = projeto.repo.isEmpty ? String(localized: "sem pasta") : projeto.repo
        return projeto.github.isEmpty ? repo : "\(projeto.github) · \(repo)"
    }

    private var planejamento: String {
        [projeto.planejamento.objetivo,
         projeto.planejamento.alvo.isEmpty ? "" : "alvo " + projeto.planejamento.alvo]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(projeto.ativo ? Aurora.verde : PV.mudo)
                    .frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(projeto.nome).fontePainel(13, .semibold).foregroundStyle(PV.texto)
                            .lineLimit(1)
                        if noCiclo { SeloPV(texto: String(localized: "no ciclo"), cor: Aurora.verde) }
                        if principal { SeloPV(texto: String(localized: "principal"), cor: Aurora.azul) }
                        if !projeto.ativo { SeloPV(texto: String(localized: "desligado"), cor: PV.mudo) }
                    }
                    Text(local).fontePainel(11).foregroundStyle(PV.mudo)
                        .lineLimit(1).truncationMode(.middle)
                    if !planejamento.isEmpty {
                        Text(planejamento).fontePainel(11).foregroundStyle(PV.mudo)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    HStack(spacing: 7) { metricas }
                        .fontePainel(11).foregroundStyle(PV.mudo)
                    if projeto.instalacao.classe != .nenhuma { botaoInstalacao }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Toggle(String(localized: "Ligado"),
                           isOn: Binding(get: { projeto.ativo },
                                         set: { estado.alternarAtivo(linhaID, $0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .help(String(localized: "Ligado: as lanes podem pegar cards deste projeto."))
                    menu
                }
                .padding(.top, 1)
            }
            if aberto, let item {
                BlocoInstalacao(item: item, instalar: instalar, abrir: modelo.abrirEndereco)
                    .padding(.leading, 17)
            }
        }
        .padding(.vertical, 10)
        .confirmationDialog(String(localized: "Remover \(projeto.nome) do cadastro?"), isPresented: $confirmarRemocao) {
            Button(String(localized: "Remover"), role: .destructive) {
                estado.remover(linhaID)
                modelo.config = Configuracao.resolver()
            }
        } message: {
            Text(String(localized: "As lanes deixam de pegar cards deste projeto. Nada muda no Linear, no GitHub nem na pasta."))
        }
    }

    @ViewBuilder
    private var metricas: some View {
        Text("prioridade \(projeto.prioridade)")
            .lineLimit(1)
            .help(String(localized: "Maior primeiro. Sem agenda multi-projeto, é só informativo."))
        PontoFaixa()
        Text(custoTexto())
            .lineLimit(1)
            .help(String(localized: "Custo conhecido dos últimos 7 dias neste projeto."))
        PontoFaixa()
        Text(fluxoTexto())
            .lineLimit(1)
            .help(String(localized: "Claims, merges e duração média claim→finalize, do eventos.jsonl."))
        if noCiclo {
            PontoFaixa()
            Text("\(rodando) rodando · \(fila) na fila").lineLimit(1)
        }
        if projeto.ativo {
            PontoFaixa()
            Text(noCiclo ? String(localized: "trabalhando") : String(localized: "aguardando"))
                .lineLimit(1)
                .foregroundStyle(noCiclo ? Aurora.verde : PV.mudo)
        }
    }

    @ViewBuilder
    private var botaoInstalacao: some View {
        Button { alternarInstalacao() } label: {
            HStack(spacing: 6) {
                Text(String(localized: "Instalação")).foregroundStyle(PV.mudo)
                Text(projeto.instalacao.classe.rotulo).foregroundStyle(PV.texto2)
                if let item {
                    Circle().fill(corSituacao(item.estado.situacao)).frame(width: 5, height: 5)
                    Text(item.estado.situacao)
                        .foregroundStyle(corSituacao(item.estado.situacao))
                    if !item.estado.versao.isEmpty {
                        Text(item.estado.versao).foregroundStyle(PV.mudo)
                    }
                }
                Image(systemName: aberto ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(PV.apagado)
            }
            .fontePainel(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Abrir as ações de instalação deste projeto"))
    }

    private var menu: some View {
        Menu {
            Button(String(localized: "Editar")) { editar() }
            if projeto.ativo, ProjetosConfig.mostrarPrincipal(estado.projetos), !principal {
                Button(String(localized: "Tornar principal")) { tornarPrincipal() }
            }
            if estado.projetos.count > 1 {
                Button(String(localized: "Mover para cima")) { estado.mover(linhaID, -1) }
                    .disabled(posicao == 0)
                Button(String(localized: "Mover para baixo")) { estado.mover(linhaID, 1) }
                    .disabled(posicao >= estado.projetos.count - 1)
            }
            Divider()
            Button(String(localized: "Remover…"), role: .destructive) { confirmarRemocao = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(PV.mudo)
        .help(String(localized: "Mais ações"))
    }

    private func tornarPrincipal() {
        estado.tornarPrincipal(linhaID)
        modelo.config = Configuracao.resolver()
    }

    private func custoTexto() -> String {
        guard let custo = modelo.snapshot?.custos.porProjeto.first(where: { $0.projeto == projeto.projetoID }) else {
            return "sem medida"
        }
        guard let usd = custo.custoUSD, let moeda = modelo.snapshot?.custos.moeda else {
            return custo.execucoes > 0 ? "custo desconhecido" : "sem medida"
        }
        return "7 dias: " + moeda.texto(usd)
    }

    private func fluxoTexto() -> String {
        guard let f = modelo.snapshot?.fluxo.first(where: { $0.projeto == projeto.projetoID }),
              f.claims + f.finalizes + f.merges > 0 else {
            return "sem fluxo"
        }
        var partes = ["\(f.claims) claims", "\(f.merges) merges"]
        if let media = f.duracaoMediaMin {
            let numero = String(format: "%.1f", media).replacingOccurrences(of: ".", with: ",")
            partes.append("média \(numero) min")
        } else if f.finalizes > 0 {
            partes.append("média sem medida")
        }
        return partes.joined(separator: " · ")
    }

}

// MARK: - Instalação

/// Estado das ações de instalação da página. Sobrevive ao redesenho do
/// `TimelineView` e é compartilhado por todas as linhas.
@MainActor
final class EstadoInstalacao: ObservableObject {
    /// Último retorno de cada projeto (o texto do CLI), por id do Linear.
    @Published var aviso: [String: String] = [:]
    /// `id + ação` em andamento: só ele mostra o indicador e trava os botões.
    @Published var agindo: String?
    @Published var logAberto: Set<String> = []
    /// Versões oferecidas por projeto (branches + tags; `main` sempre).
    @Published var versoes: [String: InstalarProjeto.Versoes] = [:]
    @Published var escolhida: [String: String] = [:]
    @Published var carregando: Set<String> = []

    /// Versão escolhida: a última do seletor, a instalada, ou `main`.
    func versao(_ item: InstalarProjeto.Item) -> String {
        if let v = escolhida[item.id], !v.isEmpty { return v }
        return item.estado.ref.isEmpty ? "main" : item.estado.ref
    }

    func escolher(_ versao: String, _ id: String) { escolhida[id] = versao }

    /// Carrega a lista de versões dos artefatos. `soFaltando` só busca o que ainda
    /// não chegou (usado quando o cadastro muda e a página volta a desenhar).
    func carregarVersoesIniciais(_ projetos: [ProjetoCadastro], soFaltando: Bool = false) {
        for p in projetos where p.instalacao.classe == .artefato {
            if soFaltando, versoes[p.projetoID] != nil { continue }
            carregarVersoes(p)
        }
    }

    func carregarVersoes(_ p: ProjetoCadastro, forcar: Bool = false) {
        guard p.instalacao.classe == .artefato, !carregando.contains(p.projetoID) else { return }
        if !forcar, versoes[p.projetoID] != nil { return }
        carregando.insert(p.projetoID)
        Task.detached(priority: .utility) {
            let v = InstalarProjeto.versoes(p)
            await MainActor.run {
                self.versoes[p.projetoID] = v
                self.carregando.remove(p.projetoID)
            }
        }
    }

    /// Roda uma ação do CLI no projeto. O estado vem do arquivo que o Python grava.
    func agir(_ acao: String, _ item: InstalarProjeto.Item) {
        guard agindo == nil else { return }
        let ref = acao == "instalar" ? versao(item) : ""
        guard let cmd = InstalarProjeto.comando(acao, projetoID: item.id, ref: ref) else {
            aviso[item.id] = String(localized: "O CLI da instalação não está no app. Reinstale o TuttiDash.")
            return
        }
        agindo = item.id + acao
        aviso[item.id] = acao == "instalar" && !ref.isEmpty
            ? String(localized: "\(Self.rotulo(acao)) de \(ref) em andamento…")
            : String(localized: "\(Self.rotulo(acao)) em andamento…")
        Task {
            let r = await Task.detached {
                Subprocesso.rodar(cmd[0], Array(cmd.dropFirst()), ambiente: InstalarProjeto.ambiente)
            }.value
            agindo = nil
            aviso[item.id] = Self.mensagem(r)
            if acao == "instalar" { carregarVersoes(item.projeto, forcar: true) }
        }
    }

    static func mensagem(_ r: Subprocesso.Resultado) -> String {
        let texto = r.texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = texto.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let t = o["texto"] as? String, !t.isEmpty { return t }
            if (o["ok"] as? Bool) == true { return "pronto" }
        }
        if !texto.isEmpty { return texto }
        return r.codigo == 0 ? "pronto" : "falhou (código \(r.codigo))"
    }

    static func rotulo(_ acao: String) -> String {
        switch acao {
        case "subir": return String(localized: "Subir")
        case "parar": return String(localized: "Parar")
        case "empacotar": return String(localized: "Empacotar")
        case "validar": return String(localized: "Validar")
        case "instalar": return String(localized: "Instalar")
        default: return acao
        }
    }
}

/// A instalação de um projeto, aberta dentro da linha: classe, situação, versão
/// e as ações. Só aparece para projeto que instala serviço ou artefato.
private struct BlocoInstalacao: View {
    let item: InstalarProjeto.Item
    @ObservedObject var instalar: EstadoInstalacao
    let abrir: (URL) -> Void

    private var p: ProjetoCadastro { item.projeto }
    private var e: InstalarProjeto.Estado { item.estado }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(corSituacao(e.situacao)).frame(width: 6, height: 6)
                Text(e.situacao).fontePainel(11.5, .medium)
                    .foregroundStyle(corSituacao(e.situacao)).lineLimit(1)
                Text(e.versao.isEmpty ? "—" : "v\(e.versao)")
                    .fontePainel(11).foregroundStyle(e.versao.isEmpty ? PV.apagado : PV.texto2)
                    .lineLimit(1)
                if !e.ref.isEmpty {
                    Text(e.ref + (e.head.isEmpty ? "" : " · \(e.head.prefix(7))"))
                        .fontePainel(10).foregroundStyle(PV.mudo).lineLimit(1)
                }
                Spacer(minLength: 8)
                if p.instalacao.classe == .artefato { seletorDeVersao }
                ForEach(e.acoes, id: \.self) { acao in
                    BotaoInstalar(texto: Self.rotulo(acao),
                                  emAndamento: instalar.agindo == item.id + acao,
                                  ativo: pode(acao)) { instalar.agir(acao, item) }
                        .help(motivo(acao) ?? Self.rotulo(acao))
                }
                if let url = URL(string: e.url), !e.url.isEmpty {
                    BotaoInstalar(texto: String(localized: "Abrir"), emAndamento: false, ativo: true) {
                        abrir(url)
                    }
                }
                if !e.log.isEmpty {
                    BotaoInstalar(texto: instalar.logAberto.contains(item.id)
                                  ? String(localized: "Fechar log") : String(localized: "Log"),
                                  emAndamento: false, ativo: true) {
                        if instalar.logAberto.contains(item.id) { instalar.logAberto.remove(item.id) }
                        else { instalar.logAberto.insert(item.id) }
                    }
                }
            }
            if let versoes = instalar.versoes[item.id], !versoes.erro.isEmpty {
                Label(versoes.erro, systemImage: "arrow.clockwise")
                    .fontePainel(10.5).foregroundStyle(Aurora.ambar)
                    .lineLimit(2).textSelection(.enabled)
            }
            if !e.bloqueio.isEmpty {
                Label(e.bloqueio, systemImage: "lock.fill")
                    .fontePainel(11).foregroundStyle(Aurora.ambar)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !e.erro.isEmpty {
                Label(e.erro, systemImage: "exclamationmark.triangle.fill")
                    .fontePainel(11).foregroundStyle(Aurora.vermelho)
                    .lineLimit(3).textSelection(.enabled)
            }
            if let aviso = instalar.aviso[item.id], !aviso.isEmpty {
                Text(aviso).fontePainel(11).foregroundStyle(PV.texto2)
                    .lineLimit(4).textSelection(.enabled)
            }
            if instalar.logAberto.contains(item.id) {
                let linhas = InstalarProjeto.ultimasLinhas(e.log)
                Text(linhas.isEmpty ? String(localized: "log vazio") : linhas)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PV.mudo)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(PV.interno, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(PV.interno, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Seletor de versão: `main` sempre, mais as branches e tags do projeto.
    private var seletorDeVersao: some View {
        HStack(spacing: 4) {
            if instalar.carregando.contains(item.id), instalar.versoes[item.id] == nil {
                ProgressView().controlSize(.mini)
            }
            Menu {
                if let versoes = instalar.versoes[item.id] {
                    Section(String(localized: "Branches")) {
                        ForEach(versoes.branches, id: \.self) { b in
                            Button(b) { instalar.escolher(b, item.id) }
                        }
                    }
                    if !versoes.tags.isEmpty {
                        Section(String(localized: "Tags")) {
                            ForEach(versoes.tags, id: \.self) { t in
                                Button(t) { instalar.escolher(t, item.id) }
                            }
                        }
                    }
                } else {
                    Button("main") { instalar.escolher("main", item.id) }
                }
                Divider()
                Button(String(localized: "Atualizar lista")) {
                    instalar.carregarVersoes(p, forcar: true)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(instalar.versao(item)).fontePainel(11).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(PV.texto2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(PV.interno, in: Capsule())
                .overlay(Capsule().stroke(PV.divisor, lineWidth: 1))
                .frame(maxWidth: 120)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Versão que o botão Instalar vai buildar (main sempre disponível)"))
        }
    }

    private func motivo(_ acao: String) -> String? {
        if !e.bloqueio.isEmpty { return e.bloqueio }
        if instalar.agindo != nil { return String(localized: "Outra ação está em andamento neste projeto.") }
        switch acao {
        case "subir" where e.situacao == "rodando": return String(localized: "Já está rodando.")
        case "parar" where e.situacao == "parado": return String(localized: "Já está parado.")
        default: return nil
        }
    }

    private func pode(_ acao: String) -> Bool { motivo(acao) == nil }

    private static func rotulo(_ acao: String) -> String { EstadoInstalacao.rotulo(acao) }
}

/// Botão das ações de instalação.
private struct BotaoInstalar: View {
    let texto: String
    let emAndamento: Bool
    let ativo: Bool
    var acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 4) {
                if emAndamento { ProgressView().controlSize(.mini) }
                Text(texto).fontePainel(11.5, .medium)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ativo ? PV.texto : PV.apagado)
        .background(ativo ? PV.botao : PV.interno, in: Capsule())
        .overlay(Capsule().stroke(ativo ? PV.botaoBorda : PV.divisor, lineWidth: 1))
        .disabled(!ativo || emAndamento)
    }
}

/// Cor do ponto de situação da instalação.
private func corSituacao(_ situacao: String) -> Color {
    switch situacao {
    case "rodando", "instalado", "empacotado", "validado": return Aurora.verde
    case "parado", "nenhuma", "não instalado": return PV.mudo
    case "cadastro inválido", "falhou", "sem resposta": return Aurora.vermelho
    default: return Aurora.ambar
    }
}

/// «Adicionar projeto» no topo: pílula de vidro com o acento da Aurora.
private struct BotaoAdicionar: View {
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(String(localized: "Adicionar projeto"))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(hover ? Aurora.tinta : Aurora.acento)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(hover ? Aurora.acento : Aurora.acento.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Aurora.acento.opacity(hover ? 0 : 0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(Pressionavel())
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

/// Selo pequeno da página de portfólio, no mesmo tom dos cartões do painel.
struct SeloPV: View {
    var texto: String
    var cor: Color
    var body: some View {
        Text(texto)
            .fontePainel(10, .semibold)
            .foregroundStyle(cor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(cor.opacity(0.12)))
            .overlay(Capsule().strokeBorder(cor.opacity(0.25), lineWidth: 0.5))
    }
}
