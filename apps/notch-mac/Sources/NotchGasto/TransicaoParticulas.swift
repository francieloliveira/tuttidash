import AppKit
import SwiftUI

// Transição de página em partículas: os pixels da tela que sai viram quadradinhos que voam e
// se juntam na tela que entra. As duas telas são fotografadas antes da troca; o painel vivo
// já fica embaixo, coberto por esta camada, e aparece quando a animação termina.
//
// As partículas nascem na silhueta (conteúdo ≠ fundo) da tela anterior — a borda da forma
// sai primeiro — e voam para formar a silhueta da tela seguinte.

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
    /// Transição curta: o painel não pode parecer “preso” entre páginas.
    var duracao: Double = 0.40
    var aoTerminar: () -> Void

    @State private var inicio = Date()
    private let motor: MotorParticulas

    init(origem: NSImage, destino: NSImage, tamanho: CGSize,
         duracao: Double = 0.40, aoTerminar: @escaping () -> Void) {
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

            // Mistura tarde: no voo mantém a cor da origem; só perto do pouso vira a do destino.
            // Evita “pastel” no meio e alinha o fim com a página real sob a overlay.
            let m = CGFloat(pow(Double(u), 1.85))
            let r = p.r0 + (p.r1 - p.r0) * m
            let g = p.g0 + (p.g1 - p.g0) * m
            let b = p.b0 + (p.b1 - p.b0) * m
            // 5 bits/canal: menos banding nos azuis escuros do painel.
            let chave = (UInt32((r * 31).rounded()) << 10)
                | (UInt32((g * 31).rounded()) << 5)
                | UInt32((b * 31).rounded())

            var caminho = caminhos[chave] ?? Path()
            caminho.addRect(CGRect(x: x - lado / 2, y: y - lado / 2, width: lado, height: lado))
            caminhos[chave] = caminho
        }

        for (chave, caminho) in caminhos {
            let r = CGFloat((chave >> 10) & 0x1F) / 31
            let g = CGFloat((chave >> 5) & 0x1F) / 31
            let b = CGFloat(chave & 0x1F) / 31
            grafico.fill(caminho, with: .color(Color(.sRGB, red: r, green: g, blue: b, opacity: 1)))
        }
    }

    private func suave(_ x: Double) -> CGFloat {
        let v = CGFloat(x)
        // ease-out mais agressivo: a maior parte do voo acontece cedo.
        let ease = 1 - pow(1 - v, 2.4)
        return ease
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

    /// PV.fundo (#040B17) — células próximas disso não formam a silhueta.
    private static let fundoR: CGFloat = 4.0 / 255.0
    private static let fundoG: CGFloat = 11.0 / 255.0
    private static let fundoB: CGFloat = 23.0 / 255.0

    init(origem: NSImage, destino: NSImage, tamanho: CGSize) {
        // Malha fina: as partículas são bem pequenas (pontos), não blocos.
        let colunas = 160
        let tamanhoPonto: CGFloat = 0.32
        let proporcao = tamanho.height / max(tamanho.width, 1)
        let linhas = max(24, min(100, Int((CGFloat(colunas) * proporcao).rounded())))

        let coresOrigem = MotorParticulas.amostrar(origem, colunas: colunas, linhas: linhas)
        let coresDestino = MotorParticulas.amostrar(destino, colunas: colunas, linhas: linhas)

        var mascaraOrigem = [Bool](repeating: false, count: colunas * linhas)
        var mascaraDestino = [Bool](repeating: false, count: colunas * linhas)
        for i in 0..<(colunas * linhas) {
            mascaraOrigem[i] = Self.ehConteudo(coresOrigem[i])
            mascaraDestino[i] = Self.ehConteudo(coresDestino[i])
        }

        // Sem contraste útil (telas quase iguais ao fundo): volta ao grid completo.
        let origemCount = mascaraOrigem.filter { $0 }.count
        let destinoCount = mascaraDestino.filter { $0 }.count
        if origemCount < 40 || destinoCount < 40 {
            for i in 0..<(colunas * linhas) {
                mascaraOrigem[i] = true
                mascaraDestino[i] = true
            }
        }

        var origemConteudo: [Int] = []
        var origemBorda: [Int] = []
        var destinoConteudo: [Int] = []
        origemConteudo.reserveCapacity(max(origemCount, 64))
        destinoConteudo.reserveCapacity(max(destinoCount, 64))

        for linha in 0..<linhas {
            for coluna in 0..<colunas {
                let i = linha * colunas + coluna
                if mascaraDestino[i] { destinoConteudo.append(i) }
                guard mascaraOrigem[i] else { continue }
                origemConteudo.append(i)
                if Self.ehBorda(linha: linha, coluna: coluna, colunas: colunas, linhas: linhas, mascara: mascaraOrigem) {
                    origemBorda.append(i)
                }
            }
        }

        // Fallback extremo: se ainda assim não há destino, usa origem.
        if destinoConteudo.isEmpty { destinoConteudo = origemConteudo }
        if origemConteudo.isEmpty { origemConteudo = destinoConteudo }
        let ancoraBorda = origemBorda.isEmpty ? origemConteudo : origemBorda

        // Mapa célula → destino mais próximo (BFS a partir da silhueta). Assim a forma da
        // tela nova aparece de verdade, em vez de um embaralhamento que parece origem→origem.
        let mapaDestino = Self.mapaMaisProximo(
            destinos: destinoConteudo, colunas: colunas, linhas: linhas)

        var resultado: [Particula] = []
        resultado.reserveCapacity(max(origemConteudo.count, destinoConteudo.count))

        // 1) Cada célula de conteúdo da origem voa para a célula correspondente do destino.
        for indiceOrigem in origemConteudo {
            let linha = indiceOrigem / colunas
            let coluna = indiceOrigem % colunas
            let indiceDestino = mapaDestino[indiceOrigem]
            let corOrigem = coresOrigem[indiceOrigem]
            let corDestino = coresDestino[indiceDestino]
            let naBorda = Self.ehBorda(linha: linha, coluna: coluna, colunas: colunas, linhas: linhas, mascara: mascaraOrigem)

            resultado.append(Self.particula(
                colOrigem: coluna, linOrigem: linha,
                indiceDestino: indiceDestino, colunas: colunas, linhas: linhas,
                tamanhoPonto: tamanhoPonto, naBorda: naBorda,
                corOrigem: corOrigem, corDestino: corDestino))
        }

        // 2) Células só do destino: nascem na borda/forma da tela anterior e pousam no destino.
        var usados = Set<Int>()
        usados.reserveCapacity(resultado.count)
        for p in resultado {
            let c = min(colunas - 1, max(0, Int((p.x1 * CGFloat(colunas)).rounded() - 0.5)))
            let l = min(linhas - 1, max(0, Int((p.y1 * CGFloat(linhas)).rounded() - 0.5)))
            usados.insert(l * colunas + c)
        }
        for indiceDestino in destinoConteudo where !usados.contains(indiceDestino) {
            let ancora = ancoraBorda[abs(indiceDestino) % ancoraBorda.count]
            let linO = ancora / colunas
            let colO = ancora % colunas
            resultado.append(Self.particula(
                colOrigem: colO, linOrigem: linO,
                indiceDestino: indiceDestino, colunas: colunas, linhas: linhas,
                tamanhoPonto: tamanhoPonto, naBorda: true,
                corOrigem: coresOrigem[ancora], corDestino: coresDestino[indiceDestino],
                atrasoExtra: 0.02))
        }

        particulas = resultado
    }

    private static func particula(
        colOrigem: Int, linOrigem: Int,
        indiceDestino: Int, colunas: Int, linhas: Int,
        tamanhoPonto: CGFloat, naBorda: Bool,
        corOrigem: CorRGB, corDestino: CorRGB,
        atrasoExtra: Double = 0
    ) -> Particula {
        let colDestino = indiceDestino % colunas
        let linDestino = indiceDestino / colunas
        let angulo = Double.random(in: 0..<(2 * .pi))
        // Arco um pouco maior na borda: a silhueta “explode” para fora antes de recompor.
        let forca = CGFloat.random(in: naBorda ? 0.012...0.038 : 0.004...0.018)
        // Borda sai primeiro (emerge do contorno); miolo segue em seguida.
        let atrasoBase = naBorda
            ? Double.random(in: 0...0.04)
            : 0.04 + 0.08 * Double(colDestino) / Double(max(colunas, 1)) + Double.random(in: 0...0.04)
        let atraso = min(0.14, atrasoBase + atrasoExtra)

        return Particula(
            x0: (CGFloat(colOrigem) + 0.5) / CGFloat(colunas),
            y0: (CGFloat(linOrigem) + 0.5) / CGFloat(linhas),
            x1: (CGFloat(colDestino) + 0.5) / CGFloat(colunas),
            y1: (CGFloat(linDestino) + 0.5) / CGFloat(linhas),
            curvaX: CGFloat(cos(angulo)) * forca,
            curvaY: CGFloat(sin(angulo)) * forca,
            lado: tamanhoPonto / CGFloat(colunas),
            atraso: atraso,
            r0: corOrigem.r, g0: corOrigem.g, b0: corOrigem.b,
            r1: corDestino.r, g1: corDestino.g, b1: corDestino.b)
    }

    /// Para cada célula da malha, o índice de conteúdo do destino mais próximo.
    private static func mapaMaisProximo(destinos: [Int], colunas: Int, linhas: Int) -> [Int] {
        let n = colunas * linhas
        var mapa = [Int](repeating: destinos.first ?? 0, count: n)
        guard !destinos.isEmpty else { return mapa }
        var dist = [Int](repeating: Int.max, count: n)
        var fila = destinos
        for d in destinos {
            dist[d] = 0
            mapa[d] = d
        }
        var i = 0
        while i < fila.count {
            let atual = fila[i]
            i += 1
            let l = atual / colunas, c = atual % colunas
            let d0 = dist[atual]
            let vizinhos = [
                (l - 1, c), (l + 1, c), (l, c - 1), (l, c + 1)
            ]
            for (yl, xc) in vizinhos {
                guard yl >= 0, yl < linhas, xc >= 0, xc < colunas else { continue }
                let j = yl * colunas + xc
                if dist[j] > d0 + 1 {
                    dist[j] = d0 + 1
                    mapa[j] = mapa[atual]
                    fila.append(j)
                }
            }
        }
        return mapa
    }

    private static func ehConteudo(_ c: CorRGB) -> Bool {
        // Cards (#081426, #0A1628, #06101F) ficam perto do fundo (#040B17). Limiar 0.16
        // tratava quase tudo como vazio — só o Dashboard “passava” por ter acentos claros.
        let d = abs(c.r - fundoR) + abs(c.g - fundoG) + abs(c.b - fundoB)
        return d > 0.045
    }

    private static func ehBorda(linha: Int, coluna: Int, colunas: Int, linhas: Int, mascara: [Bool]) -> Bool {
        guard mascara[linha * colunas + coluna] else { return false }
        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let y = linha + dy, x = coluna + dx
                if y < 0 || y >= linhas || x < 0 || x >= colunas { return true }
                if !mascara[y * colunas + x] { return true }
            }
        }
        return false
    }

    /// Uma cor por célula da malha, amostrada da imagem (origem no canto superior esquerdo).
    private struct CorRGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
    }

    private static func amostrar(_ imagem: NSImage, colunas: Int, linhas: Int) -> [CorRGB] {
        var cores = [CorRGB](repeating: CorRGB(), count: colunas * linhas)
        // colorAt usa (0,0) no topo — alinhado ao Canvas do SwiftUI. Evitar CGContext+flip,
        // que invertia a malha (partículas do cabeçalho nascendo embaixo).
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
