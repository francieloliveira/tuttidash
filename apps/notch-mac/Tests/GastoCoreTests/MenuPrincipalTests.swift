import XCTest
@testable import GastoCore

/// O app sobe sem storyboard, então o macOS não cria o menu Editar.
/// Estes atalhos são o contrato que o menu principal tem de instalar.
final class MenuPrincipalTests: XCTestCase {
    func testEditarTemOsAtalhosDeTexto() {
        let editar = submenu("Editar")
        XCTAssertEqual(atalho(editar, .desfazer), AtalhoMenu(tecla: "z", modificadores: .command))
        XCTAssertEqual(atalho(editar, .refazer), AtalhoMenu(tecla: "z", modificadores: [.command, .shift]))
        XCTAssertEqual(atalho(editar, .recortar), AtalhoMenu(tecla: "x", modificadores: .command))
        XCTAssertEqual(atalho(editar, .copiar), AtalhoMenu(tecla: "c", modificadores: .command))
        XCTAssertEqual(atalho(editar, .colar), AtalhoMenu(tecla: "v", modificadores: .command))
        XCTAssertEqual(atalho(editar, .colarEstilo), AtalhoMenu(tecla: "v", modificadores: [.command, .option, .shift]))
        XCTAssertEqual(atalho(editar, .selecionarTudo), AtalhoMenu(tecla: "a", modificadores: .command))
    }

    func testVisualizarTemTamanhoDaFonte() {
        let ver = submenu("Visualizar")
        XCTAssertEqual(atalho(ver, .aumentarFonte), AtalhoMenu(tecla: "+", modificadores: .command))
        XCTAssertEqual(atalho(ver, .diminuirFonte), AtalhoMenu(tecla: "-", modificadores: .command))
        XCTAssertEqual(atalho(ver, .fontePadrao), AtalhoMenu(tecla: "0", modificadores: .command))
        let igual = ver.itens.first { $0.acao == .aumentarFonte && $0.oculto }
        XCTAssertEqual(igual?.atalho, AtalhoMenu(tecla: "=", modificadores: .command))
    }

    func testJanelaArquivoEApp() {
        XCTAssertEqual(atalho(submenu("Arquivo"), .fecharJanela), AtalhoMenu(tecla: "w", modificadores: .command))
        XCTAssertEqual(atalho(submenu("Arquivo"), .abrirPainel), AtalhoMenu(tecla: "p", modificadores: .command))
        XCTAssertEqual(atalho(submenu("Arquivo"), .atualizar), AtalhoMenu(tecla: "r", modificadores: .command))
        XCTAssertEqual(atalho(submenu("Arquivo"), .buscar), AtalhoMenu(tecla: "f", modificadores: .command))
        XCTAssertEqual(atalho(submenu("TuttiDash"), .ajustes), AtalhoMenu(tecla: ",", modificadores: .command))
        XCTAssertEqual(atalho(submenu("TuttiDash"), .sair), AtalhoMenu(tecla: "q", modificadores: .command))
        XCTAssertEqual(atalho(submenu("TuttiDash"), .ocultar), AtalhoMenu(tecla: "h", modificadores: .command))
        XCTAssertEqual(atalho(submenu("TuttiDash"), .ocultarOutros), AtalhoMenu(tecla: "h", modificadores: [.command, .option]))
        XCTAssertEqual(atalho(submenu("Janela"), .minimizar), AtalhoMenu(tecla: "m", modificadores: .command))
        XCTAssertEqual(atalho(submenu("Visualizar"), .telaCheia), AtalhoMenu(tecla: "f", modificadores: [.command, .control]))
    }

    func testAtalhoVisivelNaoSeRepete() {
        var vistos: [AtalhoMenu] = []
        for item in CatalogoMenu.submenus.flatMap(\.itens) where !item.oculto {
            guard let atalho = item.atalho else { continue }
            XCTAssertFalse(vistos.contains(atalho), "atalho repetido: \(atalho.tecla)")
            vistos.append(atalho)
        }
    }

    private func submenu(_ titulo: String) -> SubmenuMenu {
        guard let menu = CatalogoMenu.submenus.first(where: { $0.titulo == titulo }) else {
            XCTFail("falta o menu \(titulo)")
            return SubmenuMenu(titulo: titulo, itens: [])
        }
        return menu
    }

    private func atalho(_ menu: SubmenuMenu, _ acao: AcaoMenu) -> AtalhoMenu? {
        menu.itens.first { $0.acao == acao && !$0.oculto }?.atalho
    }
}

final class EscalaTextoTests: XCTestCase {
    func testParteDoPadrao() {
        XCTAssertEqual(EscalaTexto.padrao, 1)
        XCTAssertEqual(EscalaTexto.aumentar(EscalaTexto.padrao), 1.15)
        XCTAssertEqual(EscalaTexto.diminuir(EscalaTexto.padrao), 0.85)
    }

    func testParaNosExtremos() {
        XCTAssertEqual(EscalaTexto.aumentar(EscalaTexto.maximo), EscalaTexto.maximo)
        XCTAssertFalse(EscalaTexto.podeAumentar(EscalaTexto.maximo))
        XCTAssertEqual(EscalaTexto.diminuir(EscalaTexto.minimo), EscalaTexto.minimo)
        XCTAssertFalse(EscalaTexto.podeDiminuir(EscalaTexto.minimo))
    }

    func testValorSoltoCaiNoGrauMaisProximo() {
        XCTAssertEqual(EscalaTexto.normalizar(1.2), 1.15)
        XCTAssertEqual(EscalaTexto.normalizar(99), EscalaTexto.maximo)
    }

    func testTamanhoMultiplicaABase() {
        XCTAssertEqual(EscalaTexto.tamanho(13, fator: 2), 26)
        XCTAssertEqual(EscalaTexto.tamanho(13, fator: EscalaTexto.padrao), 13)
    }
}
