import Foundation

/// Textos que separam o SuperGrok (Grok Bot, medido pela sessão do Cursor) da lane
/// do Grok CLI. Só copy: não lê nem grava `enabled`, PAUSE, billing ou dispatcher.
public enum ClarezaCota {
    public static let tituloSuperGrok = String(localized: "Grok Bot / SuperGrok (via Cursor)")
    public static let tituloGrokCLI = String(localized: "Grok CLI")
    public static let nomeCurtoSuperGrok = String(localized: "SuperGrok")
    public static let detalheGrokCLI = String(localized: "Lane do comando grok no terminal. Créditos próprios, separados do SuperGrok.")
    public static let detalheSuperGrok = String(localized: "Mede o % do menu SuperGrok pela sessão do Cursor. Não pega card. Cota separada do Grok CLI.")
    public static let seloNaoELane = String(localized: "não é lane")
    /// Cabeçalho da lista, nunca rodapé: no Form do macOS o rodapé cola na última linha.
    public static let ajudaLanesLigadas = String(localized: "Só as lanes ligadas recebem cards novos. Desligar não interrompe o card que já está rodando.")
    public static let ajudaUsoSuperGrok = String(localized: "Esta conta não tem interruptor e não recebe card. SuperGrok (Cursor e Grok Bot) é a mesma cota Sand. Desligar o Grok CLI não muda o % do SuperGrok: cotas e créditos separados.")
    public static let notaSuperGrok = String(localized: "Grok Bot / SuperGrok, lido pela sessão do Cursor. Não compartilha cota nem crédito com o Grok CLI.")
    public static let notaGrokCLI = String(localized: "Grok CLI no terminal. Créditos próprios, separados do SuperGrok.")
    public static let detalheGemini = String(localized: "Conta de uso do Gemini CLI. Desligada até você adicionar. Não renova o token.")
    public static let notaGemini = String(localized: "Gemini CLI. Conta consumer Google AI Pro/Ultra pode ficar sem dado: o Google barrou esse acesso.")
    public static let detalheCopilot = String(localized: "Requisições premium do GitHub Copilot na conta pessoal. Não pega card. A cota do mês é a que você informa.")
    public static let notaCopilot = String(localized: "Relatório oficial de billing da conta pessoal. Licença de organização não entra neste número. O token fica no Keychain.")

    public struct LinhaAjuste: Equatable, Sendable {
        public var titulo: String
        public var detalhe: String?
        public init(titulo: String, detalhe: String?) {
            self.titulo = titulo
            self.detalhe = detalhe
        }
    }

    /// Lane que o dispatcher pode mandar card: entra no painel e tem CLI.
    public static func recebeCard(_ d: Agentes.Def) -> Bool {
        d.painel && d.cli != nil
    }

    /// Conta de uso (Cursor / SuperGrok): não pega card.
    public static func contaDeUso(_ d: Agentes.Def) -> Bool {
        !recebeCard(d)
    }

    public static func linha(nome: String, rotulo: String) -> LinhaAjuste {
        LinhaAjuste(titulo: titulo(nome: nome, rotulo: rotulo), detalhe: detalhe(nome: nome))
    }

    public static func linhaLane(_ d: Agentes.Def) -> LinhaAjuste {
        linha(nome: d.nome, rotulo: d.rotulo)
    }

    /// Linha da lista «Lanes ligadas». As cinco lanes de desenvolvimento ficam iguais:
    /// só o título e o interruptor. O subtítulo longo só no Grok, junto com o rodapé
    /// da Section, fazia o Form do macOS desenhar essa linha fora do grupo.
    public static func linhaLista(_ d: Agentes.Def) -> LinhaAjuste {
        LinhaAjuste(titulo: titulo(nome: d.nome, rotulo: d.rotulo), detalhe: nil)
    }

    /// Título estável. Para cursor e grok ignora o rótulo cru do manifesto (`Cursor`),
    /// que misturava a conta de uso com a lane do terminal.
    public static func titulo(nome: String, rotulo: String) -> String {
        switch nome {
        case "grok": return tituloGrokCLI
        case "cursor": return tituloSuperGrok
        default: return rotulo
        }
    }

    public static func detalhe(nome: String) -> String? {
        switch nome {
        case "grok": return detalheGrokCLI
        case "cursor": return detalheSuperGrok
        case "gemini": return detalheGemini
        case "copilot": return detalheCopilot
        default: return nil
        }
    }

    public static func tituloSecaoUso(nomes: [String]) -> String {
        if !nomes.isEmpty && nomes.allSatisfy({ $0 == "cursor" }) {
            return String(localized: "Uso do SuperGrok")
        }
        return String(localized: "Contas de uso")
    }

    public static func ajudaSecaoUso(nomes: [String]) -> String {
        if !nomes.isEmpty && nomes.allSatisfy({ $0 == "cursor" }) {
            return ajudaUsoSuperGrok
        }
        return String(localized: "Estas contas medem uso. Não recebem card e não têm interruptor.")
    }

    /// Nome curto no card «Limites das contas» e no menu. Apelido gravado pelo usuário fica;
    /// o id cru `cursor` / `grok` vira um nome que não mistura as duas cotas.
    public static func nomeCurto(tipo: String, nome: String, rotulo: String) -> String {
        let apelido = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tipo {
        case "cursor":
            if apelido.isEmpty || apelido.caseInsensitiveCompare("cursor") == .orderedSame {
                return nomeCurtoSuperGrok
            }
            break
        case "copilot":
            if apelido.isEmpty || apelido.caseInsensitiveCompare("copilot") == .orderedSame {
                return String(localized: "Copilot")
            }
            break
        case "grok":
            if apelido.isEmpty || apelido.caseInsensitiveCompare("grok") == .orderedSame {
                return tituloGrokCLI
            }
            break
        default:
            break
        }
        if !apelido.isEmpty { return apelido }
        let salvo = rotulo.trimmingCharacters(in: .whitespacesAndNewlines)
        return salvo.isEmpty ? tipo : salvo
    }

    /// Rótulo no cadastro de contas e na primeira abertura. Apelido customizado fica.
    public static func rotuloConta(tipo: String, rotuloSalvo: String) -> String {
        let salvo = rotuloSalvo.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tipo {
        case "cursor":
            if salvo.isEmpty || salvo.caseInsensitiveCompare("cursor") == .orderedSame {
                return tituloSuperGrok
            }
            return salvo
        case "grok":
            if salvo.isEmpty || salvo.caseInsensitiveCompare("grok") == .orderedSame || salvo == "Grok CLI" {
                return tituloGrokCLI
            }
            return salvo
        case "copilot":
            if salvo.isEmpty || salvo.caseInsensitiveCompare("copilot") == .orderedSame {
                return String(localized: "Copilot")
            }
            return salvo
        default:
            return salvo.isEmpty ? tipo : salvo
        }
    }

    /// Primeira linha do tooltip. Troca o rótulo ambíguo `Cursor`; apelido customizado fica.
    public static func rotuloAjuda(tipo: String, rotulo: String) -> String {
        let claro = rotuloConta(tipo: tipo, rotuloSalvo: rotulo)
        return claro.isEmpty ? rotulo : claro
    }

    public static func notaCota(_ tipo: String) -> String? {
        switch tipo {
        case "cursor": return notaSuperGrok
        case "grok": return notaGrokCLI
        case "gemini": return notaGemini
        case "copilot": return notaCopilot
        default: return nil
        }
    }
}
