import SwiftUI
import GastoCore

/// Cores e medidas do mockup v1 (mockups/notch-gasto-v1.html).
enum Tema {
    /// Cores por lane, derivadas de `agents.d/` (fonte única, FRA-373/FRA-410).
    /// Lane sem cor no manifesto cai na matiz determinística do nome — nunca cinza
    /// genérico igual para todas.
    static let cores: [String: (Color, Color, Color)] = Dictionary(
        uniqueKeysWithValues: Agentes.todos.map { d in
            (d.nome, (Color(hex: d.corBase), Color(hex: d.corGradiente), Color(hex: d.corClaro)))
        })

    static let ok = Color(hex: 0x32D74B)
    static let warn = Color(hex: 0xFFD23F)
    static let bad = Color(hex: 0xFF453A)

    static let t1 = Color.white.opacity(0.96)
    static let t2 = Color.white.opacity(0.62)
    static let t3 = Color.white.opacity(0.40)
    static let t4 = Color.white.opacity(0.22)
    static let hair = Color.white.opacity(0.08)

    static let larguraPainel: CGFloat = 580
    /// Notch expandido do FRA-412: uma coluna estreita, o painel completo abre à parte.
    static let larguraNotchAberto: CGFloat = 520
    static let raioPainel: CGFloat = 24
    static let raioPilula: CGFloat = 11
    static let orelha: CGFloat = 10

    /// Cor de uma lane desconhecida: matiz determinística do nome (estável entre leituras).
    static func corDesconhecida(lane: String) -> Color {
        var h: UInt32 = 0
        for b in lane.utf8 { h = h &* 31 &+ UInt32(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.65, brightness: 0.95)
    }

    static func cor(lane: String) -> Color {
        cores[lane]?.0 ?? corDesconhecida(lane: lane)
    }

    static func cor2(lane: String) -> Color {
        cores[lane]?.1 ?? corDesconhecida(lane: lane)
    }

    static func corClara(lane: String) -> Color {
        cores[lane]?.2 ?? corDesconhecida(lane: lane)
    }

    static func cor(nivel: NivelTeto) -> Color {
        switch nivel {
        case .semTeto: return Color.white.opacity(0.35)
        case .ok: return ok
        case .perto: return warn
        case .estourado: return bad
        }
    }

    static func cor(nivelUso: NivelUso) -> Color {
        switch nivelUso {
        case .ok: return ok
        case .atencao: return warn
        case .critico: return bad
        }
    }

    /// Gradiente do anel grande (claro -> base), como o `#rg` do mockup.
    static func gradienteAnel(nivel: NivelTeto) -> [Color] {
        switch nivel {
        case .semTeto: return [Color.white.opacity(0.35), Color.white.opacity(0.25)]
        case .ok: return [Color(hex: 0x7CF08C), ok]
        case .perto: return [Color(hex: 0xFFE27A), Color(hex: 0xFFC21A)]
        case .estourado: return [Color(hex: 0xFF8A7A), bad]
        }
    }
}

/// Cores do primeiro protótipo do painel (FRA-412).
enum TemaPainel {
    static let ciano = Color(hex: 0x3DE8FF)
    static let violeta = Color(hex: 0x9B7BFF)
    static let verde = Color(hex: 0x3DFFA8)
    static let vermelho = Color(hex: 0xFF4D6D)
    static let amarelo = Color(hex: 0xFFC857)
    static let texto = Color(hex: 0xE6F0FF)
    static let mudo = Color(hex: 0x7F93B5)
    static let fundo = Color(hex: 0x05070F)
    static let apagado = Color(hex: 0x3A425A)

    /// Cor da lane no painel v1: o campo `corPainel` do manifesto em `agents.d/`.
    /// Lane sem cor no manifesto cai na cor da lane (`Tema.cor`).
    static let cores: [String: Color] = Dictionary(
        uniqueKeysWithValues: Agentes.todos.compactMap { d in
            d.corPainel.isEmpty ? nil : (d.nome, Color(hex: d.corPainel))
        })

    static func cor(_ lane: String) -> Color {
        cores[lane] ?? Tema.cor(lane: lane)
    }

    static func cor(_ geral: EstadoGeral) -> Color {
        switch geral {
        case .tudoOk: return verde
        case .atencao: return amarelo
        case .parado: return vermelho
        }
    }
}

extension View {
    func vidro() -> some View {
        padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Cor vinda do manifesto em `agents.d/` (`"#RRGGBB"`). Hex inválido = branco.
    init(hex texto: String) {
        let limpo = texto.hasPrefix("#") ? String(texto.dropFirst()) : texto
        if limpo.count == 6, let valor = UInt32(limpo, radix: 16) {
            self.init(hex: valor)
        } else {
            self = .white
        }
    }
}

extension Font {
    static func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
