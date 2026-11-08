import Foundation
import GastoCore

// Lê o % de uso das contas das lanes (mesma fonte do app de notch).
// Saída, uma conta por linha, separada por TAB:
//   com janela: conta  pct  janela  reset
//   sem janela: conta  ?    motivo  -      codigo  saldo
// `codigo` é o motivo tipado (ErroUso.codigo) e `saldo` o saldo em US$ (vazio se não houver).
// Quem lê só as 4 primeiras colunas continua funcionando.
let config = Configuracao.resolver()
let usos = await ColetorUso().coletar(config: config)
let f = ISO8601DateFormatter()
for u in usos {
  if let j = u.critica {
    print("\(u.conta)\t\(Int(j.pct.rounded()))\t\(j.rotulo)\t\(j.resetEm.map { f.string(from: $0) } ?? "-")")
  } else {
    let saldo = u.saldoUSD.map { String(format: "%.4f", $0) } ?? ""
    print("\(u.conta)\t?\t\(u.motivo ?? "sem dado")\t-\t\(u.codigo ?? "")\t\(saldo)")
  }
}
