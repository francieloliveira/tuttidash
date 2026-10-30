import SwiftUI
import GastoCore

/// Bloco de leitura-only da lane revisora: mostra modelo e esforço herdados
/// da lane selecionada em `revisores.pr.lane`. Não é configurável à mão.
struct BlocoRevisaoAtual: View {
    let modelo: ModeloAjustes

    private var laneSelecionada: String {
        Configuracao.valor("revisores.pr.lane", em: modelo.dados) as? String ?? ""
    }

    private var agentes: [CatalogoAgentes.ModeloAgente] {
        CatalogoAgentes.carregar()
    }

    private var agente: CatalogoAgentes.ModeloAgente? {
        agentes.first { $0.nome == laneSelecionada }
    }

    private var modeloRevisao: String {
        agente?.revisao?.modeloPadrao ?? String(localized: "não definido")
    }

    private var esforcoRevisao: String {
        guard let e = agente?.revisao?.esforcoPadrao, !e.isEmpty else {
            return String(localized: "não definido")
        }
        return CatalogoAjustes.nomesEsforco[e] ?? e
    }

    var body: some View {
        Section {
            if laneSelecionada.isEmpty {
                Text(String(localized: "Selecione uma lane revisora acima."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent(String(localized: "Lane revisora")) {
                    Text(agente?.rotulo ?? laneSelecionada).textSelection(.enabled)
                }
                LabeledContent(String(localized: "Modelo na revisão")) {
                    Text(modeloRevisao).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent(String(localized: "Esforço na revisão")) {
                    Text(esforcoRevisao).textSelection(.enabled)
                }
                if agente?.revisao?.auto == true {
                    Text(String(localized: "Pode ser usado como revisor reserva automático."))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Não entra na reserva automática (auto desligado no manifesto)."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Modelo e esforço da lane revisora")).font(.headline).foregroundStyle(.white)
        }
    }
}
