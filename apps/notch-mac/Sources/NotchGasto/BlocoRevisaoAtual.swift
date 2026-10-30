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
                Text(String(localized: "Esforço: definido pela task do card (não pela lane)."))
                    .font(.caption2).foregroundStyle(.secondary)
                if agente?.revisao?.auto == true {
                    Text(String(localized: "Pode ser usado como revisor reserva automático."))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Não entra na reserva automática (auto desligado no manifesto)."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Modelo da lane revisora")).font(.headline).foregroundStyle(.white)
        }
    }
}
