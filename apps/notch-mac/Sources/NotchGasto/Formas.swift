import SwiftUI
import AppKit

/// Silhueta do notch: topo reto colado na borda da tela, "orelhas" côncavas circulares nos cantos
/// de cima (igual à geometria do MacBook Pro) e cantos de baixo arredondados.
struct FormaNotch: Shape {
    var raioBaixo: CGFloat
    var orelha: CGFloat
    var raioTopo: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(raioBaixo, AnimatablePair(orelha, raioTopo)) }
        set { raioBaixo = newValue.first; orelha = newValue.second.first; raioTopo = newValue.second.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let e = min(orelha, r.height / 2)
        let left = r.minX + e, right = r.maxX - e
        let rb = min(raioBaixo, (right - left) / 2, r.height / 2)
        let rt = min(raioTopo, (right - left) / 2, r.height / 2)
        if e > 0 {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addArc(center: CGPoint(x: r.minX, y: r.minY + e), radius: e,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        } else {
            p.move(to: CGPoint(x: left, y: r.minY + rt))
            p.addQuadCurve(to: CGPoint(x: left + rt, y: r.minY), control: CGPoint(x: left, y: r.minY))
            p.addLine(to: CGPoint(x: right - rt, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: right, y: r.minY + rt), control: CGPoint(x: right, y: r.minY))
            p.addLine(to: CGPoint(x: right, y: r.maxY - rb))
            p.addArc(center: CGPoint(x: right - rb, y: r.maxY - rb), radius: rb,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: left + rb, y: r.maxY))
            p.addArc(center: CGPoint(x: left + rb, y: r.maxY - rb), radius: rb,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
            return p
        }
        p.addLine(to: CGPoint(x: left, y: r.maxY - rb))
        p.addArc(center: CGPoint(x: left + rb, y: r.maxY - rb), radius: rb,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: right - rb, y: r.maxY))
        p.addArc(center: CGPoint(x: right - rb, y: r.maxY - rb), radius: rb,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: right, y: r.minY + e))
        p.addArc(center: CGPoint(x: r.maxX, y: r.minY + e), radius: e,
                 startAngle: .degrees(180), endAngle: .degrees(-90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Blur por trás da janela (o `backdrop-filter` do painel).
struct FundoBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
