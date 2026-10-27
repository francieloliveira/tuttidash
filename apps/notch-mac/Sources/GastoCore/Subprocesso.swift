import Foundation

/// Roda um comando curto e espera sem girar o run loop (FRA-579).
///
/// `Process.waitUntilExit()` processa eventos enquanto espera. Na thread da interface isso deixa
/// o SwiftUI começar um redesenho dentro de outro, e o app aborta (`AG::Graph::value_set`).
/// Aqui a espera é por semáforo: a thread fica parada, sem reentrar em nada.
public enum Subprocesso {
    public struct Resultado: Sendable {
        public let codigo: Int32
        public let saida: Data
        public var texto: String { String(data: saida, encoding: .utf8) ?? "" }
    }

    public static func rodar(_ executavel: String, _ argumentos: [String], entrada: String? = nil,
                             ambiente: [String: String]? = nil) -> Resultado {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executavel)
        p.arguments = argumentos
        if let ambiente { p.environment = ambiente }
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        let dentro = entrada.map { _ in Pipe() }
        p.standardInput = dentro ?? FileHandle.nullDevice
        let fim = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in fim.signal() }
        do { try p.run() } catch { return Resultado(codigo: -1, saida: Data()) }
        if let entrada, let dentro {
            dentro.fileHandleForWriting.write(Data(entrada.utf8))
            try? dentro.fileHandleForWriting.close()
        }
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        fim.wait()
        return Resultado(codigo: p.terminationStatus, saida: dados)
    }
}
