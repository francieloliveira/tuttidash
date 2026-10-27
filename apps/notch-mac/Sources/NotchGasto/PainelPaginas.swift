import SwiftUI
import GastoCore

// Páginas da barra lateral: o conteúdo do painel v1 que não cabe no Dashboard da imagem.

private func cartaoPagina<C: View>(_ titulo: String, @ViewBuilder direita: () -> some View = { EmptyView() },
                                   @ViewBuilder conteudo: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
            Text(titulo).font(PV.fonte(15, .semibold))
            Spacer(minLength: 8)
            direita()
        }
        conteudo()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .cartaoVivo()
}

private func par(_ nome: String, _ valor: String, cor: Color = PV.texto) -> some View {
    HStack {
        Text(nome).foregroundStyle(PV.mudo)
        Spacer(minLength: 8)
        Text(valor).foregroundStyle(cor).lineLimit(1).truncationMode(.middle)
    }
    .font(PV.fonte(12.5))
}

private func stat(_ nome: String, _ valor: String, cor: Color = PV.verde) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(nome).font(PV.fonte(11)).foregroundStyle(PV.mudo)
        Text(valor).font(PV.fonte(14, .semibold)).foregroundStyle(cor).lineLimit(1)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .linhaPV(borda: false)
}

// MARK: - Lanes

struct PaginaLanes: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada
    /// Na página Lanes o detalhe já vem aberto; › fecha.
    @State private var fechadas: Set<String> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(alignment: .top, spacing: 13) {
                cartaoPagina("Todas as lanes") {
                    let linhasFiltradas = FiltroBusca(busca.texto).filtrar(modelo.snapshot?.lanes ?? []) { l in
                        [l.lane, l.card, l.descricao] }
                    if !linhasFiltradas.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(linhasFiltradas, id: \.lane) { linha in
                                LinhaLaneDashboard(linha: linha, modelo: modelo, agora: ctx.date,
                                                   aberta: !fechadas.contains(linha.lane), alternar: {
                                    if fechadas.contains(linha.lane) { fechadas.remove(linha.lane) } else { fechadas.insert(linha.lane) }
                                }, mostrarUso: true)
                            }
                        }
                    } else if modelo.snapshot == nil {
                        VStack(spacing: 6) { ForEach(0..<4, id: \.self) { _ in Esqueleto(altura: 51) } }
                    } else {
                        Text("Sem leitura das lanes").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                    }
                }
                VStack(spacing: 12) {
                    cartaoPagina("Parou · retomar", direita: {
                        Text("últimos 7 dias").font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    }) {
                        if modelo.retomadas.isEmpty {
                            Text("Nenhuma lane parou sem fechar o card.").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        } else {
                            ForEach(Array(modelo.retomadas.enumerated()), id: \.offset) { _, r in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(r.card).font(PV.fonte(12.5, .semibold)).foregroundStyle(PV.azul)
                                            Text("· \(r.lane)").font(PV.fonte(12.5))
                                        }
                                        Text("\(r.rotulo) · \(haPainel(r.inicio, agora: ctx.date) ?? "")")
                                            .font(PV.fonte(11.5))
                                            .foregroundStyle(r.rotulo == "lane:falhou" ? Color(hex: 0xFF8DA3) : PV.ambar)
                                        if let m = r.motivo {
                                            Text(m).font(PV.fonte(11)).foregroundStyle(PV.mudo).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    BotaoVer(texto: "retomar", pequeno: true) { modelo.copiar(r.comando) }
                                        .help(r.comando)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .linhaPV(borda: false)
                            }
                            Text("retomar copia o comando para a área de transferência.")
                                .font(PV.fonte(11.5)).foregroundStyle(Color(hex: 0x8FA0BA))
                        }
                    }
                    cartaoPagina("Ferramentas") {
                        HStack(spacing: 8) {
                            BotaoPV(texto: "Abrir janela das lanes") { AbrirComando.janelaLanes() }
                            BotaoPV(texto: "Abrir painel de logs") { AbrirComando.painelLogs() }
                        }
                    }
                }
                .frame(width: 420)
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - Builds

struct PaginaBuilds: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada
    private var snap: SnapshotPainel? { modelo.snapshot }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 12) {
                    cartaoPagina("Lock de build") {
                        par("Dono do lock", ResumoLock.dono(lockLane: snap?.lockLane, lockCard: snap?.lockCard),
                            cor: snap?.lockLane == nil ? PV.verdeClaro : PV.ambar)
                        par("Há quanto tempo", snap?.lockSegundos.map { Formato.relogio($0) } ?? "—")
                        if let s = snap?.lockSegundos {
                            BarraProgresso(progresso: ProgressoProcesso(fracao: min(Double(s) / 600, 1), etapa: String(localized: "na prova"),
                                                                        inicio: ctx.date.addingTimeInterval(-Double(s))),
                                           cor: s >= LanesPainel.alertaProvaSegundos ? PV.ambar : PV.azulIcone)
                        } else {
                            BarraPV(fracao: 0, cor: PV.azulIcone, altura: 6, trilho: PV.trilho)
                        }
                        if let ctx = ResumoLock.contexto(lockLane: snap?.lockLane, rodando: snap?.lanes ?? []) {
                            Text(ctx).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let s = snap?.simulador, s != "sem leitura ainda" {
                            par("Simulador dedicado", s)
                        }
                    }
                    cartaoPagina("Esperando o lock (\(fila.count))", direita: {
                        Text("uma prova por vez").font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    }) {
                        if fila.isEmpty {
                            Text("Nenhuma prova esperando para compilar.").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        }
                        ForEach(Array(fila.enumerated()), id: \.offset) { _, carta in
                            HStack(spacing: 10) {
                                Text("#—").foregroundStyle(PV.mudo).frame(width: 46, alignment: .leading)
                                Text("\(carta.lane) · \(carta.card)").lineLimit(1)
                                Spacer(minLength: 6)
                                Text("aguardando · \(carta.posicaoFila ?? 0)º").font(PV.fonte(10)).foregroundStyle(PV.mudo)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(PV.tag))
                            }
                            .font(PV.fonte(12.5))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .linhaPV(borda: false)
                        }
                    }
                    cartaoPagina("Próximos cards do Linear") {
                        par("Prontos para uma lane", snap?.filaPronta.isEmpty == false ? snap!.filaPronta.joined(separator: ", ") : "nenhum")
                        par("Próxima decisão", snap?.proximaDecisao ?? "sem decisão nova")
                    }
                }
                .frame(width: 420)

                VStack(spacing: 12) {
                    cartaoPagina("Builds de hoje", direita: {
                        Text(resumoBuilds).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    }) {
                        let builds = FiltroBusca(busca.texto).filtrar(snap?.buildsHoje ?? []) { b in
                            [b.card, b.titulo, b.lane] }
                        if builds.isEmpty {
                            Text("Nenhuma build hoje").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        } else {
                            HStack(spacing: 0) {
                                RotuloColuna(texto: "Build").frame(width: 80, alignment: .leading)
                                RotuloColuna(texto: "Card").frame(width: 100, alignment: .leading)
                                RotuloColuna(texto: "Título").frame(maxWidth: .infinity, alignment: .leading)
                                RotuloColuna(texto: "Lane").frame(width: 100, alignment: .leading)
                                RotuloColuna(texto: "Status").frame(width: 100, alignment: .leading)
                                RotuloColuna(texto: "Duração").frame(width: 90, alignment: .leading)
                                RotuloColuna(texto: "Custo").frame(width: 110, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            ForEach(Array(builds.enumerated()), id: \.offset) { _, b in
                                HStack(spacing: 0) {
                                    Text(verbatim: b.numero.map { "#" + String($0) } ?? "—").frame(width: 80, alignment: .leading)
                                    Button { modelo.abrirCard(b.card) } label: {
                                        Text(b.card).foregroundStyle(PV.azul)
                                    }
                                    .buttonStyle(.plain).frame(width: 100, alignment: .leading)
                                    Text(b.titulo ?? b.card).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(b.lane).frame(width: 100, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(b.textoStatus).foregroundStyle(b.naProva ? PV.ambar : cor(b.status))
                                        if let d = b.desfecho {
                                            Text(d).font(PV.fonte(10)).foregroundStyle(PV.mudo).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 100, alignment: .leading)
                                    Text(b.duracaoMs.map { Formato.relogio($0 / 1000) } ?? "—").frame(width: 90, alignment: .leading)
                                    Text(b.textoCusto(snap?.custos.moeda ?? .usd))
                                        .foregroundStyle(b.custo.rotuloFixo == nil && b.custoUSD != nil ? PV.texto : PV.mudo)
                                        .frame(width: 110, alignment: .trailing)
                                }
                                .font(PV.fonte(12.5))
                                .padding(.horizontal, 10).frame(height: 38)
                                .overlay(alignment: .bottom) {
                                    if let p = b.progresso(tipica: BuildPainel.duracaoTipica(builds), agora: ctx.date) {
                                        BarraProgresso(progresso: p, cor: b.naProva ? PV.ambar : PV.verde, altura: 2, mostrarLegenda: false)
                                            .padding(.horizontal, 10)
                                            .help(p.legenda(agora: ctx.date))
                                    }
                                }
                                .linhaPV(borda: false)
                            }
                        }
                    }
                    cartaoPagina("Log do dispatcher", direita: {
                        Text("só leitura").font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                        BotaoVer(texto: modelo.logDetalhado ? "Ocultar log detalhado" : "Ver log detalhado", pequeno: true) {
                            modelo.logDetalhado.toggle()
                        }
                    }) {
                        if modelo.logDetalhado {
                            ScrollView {
                                Text(snap?.logTexto.isEmpty == false ? snap!.logTexto : "O log do dispatcher ainda não existe.")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(PV.texto2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 260)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(PV.lateral))
                        } else {
                            let linhas = snap?.ultimasLinhasLog(10) ?? []
                            Text(linhas.isEmpty ? "O log do dispatcher ainda não existe." : linhas.joined(separator: "\n"))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(PV.texto2)
                                .lineLimit(nil).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(PV.lateral))
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private var fila: [CartaoProva] {
        (snap?.provas ?? []).filter { $0.posicaoFila != nil }.sorted { ($0.posicaoFila ?? 0) < ($1.posicaoFila ?? 0) }
    }

    private func hora(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private var resumoBuilds: String {
        let b = snap?.buildsHoje ?? []
        let ok = b.filter { $0.status == .ok }.count
        let falhou = b.filter { $0.status == .erro || $0.status == .morta }.count
        return "\(b.count) hoje · \(ok) concluídas · \(falhou) com falha"
    }

    private func cor(_ s: StatusExecucao) -> Color {
        switch s {
        case .ok: return PV.verde
        case .erro, .morta: return PV.vermelho
        case .emAndamento: return PV.ambar
        case .cancelada: return PV.mudo
        }
    }
}

// MARK: - Entregas

struct PaginaEntregas: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada
    @State private var pagina = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let entregas = FiltroBusca(busca.texto).filtrar(modelo.snapshot?.entregas ?? []) { e in
                [e.card, e.titulo, e.lane] }
            let resumo = ResumoEntregas.contar(entregas, agora: ctx.date)
            let fatia = ListaPaginada.cortar(entregas, numero: pagina, vazio: "0 entregas")
            VStack(spacing: 13) {
                HStack(alignment: .top, spacing: 13) {
                    cartaoPagina("Resumo") {
                        HStack(spacing: 8) {
                            stat("Fechadas hoje", "\(resumo.hoje)", cor: PV.texto)
                            stat("Fechadas na semana", "\(resumo.semana)", cor: PV.texto)
                            stat("No registro", "\(resumo.registro)", cor: PV.texto)
                        }
                    }
                    cartaoPagina("Instalado nos aparelhos") {
                        stat("iPhone", modelo.snapshot?.iphone ?? "sem leitura ainda",
                             cor: modelo.snapshot?.iphone == "sem leitura ainda" ? PV.mudo : PV.verde)
                        stat("Apple Watch", modelo.snapshot?.relogio ?? "sem leitura ainda",
                             cor: modelo.snapshot?.relogio == "sem leitura ainda" ? PV.mudo : PV.verde)
                    }
                    .frame(width: 380)
                }
                cartaoPagina("Entregas") {
                    if fatia.total == 0 {
                        Text("Nenhum card fechado neste registro").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                    } else {
                        HStack(spacing: 10) {
                            Text("Total: \(Formato.plural(fatia.total, "card", "cards"))")
                                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                            Spacer(minLength: 8)
                            controles(fatia)
                        }
                        TabelaEntregas(itens: fatia.itens, agora: ctx.date,
                                       abrirCard: modelo.abrirCard, abrirEndereco: modelo.abrirEndereco)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func controles(_ fatia: ListaPaginada<EntregaPainel>) -> some View {
        HStack(spacing: 8) {
            Text(fatia.intervalo).font(PV.fonte(12)).foregroundStyle(PV.mudo)
            BotaoPaginaCustos(texto: "Anterior", ativo: fatia.temAnterior) { pagina = fatia.pagina - 1 }
            Text("página \(fatia.pagina) de \(fatia.paginas)")
                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                .fixedSize()
            BotaoPaginaCustos(texto: "Próxima", ativo: fatia.temProxima) { pagina = fatia.pagina + 1 }
        }
    }
}

/// Tabela da tela Entregas. Card abre o Linear; PR com URL abre o GitHub.
private struct TabelaEntregas: View {
    var itens: [EntregaPainel]
    var agora: Date
    var abrirCard: (String) -> Void
    var abrirEndereco: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                RotuloColuna(texto: "Card").frame(width: 100, alignment: .leading)
                RotuloColuna(texto: "Título").frame(maxWidth: .infinity, alignment: .leading)
                RotuloColuna(texto: "Lane").frame(width: 120, alignment: .leading)
                RotuloColuna(texto: "PR").frame(width: 90, alignment: .leading)
                RotuloColuna(texto: "Duração").frame(width: 100, alignment: .leading)
                RotuloColuna(texto: "Quando").frame(width: 130, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            ForEach(itens, id: \.card) { entrega in
                HStack(spacing: 0) {
                    celulaCard(entrega.card)
                    Text(entrega.titulo ?? entrega.card)
                        .foregroundStyle(entrega.titulo == nil ? PV.mudo : PV.texto2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entrega.lane).frame(width: 120, alignment: .leading)
                    celulaPR(entrega)
                    Text(entrega.segundos.map { Formato.relogio($0) } ?? "—")
                        .frame(width: 100, alignment: .leading)
                    Text(haPainel(entrega.quandoData, agora: agora) ?? entrega.quando)
                        .foregroundStyle(PV.mudo)
                        .lineLimit(1)
                        .frame(width: 130, alignment: .trailing)
                }
                .font(PV.fonte(12.5))
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(PV.linha))
            }
        }
    }

    private func celulaCard(_ card: String) -> some View {
        Button { abrirCard(card) } label: {
            Text(card)
                .font(PV.fonte(12.5, .semibold))
                .foregroundStyle(PV.azul)
                .frame(width: 100, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .help("Abrir \(card) no Linear")
    }

    @ViewBuilder
    private func celulaPR(_ entrega: EntregaPainel) -> some View {
        if let endereco = entrega.urlPR, let url = URL(string: endereco) {
            Button { abrirEndereco(url) } label: {
                Text(Self.rotuloPR(entrega.pr))
                    .font(PV.fonte(12.5, .semibold))
                    .foregroundStyle(PV.azul)
                    .frame(width: 90, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            .help(endereco)
        } else {
            Text(entrega.pr == nil ? "—" : Self.rotuloPR(entrega.pr))
                .foregroundStyle(PV.mudo)
                .frame(width: 90, alignment: .leading)
        }
    }

    private static func rotuloPR(_ pr: String?) -> String {
        pr?.replacingOccurrences(of: "PR ", with: "") ?? "—"
    }
}

// MARK: - Custos

struct PaginaCustos: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada
    @State private var periodo: PeriodoCustos = .semana
    @State private var aba: AbaListaCustos = .todos
    @State private var pagina = 1
    private var snap: SnapshotPainel? { modelo.snapshot }
    private var moeda: MoedaPainel { snap?.custos.moeda ?? .usd }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            VStack(spacing: 13) {
                HStack(alignment: .top, spacing: 13) {
                    cartaoPagina("Resumo", direita: {
                        Text(moeda.detalhe).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                    }) {
                        HStack(spacing: 8) {
                            stat("Gasto de hoje", snap?.custos.hoje.map { moeda.texto($0) }
                                 ?? ((snap?.custos.desconhecidasHoje ?? 0) > 0 ? "—" : "sem dado"), cor: PV.texto)
                            stat("Gasto da semana", snap?.custos.semana.map { moeda.texto($0) } ?? "sem dado", cor: PV.texto)
                            stat("Semana anterior (mesmo ponto)", snap?.indicadores.semanaAnterior.map { moeda.texto($0) } ?? "sem dado",
                                 cor: PV.texto)
                        }
                        if let n = snap?.custos.desconhecidasSemana, n > 0 {
                            Text("\(Formato.plural(n, "execução", "execuções")) da semana com custo desconhecido, fora da soma.")
                                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                        }
                    }
                    cartaoPagina("Uso por conta") {
                        ForEach(Array((snap?.custos.uso ?? []).enumerated()), id: \.offset) { _, uso in
                            HStack(spacing: 10) {
                                Text(uso.lane).font(PV.fonte(12.5)).frame(width: 90, alignment: .leading)
                                BarraPV(fracao: (uso.pct ?? 0) / 100, cor: uso.pct.map { Uso.nivel($0).cor } ?? PV.azulIcone,
                                        altura: 8, trilho: PV.trilho)
                                Text(uso.pct.map { Formato.pct($0) + (uso.janela.map { " \($0)" } ?? "") } ?? "sem medida")
                                    .font(PV.fonte(12.5, uso.pct == nil ? .regular : .semibold))
                                    .foregroundStyle(uso.pct == nil ? PV.mudo : ((uso.pct ?? 0) >= Uso.pctAtencao ? PV.ambar : PV.texto))
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                    }
                }
                cartaoPagina("Builds", direita: { SeletorPeriodo(periodo: $periodo) }) {
                    let p = snap?.custos.periodos[periodo]
                    let filtro = FiltroBusca(busca.texto)
                    let buildsFiltrados = filtro.filtrar(p?.builds ?? []) { b in [b.card, b.descricao, b.lane] }
                    let topFiltrado = filtro.filtrar(p?.top ?? []) { b in [b.card, b.descricao, b.lane] }
                    let fatia: GastoCore.PaginaBuilds = ListaBuilds.pagina(buildsFiltrados, numero: pagina)
                    let top = topFiltrado
                    SeletorAbasCustos(aba: $aba)
                    if p?.total != nil || (aba == .todos && fatia.total > 0) {
                        HStack(spacing: 10) {
                            if let total = p?.total {
                                Text("Total do período: \(moeda.texto(total))")
                                    .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                            }
                            Spacer(minLength: 8)
                            if aba == .todos, fatia.total > 0 {
                                controles(fatia)
                            }
                        }
                    }
                    switch aba {
                    case .todos:
                        if fatia.total == 0 {
                            Text("Nenhum build neste período").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        } else {
                            TabelaCustosBuilds(cards: fatia.itens,
                                               indiceInicial: (fatia.pagina - 1) * fatia.tamanho,
                                               moeda: moeda, agora: ctx.date, abrir: modelo.abrirCard)
                        }
                    case .maisCaros:
                        if top.isEmpty {
                            Text("Sem gasto conhecido neste período").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        } else {
                            TabelaCustosBuilds(cards: top, indiceInicial: 0, moeda: moeda,
                                               agora: ctx.date, abrir: modelo.abrirCard)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .onChange(of: periodo) { _, _ in pagina = 1 }
        .onChange(of: aba) { _, _ in pagina = 1 }
    }

    private func controles(_ fatia: GastoCore.PaginaBuilds) -> some View {
        HStack(spacing: 8) {
            Text(fatia.intervalo).font(PV.fonte(12)).foregroundStyle(PV.mudo)
            BotaoPaginaCustos(texto: "Anterior", ativo: fatia.temAnterior) { pagina = fatia.pagina - 1 }
            Text("página \(fatia.pagina) de \(fatia.paginas)")
                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                .fixedSize()
            BotaoPaginaCustos(texto: "Próxima", ativo: fatia.temProxima) { pagina = fatia.pagina + 1 }
        }
    }
}

/// Tabela de cards da tela Custos. `#` é a posição na lista recebida.
private struct TabelaCustosBuilds: View {
    var cards: [CardCaro]
    var indiceInicial: Int
    var moeda: MoedaPainel
    var agora: Date
    var abrir: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                RotuloColuna(texto: "#").frame(width: 40, alignment: .leading)
                RotuloColuna(texto: "Card").frame(width: 100, alignment: .leading)
                RotuloColuna(texto: "Título").frame(maxWidth: .infinity, alignment: .leading)
                RotuloColuna(texto: "Lane").frame(width: 100, alignment: .leading)
                RotuloColuna(texto: "Status").frame(width: 90, alignment: .leading)
                RotuloColuna(texto: "Duração").frame(width: 90, alignment: .trailing)
                RotuloColuna(texto: "Custo").frame(width: 110, alignment: .trailing)
                RotuloColuna(texto: "Quando").frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            ForEach(Array(cards.enumerated()), id: \.element.card) { i, card in
                HStack(spacing: 0) {
                    Text("\(indiceInicial + i + 1)").frame(width: 40, alignment: .leading)
                    Button { abrir(card.card) } label: {
                        Text(card.card).font(PV.fonte(12.5, .semibold)).foregroundStyle(PV.azul)
                    }
                    .buttonStyle(.plain).frame(width: 100, alignment: .leading)
                    Text(card.descricao ?? card.card).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(card.lane).frame(width: 100, alignment: .leading)
                    Text(card.motivo ?? Formato.plural(card.tentativas, "tentativa", "tentativas"))
                        .foregroundStyle(card.destaque ? Color(hex: 0xFF8DA3) : PV.mudo)
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Text(Formato.duracao(ms: card.duracaoMs)).frame(width: 90, alignment: .trailing)
                    Text(card.custoUSD.map { moeda.texto($0) } ?? "sem custo")
                        .font(PV.fonte(12.5, .semibold)).foregroundStyle(card.custoUSD == nil ? PV.mudo : PV.vermelho)
                        .frame(width: 110, alignment: .trailing)
                    Text(haPainel(card.ultimoInicio, agora: agora) ?? "").foregroundStyle(PV.mudo)
                        .frame(width: 100, alignment: .trailing)
                }
                .font(PV.fonte(12.5))
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(card.destaque ? Color(hex: 0x2A1324) : PV.linha))
            }
        }
    }
}

private struct BotaoPaginaCustos: View {
    var texto: String
    var ativo: Bool
    var acao: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: acao) {
            Text(texto)
                .font(PV.fonte(12.5, .medium))
                .foregroundStyle(ativo ? PV.texto : PV.apagado)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover && ativo ? PV.azulFundo : PV.botao))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PV.campoBorda, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ativo)
        .onHover { h in comAnimacao(DS.suave) { hover = h } }
    }
}

// MARK: - Testes

struct PaginaTestes: View {
    @ObservedObject var modelo: ModeloNotch
    @ObservedObject private var busca = BuscaPainel.compartilhada
    @State private var provaFoco: String?
    @State private var paginaHistorico = 1
    private var snap: SnapshotPainel? { modelo.snapshot }

    var body: some View {
        VStack(spacing: 13) {
            HStack(alignment: .top, spacing: 13) {
                cartaoPagina("Prova em curso", direita: {
                    Text("lock único: uma prova por vez").font(PV.fonte(11.5)).foregroundStyle(PV.ambar)
                }) {
                    if let provas = snap?.provas, !provas.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(provas, id: \.chave) { prova in
                                    let foco = (provaFoco ?? provas.first?.chave) == prova.chave
                                    Button { provaFoco = prova.chave } label: {
                                        HStack(spacing: 7) {
                                            Circle().fill(prova.seguraLock ? PV.ciano : PV.ambar).frame(width: 7, height: 7)
                                            Text(prova.lane.isEmpty ? prova.card : prova.lane)
                                            Text(prova.posicaoFila.map { "fila \($0)º" } ?? (prova.emCurso ? "rodando" : prova.card))
                                                .foregroundStyle(PV.mudo)
                                        }
                                        .font(PV.fonte(12))
                                        .padding(.horizontal, 12).frame(height: 32)
                                        .background(Capsule().fill(foco ? PV.navSelecao : PV.linha))
                                        .overlay(Capsule().strokeBorder(foco ? PV.navSelecaoBorda : PV.campoBorda, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if let carta = provas.first(where: { $0.chave == provaFoco }) ?? provas.first {
                            CartaoProvaV2(carta: carta)
                        }
                    } else {
                        Text("Nenhuma prova agora").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                        RegraZeroTestes(alerta: false)
                    }
                }
                cartaoPagina("Hoje") {
                    let ind = snap?.indicadores ?? .vazio
                    HStack(spacing: 18) {
                        Rosca(passou: ind.testesPassou, falhou: ind.testesFalhou).frame(width: 120, height: 120)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(ind.testesPassou) passou").foregroundStyle(Color(hex: 0x19E58C))
                            Text("\(ind.testesFalhou) falhou").foregroundStyle(Color(hex: 0xF64561))
                            Text("— ignorado").foregroundStyle(PV.mudo).help("Testes ignorados: em breve")
                            Text(Formato.plural(ind.provasHoje, "prova hoje", "provas hoje")).foregroundStyle(PV.mudo)
                        }
                        .font(PV.fonte(12.5))
                    }
                }
                .frame(width: 380)
            }
            cartaoPagina("Histórico") {
                let historico = FiltroBusca(busca.texto).filtrar(snap?.historico ?? []) { h in
                    [h.card, h.titulo, h.lane, h.selo] }
                if historico.isEmpty {
                    Text("Sem prova terminada ainda").font(PV.fonte(12.5)).foregroundStyle(PV.mudo)
                } else {
                    let fatia = ListaPaginada.cortar(historico, numero: paginaHistorico, vazio: "0 provas")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(Formato.plural(historico.count, "prova", "provas"))
                                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                            Spacer(minLength: 8)
                            controlesHistorico(fatia)
                        }
                        TabelaHistoricoTestes(itens: fatia.itens, abrir: modelo.abrirCard)
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private func controlesHistorico(_ fatia: ListaPaginada<ResumoProvaHistorico>) -> some View {
        HStack(spacing: 8) {
            Text(fatia.intervalo).font(PV.fonte(12)).foregroundStyle(PV.mudo)
            BotaoPaginaCustos(texto: "Anterior", ativo: fatia.temAnterior) { paginaHistorico = fatia.pagina - 1 }
            Text("página \(fatia.pagina) de \(fatia.paginas)")
                .font(PV.fonte(12)).foregroundStyle(PV.mudo)
                .fixedSize()
            BotaoPaginaCustos(texto: "Próxima", ativo: fatia.temProxima) { paginaHistorico = fatia.pagina + 1 }
        }
    }
}

/// Histórico da tela Testes, no mesmo desenho da tabela de Custos. Falha pinta a linha como `destaque`.
private struct TabelaHistoricoTestes: View {
    var itens: [ResumoProvaHistorico]
    var abrir: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                RotuloColuna(texto: "Card").frame(width: 90, alignment: .leading)
                RotuloColuna(texto: "Título").frame(maxWidth: .infinity, alignment: .leading)
                RotuloColuna(texto: "Lane").frame(width: 90, alignment: .leading)
                RotuloColuna(texto: "Resultado").frame(width: 90, alignment: .leading)
                RotuloColuna(texto: "Duração").frame(width: 80, alignment: .trailing)
                RotuloColuna(texto: "Quando").frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            ForEach(Array(itens.enumerated()), id: \.offset) { _, item in
                let falha = item.falha || item.zeroTestes
                HStack(spacing: 0) {
                    Button { abrir(item.card) } label: {
                        Text(item.card).font(PV.fonte(12.5, .semibold)).foregroundStyle(PV.azul)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain).frame(width: 90, alignment: .leading)
                    Text((item.titulo == nil || item.titulo == "sem descrição") ? item.card : item.titulo!)
                        .foregroundStyle((item.titulo == nil || item.titulo == "sem descrição") ? PV.mudo : PV.texto)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.lane.isEmpty ? "—" : item.lane)
                        .foregroundStyle(item.lane.isEmpty ? PV.mudo : PV.texto)
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Text(item.selo)
                        .font(PV.fonte(12.5, .semibold))
                        .foregroundStyle(corSelo(item))
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    Text(Formato.relogio(item.segundos))
                        .frame(width: 80, alignment: .trailing)
                    Text(item.titulo == nil ? "—" : haPainel(Date(), agora: Date()) ?? "")
                        .foregroundStyle(PV.mudo)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(PV.fonte(12.5))
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(falha ? Color(hex: 0x2A1324) : PV.linha))
            }
        }
    }

    private func corSelo(_ item: ResumoProvaHistorico) -> Color {
        if item.zeroTestes { return .white }
        if item.falha { return Color(hex: 0xFF8DA3) }
        if item.emCurso { return PV.ambar }
        return PV.verde
    }
}

private extension CartaoProva {
    var chave: String { "\(lane)|\(card)" }
}

/// Cartão de uma prova: fases, suítes, falhas, motivo e próxima ação (conteúdo do v1, visual v2).
struct CartaoProvaV2: View {
    var carta: CartaoProva

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text(carta.card).font(PV.fonte(16, .bold)).foregroundStyle(PV.azul)
                VStack(alignment: .leading, spacing: 2) {
                    Text(carta.descricao).font(PV.fonte(12.5)).lineLimit(2)
                    Text(subtitulo).font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                }
                Spacer(minLength: 8)
                Text(carta.posicaoFila.map { "posição \($0) na fila" } ?? "tentativa \(carta.tentativa) de \(carta.tentativas)")
                    .font(PV.fonte(12, .semibold)).foregroundStyle(PV.ambar)
            }
            if carta.posicaoFila != nil {
                HStack(spacing: 12) {
                    Text(carta.esperaSegundos.map { Formato.relogio($0) } ?? "sem relógio")
                        .font(PV.fonte(20, .semibold)).foregroundStyle(PV.ambar)
                    Text(carta.proximaAcao).font(PV.fonte(12)).foregroundStyle(PV.mudo)
                }
            } else {
                fases
                if !carta.suites.isEmpty { GradeSuites(suites: carta.suites) }
                if let motivo = carta.motivo {
                    Text(motivo).font(PV.fonte(12))
                        .foregroundStyle(carta.zeroTestes || carta.falha ? Color(hex: 0xFFB3C1) : PV.texto)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(PV.vermelho.opacity(carta.falha || carta.zeroTestes ? 0.16 : 0.08)))
                }
                Text("Próxima ação: \(carta.proximaAcao)").font(PV.fonte(12.5)).foregroundStyle(Color(hex: 0x8CC4FF))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(PV.navSelecao))
                RegraZeroTestes(alerta: carta.zeroTestes)
            }
        }
        .padding(.top, 4)
    }

    private var subtitulo: String {
        let quem = carta.lane.isEmpty ? "lane sem nome" : "lane \(carta.lane)"
        if carta.emCurso { return "\(quem), prova há \(Formato.relogio(carta.segundos))" }
        if let espera = carta.esperaSegundos { return "\(quem), espera há \(Formato.relogio(espera))" }
        return "\(quem), \(Formato.relogio(carta.segundos))"
    }

    private var fases: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(carta.fases.enumerated()), id: \.offset) { i, fase in
                VStack(spacing: 4) {
                    Text(marca(fase, i))
                        .font(PV.fonte(11, .semibold))
                        .foregroundStyle(fase.marca == .atual ? Color(hex: 0x04121F) : PV.texto)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(fundo(fase.marca)))
                        .overlay(Circle().strokeBorder(borda(fase.marca), lineWidth: 1))
                    Text(fase.fase.rotulo).font(PV.fonte(12.5, .semibold))
                    Text(fase.detalhe).font(PV.fonte(11)).foregroundStyle(PV.mudo).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    HStack(spacing: 0) {
                        Rectangle().fill(i == 0 ? Color.clear : (carta.fases[i - 1].marca == .feita ? PV.verde : PV.trilho))
                        Rectangle().fill(i == carta.fases.count - 1 ? Color.clear : (fase.marca == .feita ? PV.verde : PV.trilho))
                    }
                    .frame(height: 2).padding(.top, 13)
                }
            }
        }
    }

    private func marca(_ f: FaseMarcada, _ i: Int) -> String {
        switch f.marca {
        case .feita: return "ok"
        case .falha: return "x"
        case .atual, .aguardando: return "\(i + 1)"
        }
    }

    private func fundo(_ m: MarcaFase) -> Color {
        switch m {
        case .feita: return PV.verdeFundo
        case .falha: return PV.vermelhoFundo
        case .atual: return PV.ciano
        case .aguardando: return PV.cartao
        }
    }

    private func borda(_ m: MarcaFase) -> Color {
        switch m {
        case .feita: return PV.verde
        case .falha: return PV.vermelho
        case .atual: return PV.ciano
        case .aguardando: return Color(hex: 0x3A4C68)
        }
    }
}

/// Uma suíte = um quadradinho (nome e tempo no hover). Com 100+ suítes, cards lado a lado
/// estouravam a largura da coluna e empurravam o painel inteiro para fora da janela.
struct GradeSuites: View {
    var suites: [SuiteProva]

    var body: some View {
        let ok = suites.filter { $0.estado == .ok }.count
        let falhas = suites.filter { $0.estado == .falha }
        let pendentes = suites.count - ok - falhas.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Suítes (\(suites.count))").foregroundStyle(PV.mudo)
                Text("\(ok) ok").foregroundStyle(PV.verde)
                if !falhas.isEmpty { Text("\(falhas.count) falha").foregroundStyle(PV.vermelho) }
                if pendentes > 0 { Text("\(pendentes) pendente").foregroundStyle(PV.mudo) }
            }
            .font(PV.fonte(12.5))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 9, maximum: 12), spacing: 3)], alignment: .leading, spacing: 3) {
                ForEach(Array(suites.enumerated()), id: \.offset) { _, suite in
                    RoundedRectangle(cornerRadius: 2).fill(cor(suite.estado)).frame(height: 9)
                        .help("\(suite.nome) · \(legenda(suite))")
                }
            }
            if !falhas.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Array(falhas.enumerated()), id: \.offset) { _, suite in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suite.nome).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Text(legenda(suite)).font(PV.fonte(11)).foregroundStyle(Color(hex: 0xFFB3C1))
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x2A1324)))
                        .overlay(alignment: .bottom) { Rectangle().fill(PV.vermelho).frame(height: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func cor(_ e: EstadoSuite) -> Color {
        switch e {
        case .ok: return PV.verde
        case .falha: return PV.vermelho
        case .pendente: return Color(hex: 0x2A3A52)
        }
    }

    private func legenda(_ s: SuiteProva) -> String {
        switch s.estado {
        case .ok: return s.segundos.map { Formato.relogio($0) } ?? "ok"
        case .falha: return s.segundos.map { "\(Formato.relogio($0)), falhou" } ?? "falhou"
        case .pendente: return "pendente"
        }
    }
}

/// Vermelho só quando a prova rodou 0 testes. No resto, a regra fica cinza.
struct RegraZeroTestes: View {
    var alerta: Bool

    var body: some View {
        HStack(spacing: 8) {
            if alerta {
                Text("!").font(PV.fonte(12, .bold)).foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(Circle().fill(PV.vermelho))
            }
            Text("0 testes rodados = falha.").font(PV.fonte(12.5, alerta ? .semibold : .regular))
                .foregroundStyle(alerta ? PV.vermelho : PV.mudo)
            Text("A prova é reprovada mesmo que o xcodebuild diga sucesso.").font(PV.fonte(12.5))
                .foregroundStyle(alerta ? Color(hex: 0xFFB3C1) : PV.mudo)
        }
        .padding(alerta ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if alerta { RoundedRectangle(cornerRadius: 8).fill(PV.vermelho.opacity(0.16)) } }
    }
}
