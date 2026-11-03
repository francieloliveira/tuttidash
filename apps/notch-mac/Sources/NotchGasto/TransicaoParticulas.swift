import AppKit
import SwiftUI

// Transição de página em partículas: os pixels da tela que sai viram quadradinhos que voam e
// se juntam na tela que entra. As duas telas são fotografadas antes da troca; o painel vivo
// já fica embaixo, coberto por esta camada, e aparece quando a animação termina.
//
// A ideia vem do canvas «starfallParticleArt» do site da SpaceX: partículas brancas que saem
// de uma nuvem de pó e montam a ilustração. Aqui a nuvem é a própria tela, colorida.

/// As duas fotos de uma troca de página.
struct TransicaoPainel: Identifiable {
    let id = UUID()
    let origem: NSImage
    let destino: NSImage
    let tamanho: CGSize
}

/// Camada que cobre a área do painel durante a troca de página.
struct TransicaoParticulas: View {
    let origem: NSImage
    let destino: NSImage
    let tamanho: CGSize
    var duracao: Double = 0.72
    var aoTerminar: () -> Void

    @State private var inicio = Date()
    private let motor: MotorParticulas

    init(origem: NSImage, destino: NSImage, tamanho: CGSize,
         duracao: Double = 0.72, aoTerminar: @escaping () -> Void) {
        self.origem = origem
        self.destino = destino
        self.tamanho = tamanho
        self.duracao = duracao
        self.aoTerminar = aoTerminar
        self.motor = MotorParticulas(origem: origem, destino: destino, tamanho: tamanho)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { contexto in
            Canvas { grafico, area in
                desenhar(grafico, area: area, agora: contexto.date)
            }
        }
        .frame(width: tamanho.width, height: tamanho.height)
        .background(PV.fundo)
        .clipped()
        .allowsHitTesting(true)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(nanoseconds: UInt64((duracao + 0.02) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            aoTerminar()
        }
    }

    private func desenhar(_ grafico: GraphicsContext, area: CGSize, agora: Date) {
        guard area.width > 1, area.height > 1 else { return }
        let passado = agora.timeIntervalSince(inicio)
        let t = min(1, max(0, passado / duracao))

        // Fundo opaco: sem ele, a página nova apareceria nos vãos entre as partículas.
        grafico.fill(Path(CGRect(origin: .zero, size: area)), with: .color(PV.fundo))

        // Agrupa por cor quantizada (4 bits por canal) para trocar milhares de `fill` por
        // algumas centenas — é o que mantém a animação a 60 fps.
        var caminhos: [UInt32: Path] = [:]
        caminhos.reserveCapacity(512)

        let largura = area.width
        let altura = area.height
        for p in motor.particulas {
            let resto = max(0.0001, 1 - p.atraso)
            let u = suave(min(1, max(0, (t - p.atraso) / resto)))
            let onda = sin(Double.pi * u)
            let x = (p.x0 + (p.x1 - p.x0) * u + p.curvaX * CGFloat(onda)) * largura
            let y = (p.y0 + (p.y1 - p.y0) * u + p.curvaY * CGFloat(onda)) * altura
            // Cresce um pouco ao chegar, como se a partícula "pousasse" na tela nova.
            let lado = p.lado * largura * (0.62 + 0.38 * u)

            let r = p.r0 + (p.r1 - p.r0) * u
            let g = p.g0 + (p.g1 - p.g0) * u
            let b = p.b0 + (p.b1 - p.b0) * u
            let chave = (UInt32((r * 15).rounded()) << 8)
                | (UInt32((g * 15).rounded()) << 4)
                | UInt32((b * 15).rounded())

            var caminho = caminhos[chave] ?? Path()
            caminho.addRect(CGRect(x: x - lado / 2, y: y - lado / 2, width: lado, height: lado))
            caminhos[chave] = caminho
        }

        for (chave, caminho) in caminhos {
            let r = CGFloat((chave >> 8) & 0xF) / 15
            let g = CGFloat((chave >> 4) & 0xF) / 15
            let b = CGFloat(chave & 0xF) / 15
            grafico.fill(caminho, with: .color(Color(.sRGB, red: r, green: g, blue: b, opacity: 1)))
        }
    }

    private func suave(_ x: Double) -> CGFloat {
        let v = CGFloat(x)
        return v * v * (3 - 2 * v)
    }
}

// MARK: - Partículas

/// A malha e o trajeto de cada partícula, calculados uma vez por transição.
private final class MotorParticulas {
    struct Particula {
        var x0, y0, x1, y1: CGFloat
        var curvaX, curvaY: CGFloat
        var lado: CGFloat
        var atraso: Double
        var r0, g0, b0, r1, g1, b1: CGFloat
    }

    let particulas: [Particula]

    init(origem: NSImage, destino: NSImage, tamanho: CGSize) {
        // Malha fina: as partículas são bem pequenas (pontos), não blocos.
        let colunas = 170
        // Lado do ponto, em fração da célula da malha. 0,5 era metade da célula; 0,3 deixa os
        // pontos ~40% menores, com mais ar entre eles (pedido do dono, 02/11).
        let tamanhoPonto: CGFloat = 0.3
        let proporcao = tamanho.height / max(tamanho.width, 1)
        let linhas = max(24, min(110, Int((CGFloat(colunas) * proporcao).rounded())))
        let total = colunas * linhas

        let coresOrigem = MotorParticulas.amostrar(origem, colunas: colunas, linhas: linhas)
        let coresDestino = MotorParticulas.amostrar(destino, colunas: colunas, linhas: linhas)

        // Cada linha desliza para um lado por algumas colunas (com volta no fim da linha):
        // é uma permutação — no fim, cada célula da tela nova é coberta exatamente uma vez.
        let deslocamentoMaximo = max(2, colunas / 10)
        var resultado: [Particula] = []
        resultado.reserveCapacity(total)

        for linha in 0..<linhas {
            let deslocamento = Int.random(in: -deslocamentoMaximo...deslocamentoMaximo)
            for coluna in 0..<colunas {
                let indiceOrigem = linha * colunas + coluna
                let colunaDestino = (coluna + deslocamento + colunas) % colunas
                let indiceDestino = linha * colunas + colunaDestino

                let corOrigem = coresOrigem[indiceOrigem]
                let corDestino = coresDestino[indiceDestino]

                // Sorteia um arco pequeno, perpendicular ao caminho, para não ser um trilho reto.
                let angulo = Double.random(in: 0..<(2 * .pi))
                let forca = CGFloat.random(in: 0.004...0.022)
                let atraso = min(0.34, 0.05 + 0.20 * Double(colunaDestino) / Double(colunas)
                    + Double.random(in: 0...0.10))

                resultado.append(Particula(
                    x0: (CGFloat(coluna) + 0.5) / CGFloat(colunas),
                    y0: (CGFloat(linha) + 0.5) / CGFloat(linhas),
                    x1: (CGFloat(colunaDestino) + 0.5) / CGFloat(colunas),
                    y1: (CGFloat(linha) + 0.5) / CGFloat(linhas),
                    curvaX: CGFloat(cos(angulo)) * forca,
                    curvaY: CGFloat(sin(angulo)) * forca,
                    // Fração da célula ocupada pelo ponto: bem pequeno, com ar entre as partículas.
                    lado: tamanhoPonto / CGFloat(colunas),
                    atraso: atraso,
                    r0: corOrigem.r, g0: corOrigem.g, b0: corOrigem.b,
                    r1: corDestino.r, g1: corDestino.g, b1: corDestino.b))
            }
        }
        particulas = resultado
    }

    /// Uma cor por célula da malha, amostrada da imagem (origem no canto superior esquerdo).
    private struct CorRGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
    }

    private static func amostrar(_ imagem: NSImage, colunas: Int, linhas: Int) -> [CorRGB] {
        var cores = [CorRGB](repeating: CorRGB(), count: colunas * linhas)
        guard let tiff = imagem.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return cores
        }
        for linha in 0..<linhas {
            let y = min(rep.pixelsHigh - 1,
                        Int((CGFloat(linha) + 0.5) / CGFloat(linhas) * CGFloat(rep.pixelsHigh)))
            for coluna in 0..<colunas {
                let x = min(rep.pixelsWide - 1,
                            Int((CGFloat(coluna) + 0.5) / CGFloat(colunas) * CGFloat(rep.pixelsWide)))
                guard let cor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                cores[linha * colunas + coluna] = CorRGB(r: cor.redComponent,
                                                         g: cor.greenComponent,
                                                         b: cor.blueComponent)
            }
        }
        return cores
    }
}

// MARK: - Foto da área

/// Referência à vista que cobre a área de conteúdo, para tirar a foto dos pixels reais.
final class AreaPainel {
    weak var vista: NSView?
    var tamanho: CGSize = .zero

    /// Foto exata do que está na tela agora (inclui o cabeçalho e a rolagem).
    static func foto(de area: AreaPainel?) -> NSImage? {
        guard let vista = area?.vista, let janela = vista.window,
              let conteudo = janela.contentView else { return nil }
        let alvo = conteudo.convert(vista.bounds, from: vista).intersection(conteudo.bounds)
        guard alvo.width > 2, alvo.height > 2,
              let rep = conteudo.bitmapImageRepForCachingDisplay(in: alvo) else { return nil }
        conteudo.cacheDisplay(in: alvo, to: rep)
        let imagem = NSImage(size: rep.size)
        imagem.addRepresentation(rep)
        return imagem
    }
}

/// NSView invisível, do tamanho da área de conteúdo, que entrega a vista para a captura.
struct AreaCaptura: NSViewRepresentable {
    let area: AreaPainel

    func makeNSView(context: Context) -> NSView {
        let vista = Vista()
        vista.area = area
        area.vista = vista
        return vista
    }

    func updateNSView(_ vista: NSView, context: Context) {
        area.vista = vista
    }

    private final class Vista: NSView {
        weak var area: AreaPainel?

        override func layout() {
            super.layout()
            area?.tamanho = bounds.size
        }
    }
}
