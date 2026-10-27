import Foundation

/// Datas "ingênuas" no relógio local, como a ferramenta Python (sem fuso no nome do log).
public enum Datas {
    public static var calendarioISO: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone.current
        c.locale = Locale(identifier: "pt_BR")
        return c
    }

    /// `2026-W41` para o dia informado (semana ISO, segunda a domingo).
    public static func rotuloSemana(_ data: Date, calendario: Calendar = calendarioISO) -> String {
        let c = calendario.dateComponents([.yearForWeekOfYear, .weekOfYear], from: data)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    public static func numeroSemana(_ data: Date, calendario: Calendar = calendarioISO) -> Int {
        calendario.component(.weekOfYear, from: data)
    }

    /// `AAAA-MM-DD` no relógio local.
    public static func diaISO(_ data: Date, calendario: Calendar = calendarioISO) -> String {
        let c = calendario.dateComponents([.year, .month, .day], from: data)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Lê `AAAA-MM-DDTHH:MM:SS` ou `AAAA-MM-DD HH:MM:SS` (heartbeat/started_at) no relógio local.
    public static func lerLocal(_ texto: String, calendario: Calendar = calendarioISO) -> Date? {
        let s = texto.trimmingCharacters(in: .whitespaces)
        let partes = s.split(whereSeparator: { $0 == "T" || $0 == " " })
        guard let dataParte = partes.first else { return nil }
        let ymd = dataParte.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return nil }
        var comp = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: 0, minute: 0, second: 0)
        if partes.count > 1 {
            let hms = partes[1].split(separator: ":").map { String($0) }
            guard hms.count >= 2, let h = Int(hms[0]), let m = Int(hms[1]) else { return nil }
            comp.hour = h; comp.minute = m
            if hms.count > 2 { comp.second = Int(Double(hms[2].prefix(9)) ?? 0) }
        }
        guard let d = calendario.date(from: comp) else { return nil }
        // recusa datas impossíveis (ex.: 2026-13-40): o Calendar "normaliza" sem reclamar
        let volta = calendario.dateComponents([.year, .month, .day], from: d)
        guard volta.year == ymd[0], volta.month == ymd[1], volta.day == ymd[2] else { return nil }
        return d
    }

    static var calendarioUTC: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// Lê ISO 8601 **com fuso**, como vem dos endpoints de uso:
    /// `2026-04-11T07:00:00.528743+00:00`, `2026-10-06T04:06:57.612354Z`, `...-0300`.
    /// A fração de segundo é descartada. Sem fuso retorna nil (não assume o do Mac).
    public static func lerISO8601(_ texto: String) -> Date? {
        let s = texto.trimmingCharacters(in: .whitespaces)
        guard let corte = s.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else { return nil }
        let ymd = s[s.startIndex..<corte].split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return nil }

        var hora = String(s[s.index(after: corte)...])
        var fusoSeg = 0
        if hora.hasSuffix("Z") || hora.hasSuffix("z") {
            hora.removeLast()
        } else if let i = hora.lastIndex(where: { $0 == "+" || $0 == "-" }), i > hora.startIndex {
            let sinal = hora[i] == "-" ? -1 : 1
            let fuso = String(hora[hora.index(after: i)...])
            hora = String(hora[hora.startIndex..<i])
            var h = 0, m = 0
            let partes = fuso.split(separator: ":").map(String.init)
            if partes.count == 2, let a = Int(partes[0]), let b = Int(partes[1]) {
                h = a; m = b
            } else if fuso.count == 4, let a = Int(fuso.prefix(2)), let b = Int(fuso.suffix(2)) {
                h = a; m = b
            } else if fuso.count == 2, let a = Int(fuso) {
                h = a
            } else {
                return nil
            }
            fusoSeg = sinal * (h * 3600 + m * 60)
        } else {
            return nil
        }

        let hms = hora.split(separator: ":").map(String.init)
        guard hms.count >= 2, let h = Int(hms[0]), let m = Int(hms[1]) else { return nil }
        let seg = hms.count > 2 ? Int(Double(hms[2]) ?? 0) : 0
        let cal = calendarioUTC
        let comp = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: h, minute: m, second: seg)
        guard let d = cal.date(from: comp) else { return nil }
        let volta = cal.dateComponents([.year, .month, .day], from: d)
        guard volta.year == ymd[0], volta.month == ymd[1], volta.day == ymd[2] else { return nil }
        return d.addingTimeInterval(-Double(fusoSeg))
    }
}
