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
        VStack(alignment: .leading, spacing: DS.e2) {
            if laneSelecionada.isEmpty {
                Text(String(localized: "Selecione uma lane revisora acima."))
                    .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.e3) {
                    Text(String(localized: "Lane revisora"))
                        .font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                    Spacer(minLength: DS.e3)
                    Text(agente?.rotulo ?? laneSelecionada)
                        .font(PV.fonte(12.5)).foregroundStyle(PV.texto)
                        .textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.e3) {
                    Text(String(localized: "Modelo na revisão"))
                        .font(PV.fonte(12.5)).foregroundStyle(PV.texto2)
                    Spacer(minLength: DS.e3)
                    Text(modeloRevisao)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(PV.texto)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Text(String(localized: "Esforço: definido pela task do card (não pela lane)."))
                    .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                if agente?.revisao?.auto == true {
                    Text(String(localized: "Pode ser usado como revisor reserva automático."))
                        .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                } else {
                    Text(String(localized: "Não entra na reserva automática (auto desligado no manifesto)."))
                        .font(PV.fonte(11.5)).foregroundStyle(PV.mudo)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
