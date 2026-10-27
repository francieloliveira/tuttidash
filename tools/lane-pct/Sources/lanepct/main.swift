import Foundation
import GastoCore
#if canImport(GastoPrivado)
import GastoPrivado
GastoPrivado.registrar()
#endif
// Le o % de uso das contas das lanes (mesma fonte do app de notch). Saida: conta<TAB>pct<TAB>janela<TAB>reset
let config = Configuracao.resolver()
let usos = await ColetorUso().coletar(config: config)
let f = ISO8601DateFormatter()
for u in usos {
  if let j = u.critica {
    print("\(u.conta)\t\(Int(j.pct.rounded()))\t\(j.rotulo)\t\(j.resetEm.map { f.string(from: $0) } ?? "-")")
  } else {
    print("\(u.conta)\t?\t\(u.motivo ?? "sem dado")\t-")
  }
}
