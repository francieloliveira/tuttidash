import Foundation
import CoreFoundation

/// Leitura tolerante de valores vindos de JSONSerialization (mesmas regras do Python:
/// bool não conta como número).
public enum JV {
    public static func ehBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    public static func numero(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !ehBool(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    public static func inteiro(_ v: Any?) -> Int? {
        guard let d = numero(v), abs(d) < 9.0e15 else { return nil }
        return Int(d)   // trunca como int() do Python
    }

    public static func texto(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func verdadeiro(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return !s.isEmpty }
        if v is NSNull || v == nil { return false }
        return true
    }

    public static func objeto(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }
}
