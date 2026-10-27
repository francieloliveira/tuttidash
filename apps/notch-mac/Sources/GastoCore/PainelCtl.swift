import Foundation

/// O botão desativar do notch só monta `lanes_ctl.py disable <lane>`.
/// Quem chama é que executa. Este tipo não abre `enabled` e não cria PAUSE.
public enum AcaoDesativar {
    public static func pedido(lane: String, script: String) -> PedidoDesativar? {
        let nome = lane.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nomeValido(nome) else { return nil }
        let caminho = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caminho.isEmpty else { return nil }
        return PedidoDesativar(executavel: "/usr/bin/python3", argumentos: [caminho, "disable", nome])
    }

    /// `rodar` recebe o pedido já montado. Lane inválida não chama `rodar`.
    public static func executar(lane: String, script: String, rodar: (PedidoDesativar) -> Int32) -> ResultadoCtl {
        guard let pedido = pedido(lane: lane, script: script) else {
            return ResultadoCtl(pedido: PedidoDesativar(executavel: "", argumentos: []), codigo: 2, executou: false)
        }
        return ResultadoCtl(pedido: pedido, codigo: rodar(pedido), executou: true)
    }

    /// Mesma forma do dispatcher: `[a-z][a-z0-9_-]*` (ex.: `opencode-go`).
    static func nomeValido(_ nome: String) -> Bool {
        guard let primeiro = nome.utf8.first, (97...122).contains(primeiro) else { return false }
        return nome.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
        }
    }
}
