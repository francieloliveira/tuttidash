import SwiftUI
import GastoCore

/// Estado observável da interface. Atualizado na main thread.
@MainActor
final class ModeloNotch: ObservableObject {
    @Published var resumo: Resumo?
    @Published var config: Configuracao = Configuracao.resolver()
    @Published var ledgerExiste = false
    @Published var logsDirExiste = false
    @Published var atualizadoEm: Date?
    @Published var expandido = false
    /// Limites das contas (uma por tipo do registry). Vazio = ainda lendo ou desligado na config.
    @Published var usos: [UsoConta] = [] {
        didSet { if oldValue != usos { nivelAviso = .completo } }
    }
    /// Intervalos e quando animar/conferir o mouse (FRA-339).
    let politica = PoliticaAtualizacao.padrao
    /// Regra de largura da pílula: cresce com o conteúdo ou encurta o aviso, nunca corta.
    let geometria = GeometriaPilula.padrao
    /// Largura medida do conteúdo do lado esquerdo/direito da pílula.
    @Published var conteudoEsquerda: CGFloat = 0 { didSet { if oldValue != conteudoEsquerda { aoMudarPilula() } } }
    @Published var conteudoDireita: CGFloat = 0 { didSet { if oldValue != conteudoDireita { aoMudarPilula() } } }
    /// Quanto do aviso de limite cabe na pílula.
    @Published var nivelAviso: NivelAviso = .completo
    var aoMudarPilula: () -> Void = {}
    /// Lanes que pararam sem fechar o card e podem ser retomadas (mais nova primeiro).
    @Published var retomadas: [Retomada] = []

    /// A conta mais apertada acima de 80%: é o alerta que aparece no recolhido.
    var alertaUso: UsoConta? {
        var pior: UsoConta?
        for u in usos where u.alerta && (pior == nil || (u.pct ?? 0) > (pior?.pct ?? 0)) { pior = u }
        return pior
    }

    /// Reset da janela semanal de cada conta, quando o servidor informou.
    /// Chave = nome da conta/lane (claude, codex, opencode, grok, cursor).
    /// Prefere a janela cujo rótulo é "semana"; senão usa a janela crítica da conta.
    var resetSemanal: [String: Date] {
        var saida: [String: Date] = [:]
        for u in usos {
            let j = u.janelas.first { $0.rotulo.localizedCaseInsensitiveContains("semana") } ?? u.critica
            if let r = j?.resetEm { saida[u.conta] = r }
        }
        return saida
    }

    // Geometria da tela
    @Published var temNotch = true
    @Published var larguraNotch: CGFloat = 196
    @Published var alturaNotch: CGFloat = 34
    /// Retrato do painel e do notch, calculado só com o que foi lido.
    @Published var snapshot: SnapshotPainel?
    /// Log cru do dispatcher. Começa fechado: só o botão «Ver log detalhado» abre.
    @Published var logDetalhado = false
    /// Lane escolhida no notch expandido para o botão desativar.
    @Published var laneEmFoco: String?
    /// Mensagem das ações de lane; cada uma vira um aviso na janela principal (FRA-531).
    @Published var avisoCtl: String? {
        didSet {
            guard let m = avisoCtl, m != oldValue else { return }
            if m.hasSuffix("…") { CentralAvisos.compartilhada.info(m) }
            else if m.hasPrefix("Não") || m.contains("código") || m.contains("inválida") { CentralAvisos.compartilhada.erro(String(localized: "Não deu certo"), m) }
            else { CentralAvisos.compartilhada.ok(m) }
        }
    }
    /// Leitura dos dados e medição de uso pedidas pelo usuário em andamento (indicador no cabeçalho).
    /// Só «Atualizar agora» e abrir o painel com dados antigos acendem; o timer não (FRA-583).
    @Published var atualizando = false
    @Published var medindoUso = false
    @Published var usoEm: Date?
    /// Lanes com ativar/desativar em andamento (indicador no menu da lane).
    @Published var lanesEmAcao: Set<String> = []
    var atualizarAgora: () -> Void = {}
    var abrirPainel: () -> Void = {}
    var desativarLane: (String) -> Void = { _ in }
    var ativarLane: (String) -> Void = { _ in }

    /// Tamanho real do notch expandido (medido), para o hit-test do hover.
    @Published var tamanhoPainel: CGSize = CGSize(width: Tema.larguraNotchAberto, height: 420) {
        didSet { if oldValue != tamanhoPainel { aoMudarTamanho() } }
    }
    var aoMudarTamanho: () -> Void = {}

    var abrirConfig: () -> Void = {}
    var abrirCard: (String) -> Void = { _ in }
    /// Abre um pull request cuja URL já veio no fechamento (`https://github.com/.../pull/N`).
    var abrirEndereco: (URL) -> Void = { _ in }
    var copiar: (String) -> Void = { _ in }

    /// Largura do lado esquerdo da pílula recolhida (os indicadores ficam à esquerda).
    var ladoEsquerdoPilula: CGFloat {
        CGFloat(geometria.lado(esquerda: Double(conteudoEsquerda), direita: 0))
    }

    /// Largura do lado direito da pílula recolhida (mínimo, sem sobrar à direita do notch).
    var ladoDireitoPilula: CGFloat {
        conteudoDireita > 0 ? CGFloat((Double(conteudoDireita) + geometria.respiro).rounded(.up)) : 0
    }

    /// Largura da pílula recolhida: lado esquerdo + vão do notch + lado direito (enxuto).
    var larguraPilula: CGFloat {
        let vao = temNotch ? larguraNotch : CGFloat(geometria.vaoSemNotch)
        return ladoEsquerdoPilula + vao + ladoDireitoPilula
    }

    /// Deslocamento horizontal do centro da pílula em relação ao centro físico do notch.
    var deslocamentoCentroPilula: CGFloat {
        (ladoDireitoPilula - ladoEsquerdoPilula) / 2
    }

    /// Depois de medir: encurta o aviso um passo se ainda não couber.
    func conferirAviso() {
        let n = geometria.nivelAviso(atual: nivelAviso, esquerda: Double(conteudoEsquerda),
                                     direita: Double(conteudoDireita))
        if n != nivelAviso { nivelAviso = n }
    }
}

/// Texto da busca do painel (FRA-563), fora do `ModeloNotch`: cada tecla redesenha só a
/// página aberta e o campo, e não o notch, a pílula e as outras telas que observam o modelo.
@MainActor
final class BuscaPainel: ObservableObject {
    static let compartilhada = BuscaPainel()
    @Published var texto = ""
}
