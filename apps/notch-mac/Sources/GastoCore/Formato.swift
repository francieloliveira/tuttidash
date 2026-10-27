import Foundation

/// Formatação pt-BR sem depender do locale do sistema.
public enum Formato {
    /// 1234.5 -> "1.234,50"
    public static func valor(_ v: Double) -> String {
        let centavos = Int((abs(v) * 100).rounded())
        let inteiro = centavos / 100
        let frac = centavos % 100
        var grupos: [String] = []
        var n = inteiro
        repeat {
            let g = n % 1000
            n /= 1000
            grupos.insert(n > 0 ? String(format: "%03d", g) : String(g), at: 0)
        } while n > 0
        return (v < 0 && centavos > 0 ? "-" : "") + grupos.joined(separator: ".") + String(format: ",%02d", frac)
    }

    /// "US$ 24,05"
    public static func usd(_ v: Double) -> String { "US$ " + valor(v) }

    /// "R$ 24,05"
    public static func brl(_ v: Double) -> String { "R$ " + valor(v) }

    /// Duração compacta: "7 min", "1h42".
    public static func duracao(ms: Int) -> String {
        let m = ms / 60000
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h" + String(format: "%02d", m % 60)
    }

    /// Duração falada do painel: "8 s", "4 min", "3 min 54 s", "1 h 12 min".
    public static func relogio(_ segundos: Int) -> String {
        let s = max(0, segundos)
        if s < 60 { return "\(s) s" }
        let minutos = s / 60
        let resto = s % 60
        if minutos < 60 {
            return resto == 0 ? "\(minutos) min" : "\(minutos) min \(resto) s"
        }
        let horas = minutos / 60
        let minResto = minutos % 60
        return minResto == 0 ? "\(horas) h" : "\(horas) h \(minResto) min"
    }

    /// "agora", "há 12 min", "há 2h05".
    public static func ha(_ data: Date, agora: Date) -> String {
        let s = Int(agora.timeIntervalSince(data))
        if s < 60 { return "agora" }
        return "há " + duracao(ms: s * 1000)
    }

    public static func plural(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) " + (n == 1 ? singular : plural)
    }

    public static let diasSemana = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]

    /// "em 48 min", "em 2h05", "em 3 d". Já passou vira "agora".
    public static func faltam(_ data: Date, agora: Date) -> String {
        let s = Int(data.timeIntervalSince(agora))
        if s <= 0 { return "agora" }
        if s < 3600 { return "em \(max(s / 60, 1)) min" }
        if s < 86400 { return "em " + duracao(ms: s * 1000) }
        return "em \(s / 86400) d"
    }

    /// Horário do reset no relógio local: "19:40" se for hoje, "ter 03:00" em outro dia.
    public static func quando(_ data: Date, agora: Date, calendario: Calendar = Datas.calendarioISO) -> String {
        let c = calendario.dateComponents([.hour, .minute, .weekday], from: data)
        let hora = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendario.isDate(data, inSameDayAs: agora) { return hora }
        return diasSemana[((c.weekday ?? 1) - 1) % 7] + " " + hora
    }

    /// "33%" (sem casas; 0,4% não vira 0%).
    public static func pct(_ v: Double) -> String {
        if v > 0 && v < 1 { return "<1%" }
        return "\(Int(v.rounded()))%"
    }
}
