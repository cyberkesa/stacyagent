import Foundation

enum TelemetryExtractor {
    static func capture<T>(_ value: T, wallSeconds: Double, firstTokenSeconds: Double?) -> ModelPassTelemetry {
        var values: [String:Any] = [:]
        flatten(Mirror(reflecting: value), prefix: "", depth: 0, into: &values)
        return ModelPassTelemetry(
            promptTokens: int(values, ["prompttokencount","prompttokens","promptcount"]),
            outputTokens: int(values, ["generationtokencount","generatedtokencount","outputtokencount","outputtokens","tokencount"]),
            promptTokensPerSecond: double(values, ["prompttokenspersecond","prompttps","promptthroughput"]),
            generationTokensPerSecond: double(values, ["generationtokenspersecond","tokenspersecond","generationtps"]),
            firstTokenSeconds: firstTokenSeconds,
            wallSeconds: wallSeconds
        )
    }
    private static func flatten(_ mirror: Mirror, prefix: String, depth: Int, into out: inout [String:Any]) {
        guard depth < 5 else { return }
        for child in mirror.children {
            let label=(child.label ?? "").lowercased().replacingOccurrences(of:"_",with:"")
            let key=prefix+label; out[key]=child.value
            let nested=Mirror(reflecting: child.value)
            if !nested.children.isEmpty { flatten(nested, prefix: key, depth: depth + 1, into: &out) }
        }
    }
    private static func int(_ v:[String:Any], _ names:[String])->Int? {
        for n in names { for (k,x) in v where k.hasSuffix(n) { if let x=x as? Int{return x}; if let x=x as? Int64{return Int(x)} } }; return nil
    }
    private static func double(_ v:[String:Any], _ names:[String])->Double? {
        for n in names { for (k,x) in v where k.hasSuffix(n) { if let x=x as? Double{return x}; if let x=x as? Float{return Double(x)}; if let x=x as? Int{return Double(x)} } }; return nil
    }
}
