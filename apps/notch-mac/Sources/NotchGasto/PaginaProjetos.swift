import SwiftUI
import GastoCore

/// Portfólio: todos os projetos do cadastro, o que está ligado e quem está no ciclo.
/// Não inventa dado de projeto sem leitura: o que não veio no heartbeat aparece como
/// «sem leitura neste ciclo».
struct PaginaProjetos: View {
    @ObservedObject var modelo: ModeloNotch
    /// A página Projetos é dona do cadastro; o botão do cabeçalho abre a linha nova
    /// no gerenciador que fica logo abaixo.
    var aoAdicionar: () -> Void = {}
    @State private var erro: String?

    private var projetos: [ProjetoCadastro] { modelo.config.projetos }
    private var hb: EstadoLanes.Heartbeat? { modelo.resumo?.heartbeat }
    private var atual: String? { hb?.project }
    private var ativos: Int { projetos.filter(\.ativo).count }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 13) {
                resumoTopo
                HStack(alignment: .top, spacing: 13) {
                cartaoPagina("Portfólio", direita: {
                    HStack(spacing: 10) {
                        Text("\(projetos.count) cadastrados · \(ativos) ligados")
                            .fontePainel(11.5).foregroundStyle(PV.mudo)
                        Button(action: aoAdicionar) {
                            Label("Adicionar projeto", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }) {
                    if projetos.isEmpty {
                        Text("Nenhum projeto cadastrado. Abra Ajustes › Projetos para ligar o primeiro.")
                            .fontePainel(12.5).foregroundStyle(PV.mudo)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(projetos) { p in linha(p, agora: ctx.date) }
                        }
                    }
                }

                VStack(spacing: 12) {
                    if let erro {
                        Text(erro).fontePainel(11.5).foregroundStyle(Aurora.rosa)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    cartaoPagina("Ciclo atual") {
                        let nome = hb?.projectName ?? projetos.first(where: { $0.projetoID == atual })?.nome
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill((hb?.agenda ?? false) ? Aurora.verde : PV.mudo)
                                    .frame(width: 6, height: 6)
                                Text(nome ?? "sem leitura neste ciclo")
                                    .fontePainel(13, .semibold).foregroundStyle(PV.texto)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                if hb?.agenda == true {
                                    SeloPV(texto: "agenda", cor: Aurora.verde)
                                }
                            }
                            let rodando = modelo.snapshot?.lanes.filter { $0.estado == .rodando }.count ?? 0
                            let fila = modelo.snapshot?.filaPronta.count ?? 0
                            HStack(spacing: 8) {
                                statPV("Rodando", "\(rodando)", cor: Aurora.verde)
                                statPV("Fila", "\(fila)", cor: Aurora.azul)
                                statPV("Projetos", "\(ativos)", cor: PV.mudo)
                            }
                            Text(hb?.agenda == true
                                 ? "A agenda alterna os projetos ligados; a lane em andamento manda."
                                 : "A agenda multi-projeto está desligada: o dispatcher fica no projeto principal.")
                                .fontePainel(11.5).foregroundStyle(PV.mudo)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(width: 420)
                }
                .padding(.top, 0)
            }
            .padding(.top, 10)
        }
    }

    /// Resumo do portfólio no topo: números grandes e o atalho para gerenciar.
    private var resumoTopo: some View {
        let principal = ProjetosConfig.padrao(projetos)?.nome ?? "sem principal"
        let rodando = modelo.snapshot?.lanes.filter { $0.estado == .rodando }.count ?? 0
        let fila = modelo.snapshot?.filaPronta.count ?? 0
        return HStack(spacing: 0) {
            statPV("Projetos", "\(projetos.count)", cor: PV.texto)
            statPV("Ligados", "\(ativos)", cor: ativos > 0 ? Aurora.verde : PV.mudo)
            statPV("Principal", principal, cor: PV.texto)
            statPV("Rodando", "\(rodando)", cor: rodando > 0 ? Aurora.verde : PV.mudo)
            statPV("Fila", "\(fila)", cor: fila > 0 ? Aurora.azul : PV.mudo)
        }
        .linhaPV()
    }

    private func linha(_ p: ProjetoCadastro, agora: Date) -> some View {
        let noCiclo = atual == p.projetoID
        let cor = p.ativo ? Aurora.verde : PV.mudo
        return HStack(spacing: 10) {
            Circle().fill(cor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.nome).fontePainel(12.5, .semibold).foregroundStyle(PV.texto).lineLimit(1)
                    if noCiclo { SeloPV(texto: "no ciclo", cor: Aurora.verde) }
                    if p.padrao { SeloPV(texto: "principal", cor: Aurora.azul) }
                    if !p.ativo { SeloPV(texto: "desligado", cor: PV.mudo) }
                }
                Text(p.github.isEmpty ? p.repo : "\(p.github) · \(p.repo)")
                    .fontePainel(11).foregroundStyle(PV.mudo).lineLimit(1).truncationMode(.middle)
                if !p.planejamento.objetivo.isEmpty || !p.planejamento.alvo.isEmpty {
                    Text([p.planejamento.objetivo, p.planejamento.alvo.isEmpty ? "" : "alvo " + p.planejamento.alvo]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .fontePainel(10.5).foregroundStyle(PV.mudo).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text("prioridade \(p.prioridade)").fontePainel(11).foregroundStyle(PV.mudo)
                Text(custoTexto(p)).fontePainel(11).foregroundStyle(PV.mudo)
                    .help("Custo conhecido dos últimos 7 dias neste projeto.")
                Text(fluxoTexto(p)).fontePainel(10.5).foregroundStyle(PV.mudo)
                    .help("Claims, merges e duração média claim→finalize, do eventos.jsonl.")
                if noCiclo {
                    let rodando = modelo.snapshot?.lanes.filter { $0.estado == .rodando }.count ?? 0
                    let fila = modelo.snapshot?.filaPronta.count ?? 0
                    Text("\(rodando) rodando · \(fila) na fila")
                        .fontePainel(10.5).foregroundStyle(PV.mudo)
                }
                if p.ativo {
                    Text(noCiclo ? "trabalhando" : "aguardando")
                        .fontePainel(11).foregroundStyle(noCiclo ? Aurora.verde : PV.mudo)
                    if !p.padrao {
                        Button("tornar principal") { definirPrincipal(p) }
                            .buttonStyle(.plain)
                            .fontePainel(11, .semibold)
                            .foregroundStyle(Aurora.azul)
                            .help(hb?.agenda == true
                                  ? "Muda o projeto principal. Com a agenda ligada, o rodízio continua."
                                  : "O dispatcher passa a trabalhar este projeto no próximo ciclo.")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .linhaPV(borda: false)
    }

    private func fluxoTexto(_ p: ProjetoCadastro) -> String {
        guard let f = modelo.snapshot?.fluxo.first(where: { $0.projeto == p.projetoID }),
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

    private func custoTexto(_ p: ProjetoCadastro) -> String {
        guard let custo = modelo.snapshot?.custos.porProjeto.first(where: { $0.projeto == p.projetoID }) else {
            return "sem medida"
        }
        guard let usd = custo.custoUSD, let moeda = modelo.snapshot?.custos.moeda else {
            return custo.execucoes > 0 ? "custo desconhecido" : "sem medida"
        }
        return "7 dias: " + moeda.texto(usd)
    }

    private func definirPrincipal(_ p: ProjetoCadastro) {
        let lista = projetos.map { item -> ProjetoCadastro in
            var x = item
            x.padrao = x.projetoID == p.projetoID
            return x
        }
        do {
            try ModeloAjustes(home: modelo.config.home).definirProjetos(lista)
            modelo.config = Configuracao.resolver()
            erro = nil
        } catch {
            erro = String(localized: "Não foi possível gravar o projeto principal: \(error.localizedDescription)")
        }
    }

    private func statPV(_ nome: String, _ valor: String, cor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(nome).fontePainel(10.5).foregroundStyle(PV.mudo)
            Text(valor).fontePainel(15, .semibold).foregroundStyle(cor).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .linhaPV(borda: false)
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
