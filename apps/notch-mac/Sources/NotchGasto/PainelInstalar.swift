import SwiftUI
import GastoCore

/// FRA-699: a tela de instalação por projeto.
///
/// Ela **não executa nada por conta própria**: lê `~/.transcentia/instalacoes/<id>.json`
/// e, no clique, chama `tools/instalar.py`. Nenhum nome de projeto, linguagem ou
/// ferramenta aparece aqui: a classe e os comandos vêm do cadastro (Ajustes › Projetos).
/// Cada projeto de artefato oferece a versão a instalar: `main` sempre, mais as
/// branches e tags que o CLI lista — a instalação builda essa versão num worktree isolado.
struct PaginaInstalar: View {
    @ObservedObject var modelo: ModeloNotch

    /// Último retorno de cada projeto (o texto do CLI), por id do Linear.
    @State private var aviso: [String: String] = [:]
    /// `id + ação` em andamento: só ele mostra o indicador e trava os botões.
    @State private var agindo: String?
    /// Projetos com o log aberto.
    @State private var logAberto: Set<String> = []
    /// Versões oferecidas por projeto (branches + tags; `main` sempre).
    @State private var versoes: [String: InstalarProjeto.Versoes] = [:]
    /// Versão escolhida no seletor de cada projeto.
    @State private var escolhida: [String: String] = [:]
    /// Projetos com a lista de versões sendo carregada.
    @State private var carregando: Set<String> = []
    @State private var carregou = false

    private var ajustes: ModeloAjustes { ModeloAjustes() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let a = ajustes
            let projetos = ProjetosConfig.ler(a.dados)
            let itens = InstalarProjeto.itens(projetos, home: a.home)
            VStack(spacing: 13) {
                resumo(itens)
                cartaoPagina("Instalar por projeto", direita: {
                    Text("A configuração fica em Ajustes › Projetos")
                        .fontePainel(11.5).foregroundStyle(PV.mudo)
                }) {
                    if itens.isEmpty {
                        Text("Nenhum projeto no cadastro. Adicione o primeiro em Ajustes › Projetos.")
                            .fontePainel(12.5).foregroundStyle(PV.mudo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                RotuloColuna(texto: "Projeto").frame(maxWidth: .infinity, alignment: .leading)
                                RotuloColuna(texto: "Classe").frame(width: 130, alignment: .leading)
                                RotuloColuna(texto: "Situação").frame(width: 130, alignment: .leading)
                                RotuloColuna(texto: "Versão").frame(width: 110, alignment: .leading)
                                RotuloColuna(texto: "Ações").frame(width: 380, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            ForEach(itens) { item in
                                LinhaInstalar(item: item,
                                              agindo: agindo,
                                              aviso: aviso[item.id],
                                              logAberto: logAberto.contains(item.id),
                                              versoes: versoes[item.id],
                                              escolhida: escolhida(item),
                                              carregando: carregando.contains(item.id),
                                              escolher: { escolhida[item.id] = $0 },
                                              recarregar: { carregarVersoes(item.id, do: item.projeto) },
                                              agir: { agir($0, item) },
                                              alternarLog: {
                                                  if logAberto.contains(item.id) { logAberto.remove(item.id) }
                                                  else { logAberto.insert(item.id) }
                                              },
                                              abrir: modelo.abrirEndereco)
                                Divider().overlay(PV.divisor)
                            }
                        }
                    }
                }
            }
            .padding(.top, 10)
            .onAppear {
                guard !carregou else { return }
                carregou = true
                for item in itens {
                    carregarVersoes(item.id, do: item.projeto)
                }
            }
        }
    }

    /// Versão escolhida: a última do seletor, a instalada, ou `main`.
    private func escolhida(_ item: InstalarProjeto.Item) -> String {
        if let v = escolhida[item.id], !v.isEmpty { return v }
        return item.estado.ref.isEmpty ? "main" : item.estado.ref
    }

    private func carregarVersoes(_ id: String, do projeto: ProjetoCadastro) {
        guard projeto.instalacao.classe == .artefato, !carregando.contains(id) else { return }
        carregando.insert(id)
        Task.detached(priority: .utility) {
            let v = InstalarProjeto.versoes(projeto)
            await MainActor.run {
                versoes[id] = v
                carregando.remove(id)
            }
        }
    }

    private func resumo(_ itens: [InstalarProjeto.Item]) -> some View {
        let rodando = itens.filter { $0.estado.situacao == "rodando" }.count
        let instalados = itens.filter { $0.estado.situacao == "instalado" }.count
        let travados = itens.filter { !$0.estado.bloqueio.isEmpty }.count
        return HStack(alignment: .top, spacing: 13) {
            cartaoPagina("Resumo") {
                HStack(spacing: 8) {
                    stat("Projetos", "\(itens.count)", cor: PV.texto)
                    stat("Serviços no ar", "\(rodando)", cor: rodando > 0 ? PV.verde : PV.texto)
                    stat("Artefatos instalados", "\(instalados)", cor: instalados > 0 ? PV.verde : PV.texto)
                    stat("Com lane rodando", "\(travados)", cor: travados > 0 ? PV.ambar : PV.texto)
                }
            }
        }
    }

    /// Roda uma ação do CLI no projeto. O estado vem do arquivo que o Python grava.
    private func agir(_ acao: String, _ item: InstalarProjeto.Item) {
        guard agindo == nil else { return }
        let ref = acao == "instalar" ? escolhida(item) : ""
        guard let cmd = InstalarProjeto.comando(acao, projetoID: item.id, ref: ref) else {
            aviso[item.id] = String(localized: "O CLI da instalação não está no app. Reinstale o TuttiDash.")
            return
        }
        let chave = item.id + acao
        agindo = chave
        aviso[item.id] = acao == "instalar" && !ref.isEmpty
            ? String(localized: "\(rotulo(acao)) de \(ref) em andamento…")
            : String(localized: "\(rotulo(acao)) em andamento…")
        Task {
            let r = await Task.detached {
                Subprocesso.rodar(cmd[0], Array(cmd.dropFirst()), ambiente: InstalarProjeto.ambiente)
            }.value
            agindo = nil
            aviso[item.id] = Self.mensagem(r)
            if acao == "instalar", !ref.isEmpty {
                carregarVersoes(item.id, do: item.projeto)
            }
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

    private func rotulo(_ acao: String) -> String {
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

/// Uma linha da tabela: projeto, classe, situação, versão e as ações da classe.
private struct LinhaInstalar: View {
    let item: InstalarProjeto.Item
    let agindo: String?
    let aviso: String?
    let logAberto: Bool
    let versoes: InstalarProjeto.Versoes?
    let escolhida: String
    let carregando: Bool
    let escolher: (String) -> Void
    let recarregar: () -> Void
    let agir: (String) -> Void
    let alternarLog: () -> Void
    let abrir: (URL) -> Void

    private var p: ProjetoCadastro { item.projeto }
    private var e: InstalarProjeto.Estado { item.estado }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.nome).fontePainel(13, .semibold).foregroundStyle(PV.texto)
                    Text(p.repo.isEmpty ? String(localized: "sem pasta") : p.repo)
                        .fontePainel(10.5).foregroundStyle(PV.mudo)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(p.instalacao.classe.rotulo)
                    .fontePainel(11.5).foregroundStyle(PV.texto2)
                    .frame(width: 130, alignment: .leading)
                HStack(spacing: 6) {
                    Circle().fill(cor).frame(width: 7, height: 7)
                    Text(e.situacao).fontePainel(12).foregroundStyle(cor)
                        .lineLimit(1)
                }
                .frame(width: 130, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.versao.isEmpty ? "—" : e.versao)
                        .fontePainel(12).foregroundStyle(e.versao.isEmpty ? PV.mudo : PV.texto2)
                        .lineLimit(1)
                    if !e.ref.isEmpty {
                        Text(e.ref + (e.head.isEmpty ? "" : " · \(e.head.prefix(7))"))
                            .fontePainel(10).foregroundStyle(PV.mudo)
                            .lineLimit(1)
                    }
                }
                .frame(width: 110, alignment: .leading)
                HStack(spacing: 6) {
                    if p.instalacao.classe == .artefato {
                        seletorDeVersao
                    }
                    ForEach(e.acoes, id: \.self) { acao in
                        BotaoInstalar(texto: rotulo(acao),
                                      emAndamento: agindo == item.id + acao,
                                      ativo: pode(acao)) { agir(acao) }
                            .help(motivo(acao) ?? rotulo(acao))
                    }
                    if let url = URL(string: e.url), !e.url.isEmpty {
                        BotaoInstalar(texto: String(localized: "Abrir"), emAndamento: false, ativo: true) {
                            abrir(url)
                        }
                    }
                    if !e.log.isEmpty {
                        BotaoInstalar(texto: logAberto ? String(localized: "Fechar log") : String(localized: "Log"),
                                      emAndamento: false, ativo: true, acao: alternarLog)
                    }
                }
                .frame(width: 380, alignment: .trailing)
            }
            if let versoes, !versoes.erro.isEmpty {
                Label(versoes.erro, systemImage: "arrow.clockwise")
                    .fontePainel(10.5).foregroundStyle(PV.ambar)
                    .lineLimit(2).textSelection(.enabled)
            }
            if !e.bloqueio.isEmpty {
                Label(e.bloqueio, systemImage: "lock.fill")
                    .fontePainel(11).foregroundStyle(PV.ambar)
            }
            if !e.erro.isEmpty {
                Label(e.erro, systemImage: "exclamationmark.triangle.fill")
                    .fontePainel(11).foregroundStyle(PV.vermelho)
                    .lineLimit(3).textSelection(.enabled)
            }
            if let aviso, !aviso.isEmpty {
                Text(aviso).fontePainel(11).foregroundStyle(PV.texto2)
                    .lineLimit(4).textSelection(.enabled)
            }
            if logAberto {
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
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    /// Seletor de versão: `main` sempre, mais as branches e tags do projeto.
    private var seletorDeVersao: some View {
        HStack(spacing: 4) {
            if carregando && versoes == nil {
                ProgressView().controlSize(.mini)
            }
            Menu {
                if let versoes {
                    Section(String(localized: "Branches")) {
                        ForEach(versoes.branches, id: \.self) { b in
                            Button(b) { escolher(b) }
                        }
                    }
                    if !versoes.tags.isEmpty {
                        Section(String(localized: "Tags")) {
                            ForEach(versoes.tags, id: \.self) { t in
                                Button(t) { escolher(t) }
                            }
                        }
                    }
                } else {
                    Button("main") { escolher("main") }
                }
                Divider()
                Button(String(localized: "Atualizar lista")) { recarregar() }
            } label: {
                HStack(spacing: 3) {
                    Text(escolhida).fontePainel(11).lineLimit(1)
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

    private var cor: Color {
        switch e.situacao {
        case "rodando", "instalado", "empacotado", "validado": return PV.verde
        case "parado", "nenhuma", "não instalado": return PV.mudo
        case "cadastro inválido", "falhou", "sem resposta": return PV.vermelho
        default: return PV.ambar
        }
    }

    private func rotulo(_ acao: String) -> String {
        switch acao {
        case "subir": return String(localized: "Subir")
        case "parar": return String(localized: "Parar")
        case "empacotar": return String(localized: "Empacotar")
        case "validar": return String(localized: "Validar")
        case "instalar": return String(localized: "Instalar")
        default: return acao
        }
    }

    /// Botão desabilitado com o motivo visível (trava, estado ou ação em curso).
    private func motivo(_ acao: String) -> String? {
        if !e.bloqueio.isEmpty { return e.bloqueio }
        if agindo != nil { return String(localized: "Outra ação está em andamento neste projeto.") }
        switch acao {
        case "subir" where e.situacao == "rodando": return String(localized: "Já está rodando.")
        case "parar" where e.situacao == "parado": return String(localized: "Já está parado.")
        default: return nil
        }
    }

    private func pode(_ acao: String) -> Bool {
        motivo(acao) == nil
    }
}

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
