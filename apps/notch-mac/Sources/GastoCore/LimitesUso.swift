import Foundation

/// Nível de alerta de uma janela de limite de uso da conta.
/// Regras do GOAL: amarelo a partir de 80%, vermelho a partir de 95%.
public enum NivelUso: String, Sendable {
    case ok
    case atencao
    case critico
}

public enum Uso {
    public static let pctAtencao = 80.0
    public static let pctCritico = 95.0

    public static func nivel(_ pct: Double, atencao: Double = pctAtencao, critico: Double = pctCritico) -> NivelUso {
        if pct >= critico { return .critico }
        if pct >= atencao { return .atencao }
        return .ok
    }
}

/// Uma janela de limite da conta: 5 h, semana, semana por modelo, período de crédito.
/// `pct` é quanto já foi usado (0...100, pode passar de 100); falta = 100 - pct.
public struct JanelaUso: Equatable, Sendable {
    public var chave: String
    public var rotulo: String
    public var pct: Double
    /// Quando a janela zera. nil = o servidor não informou.
    public var resetEm: Date?

    public init(chave: String, rotulo: String, pct: Double, resetEm: Date? = nil) {
        self.chave = chave; self.rotulo = rotulo; self.pct = pct; self.resetEm = resetEm
    }

    public var nivel: NivelUso { Uso.nivel(pct) }
    /// Quanto falta do limite, em pontos percentuais (nunca negativo).
    public var faltaPct: Double { max(100 - pct, 0) }
}

/// Limite de uso de uma conta usada pelas lanes (um tipo do registry por conta).
/// Sem dado = `janelas` vazio e `motivo` preenchido — nunca um número inventado.
public struct UsoConta: Equatable, Sendable {
    public var conta: String
    public var rotulo: String
    /// De onde o número veio, para o tooltip (ex.: "opencode.db · session_v2").
    public var fonte: String
    public var janelas: [JanelaUso]
    public var motivo: String?
    public var atualizadoEm: Date?
    /// claude, grok ou cursor (como foi medido).
    public var tipo: String = ""
    public var nome: String = ""
    public var sigla: String = ""

    public init(conta: String, rotulo: String, fonte: String, janelas: [JanelaUso] = [],
                motivo: String? = nil, atualizadoEm: Date? = nil) {
        self.conta = conta; self.rotulo = rotulo; self.fonte = fonte
        self.tipo = conta; self.nome = conta; self.sigla = String(conta.prefix(1)).uppercased()
        self.janelas = janelas; self.motivo = motivo; self.atualizadoEm = atualizadoEm
    }

    public var temDado: Bool { !janelas.isEmpty }

    /// A janela mais apertada: é ela que manda na cor da barra e no alerta do recolhido.
    /// Empate fica com a primeira (a ordem das janelas é fixa: 5 h antes da semana).
    public var critica: JanelaUso? {
        var maior: JanelaUso?
        for j in janelas where maior == nil || j.pct > maior!.pct { maior = j }
        return maior
    }

    public var pct: Double? { critica?.pct }
    public var nivel: NivelUso? { critica?.nivel }
    public var alerta: Bool { (pct ?? 0) >= Uso.pctAtencao }
}

/// Por que uma conta ficou sem dado. `mensagem` é o texto que vai para o painel.
public enum ErroUso: Error, Equatable, Sendable {
    /// O arquivo de credencial não existe (CLI nunca logou neste Mac).
    case semCredencial(String)
    case credencialIlegivel(String)
    /// O token no disco já venceu. O app não renova (não grava em ~/.claude nem ~/.grok).
    case tokenExpirado(String)
    case naoAutorizado
    case limitado
    case http(Int)
    case rede(String)
    case respostaIlegivel
    case semJanelas
    case desligado
    /// O plano não tem limite incluído.
    case semLimiteIncluido
    /// A conta usa a cota compartilhada da empresa, sem % individual.
    case cotaCompartilhada
    /// Motivo dado por uma fonte registrada de fora (`FonteUso`).
    case motivo(String)
    /// Igual a `motivo`, e a próxima tentativa espera como depois de um 429.
    case motivoEsperar(String)
    /// Copilot: falta o usuário do GitHub nos Ajustes.
    case semUsuarioCopilot
    /// Copilot: o usuário tem caractere que a API não aceita no caminho.
    case usuarioCopilotInvalido
    /// Copilot: cota mensal ausente ou zero. Não vira 0%.
    case semCotaInformada
    /// Copilot: nem Keychain nem arquivo têm token.
    case semTokenCopilot
    /// Copilot: o relatório pessoal veio vazio (licença de organização/empresa).
    case licencaOrganizacao
    /// Copilot: o JSON é o relatório da organização, não o da conta pessoal.
    case respostaOrganizacao
    /// Copilot: `timePeriod` não é o mês pedido.
    case relatorioOutroMes
    /// Copilot: 401 ou 403. O app não renova o token.
    case tokenCopilotRecusado
    /// Copilot: 404 no relatório pessoal.
    case copilotSemRelatorio
    /// Copilot: havia itens, mas nenhum com quantidade de requisições.
    case semQuantidadeCopilot

    public var mensagem: String {
        switch self {
        case .semCredencial(let cli):
            return "sem credencial local (rode `\(cli)` e faça login)"
        case .credencialIlegivel(let caminho):
            return "credencial ilegível em \(caminho)"
        case .tokenExpirado(let cli):
            return "token local vencido (rode `\(cli)` para renovar)"
        case .naoAutorizado:
            return "token recusado pelo servidor (rode o CLI para renovar)"
        case .limitado:
            return "servidor pediu para esperar (429)"
        case .http(let c):
            return "servidor respondeu HTTP \(c)"
        case .rede(let d):
            return "sem resposta: \(d)"
        case .respostaIlegivel:
            return "resposta do servidor ilegível"
        case .semJanelas:
            return "servidor não informou nenhuma janela de limite"
        case .desligado:
            return "desligado na config (uso_contas)"
        case .semLimiteIncluido:
            return "plano sem limite incluído"
        case .cotaCompartilhada:
            return "cota compartilhada da empresa (sem % individual)"
        case .motivo(let texto), .motivoEsperar(let texto):
            return texto
        case .semUsuarioCopilot:
            return "sem usuário do GitHub"
        case .usuarioCopilotInvalido:
            return "usuário do GitHub inválido"
        case .semCotaInformada:
            return "sem cota informada"
        case .semTokenCopilot:
            return "sem token do GitHub (cole em Ajustes › Contas; fica no Keychain, ou aponte um arquivo)"
        case .licencaOrganizacao:
            return "licença gerida por organização ou empresa: o relatório pessoal veio vazio"
        case .respostaOrganizacao:
            return "resposta de organização, não da conta pessoal"
        case .relatorioOutroMes:
            return "relatório de outro mês"
        case .tokenCopilotRecusado:
            return "token do GitHub recusado pelo servidor"
        case .copilotSemRelatorio:
            return "usuário do GitHub sem relatório pessoal"
        case .semQuantidadeCopilot:
            return "relatório sem quantidade de requisições premium"
        }
    }
}
