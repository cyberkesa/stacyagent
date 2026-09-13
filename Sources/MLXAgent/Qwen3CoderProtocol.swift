import Foundation

struct Qwen3CoderInvocation: Sendable {
    let name: String
    let arguments: [String: String]
}

enum Qwen3CoderParseResult: Sendable {
    case none
    case complete([Qwen3CoderInvocation])
    case incomplete(String)
}

enum Qwen3CoderProtocol {
    /// Detects a concrete implementation artifact in ordinary prose. This is an
    /// output-shape check, not natural-language intent matching: a CHAT turn that
    /// emits source code while a project is in focus crossed the execution boundary.
    static func containsImplementationArtifact(_ text: String) -> Bool {
        let fencedSource = #"(?s)```[^\n]*\n.+?```"#
        if let regex = try? NSRegularExpression(pattern: fencedSource),
           regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
           ) != nil {
            return true
        }

        let lower = text.lowercased()
        return (lower.contains("<!doctype html") || lower.contains("<html")) &&
            lower.contains("</html>")
    }

    static func analyze(_ text: String) -> Qwen3CoderParseResult {
        var invocations: [Qwen3CoderInvocation] = []

        // 1. Стандартный формат Qwen: <tool_call>{"name": "...", "arguments": {...}}</tool_call>
        let toolCallInvocations = parseToolCallBlocks(text)
        if !toolCallInvocations.isEmpty {
            invocations.append(contentsOf: toolCallInvocations)
        }

        // 2. XML формат: <function=name><parameter=key>value</parameter></function>
        let functionInvocations = parseCompleteFunctions(text)
        if !functionInvocations.isEmpty {
            invocations.append(contentsOf: functionInvocations)
        }

        // 3. Восстановление XML с закрытыми параметрами
        if invocations.isEmpty, let recovered = recoverClosedParametersFunction(text) {
            invocations.append(recovered)
        }

        // 4. Поиск чистых JSON блоков
        if invocations.isEmpty {
            let jsonInvocations = parseAllJSONInvocations(text)
            if !jsonInvocations.isEmpty {
                invocations.append(contentsOf: jsonInvocations)
            }
        }

        if !invocations.isEmpty {
            return .complete(invocations)
        }

        if (text.contains("<tool_call>") && !text.contains("</tool_call>")) ||
           (text.contains("<function=") && !text.contains("</function>")) {
            return .incomplete(String(text.suffix(2_000)))
        }

        return .none
    }

    private static func sanitizeJSONString(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count + 64)
        var inString = false
        var isEscaped = false

        for char in input {
            if isEscaped {
                output.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                output.append(char)
                isEscaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                output.append(char)
                continue
            }
            if inString {
                if char == "\n" { output.append("\\n"); continue }
                if char == "\r" { output.append("\\r"); continue }
                if char == "\t" { output.append("\\t"); continue }
            }
            output.append(char)
        }
        return output
    }

    private static func parseToolCallBlocks(_ text: String) -> [Qwen3CoderInvocation] {
        var results: [Qwen3CoderInvocation] = []
        var cursor = text.startIndex

        while let start = text.range(of: "<tool_call>", range: cursor..<text.endIndex) {
            let searchEnd = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            let block = String(text[start.upperBound..<searchEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let inv = parseSingleJSONInvocation(block) {
                results.append(inv)
            } else {
                let inner = parseAllJSONInvocations(block)
                results.append(contentsOf: inner)
            }

            if searchEnd == text.endIndex { break }
            cursor = text.index(searchEnd, offsetBy: "</tool_call>".count)
        }

        return results
    }

    private static func parseCompleteFunctions(_ text: String) -> [Qwen3CoderInvocation] {
        var invocations: [Qwen3CoderInvocation] = []
        var cursor = text.startIndex

        while let functionOpen = text.range(of: "<function=", range: cursor..<text.endIndex),
              let nameEnd = text[functionOpen.upperBound...].firstIndex(of: ">"),
              let functionClose = text.range(of: "</function>", range: nameEnd..<text.endIndex) {

            let name = text[functionOpen.upperBound..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = text.index(after: nameEnd)
            let body = String(text[bodyStart..<functionClose.lowerBound])

            var args = parseXMLParameters(body)
            if args.isEmpty, let object = parseFirstJSONObject(body) {
                args = stringArguments(object)
            }

            if !name.isEmpty {
                invocations.append(.init(name: name, arguments: args))
            }

            cursor = functionClose.upperBound
        }

        return invocations
    }

    private static func recoverClosedParametersFunction(_ text: String) -> Qwen3CoderInvocation? {
        guard let functionOpen = text.range(of: "<function="),
              let nameEnd = text[functionOpen.upperBound...].firstIndex(of: ">") else {
            return nil
        }

        let name = text[functionOpen.upperBound..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let bodyStart = text.index(after: nameEnd)
        var bodyEnd = text.endIndex
        if let toolClose = text.range(of: "</tool_call>", range: bodyStart..<text.endIndex) {
            bodyEnd = toolClose.lowerBound
        }

        let body = String(text[bodyStart..<bodyEnd])
        let lowerBody = body.lowercased()
        guard lowerBody.components(separatedBy: "<parameter=").count ==
                lowerBody.components(separatedBy: "</parameter>").count else {
            return nil
        }
        let args = parseXMLParameters(body)
        guard !args.isEmpty else { return nil }

        return .init(name: name, arguments: args)
    }

    private static func parseXMLParameters(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = body.startIndex

        while let start = body.range(of: "<parameter=", options: [.caseInsensitive], range: cursor..<body.endIndex),
              let keyEnd = body[start.upperBound...].firstIndex(of: ">") {
            let key = body[start.upperBound..<keyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = body.index(after: keyEnd)
            guard let close = body.range(of: "</parameter>", options: [.caseInsensitive], range: valueStart..<body.endIndex) else {
                break
            }
            var value = String(body[valueStart..<close.lowerBound])
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }
            result[key] = value
            cursor = close.upperBound
        }

        if result.isEmpty {
            cursor = body.startIndex
            while let start = body.range(of: "<parameter name=\"", options: [.caseInsensitive], range: cursor..<body.endIndex),
                  let quoteEnd = body[start.upperBound...].firstIndex(of: "\""),
                  let tagEnd = body[quoteEnd...].firstIndex(of: ">") {
                let key = String(body[start.upperBound..<quoteEnd])
                let valueStart = body.index(after: tagEnd)
                guard let close = body.range(of: "</parameter>", options: [.caseInsensitive], range: valueStart..<body.endIndex) else { break }
                result[key] = String(body[valueStart..<close.lowerBound]).trimmingCharacters(in: .newlines)
                cursor = close.upperBound
            }
        }

        return result
    }

    private static func parseAllJSONInvocations(_ text: String) -> [Qwen3CoderInvocation] {
        var results: [Qwen3CoderInvocation] = []
        var searchRange = text.startIndex..<text.endIndex

        while let open = text[searchRange].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escape = false
            var closeIndex: String.Index? = nil

            for idx in text[open..<text.endIndex].indices {
                let char = text[idx]
                if escape { escape = false; continue }
                if char == "\\" { escape = true; continue }
                if char == "\"" { inString.toggle(); continue }
                if !inString {
                    if char == "{" { depth += 1 }
                    else if char == "}" {
                        depth -= 1
                        if depth == 0 {
                            closeIndex = idx
                            break
                        }
                    }
                }
            }

            guard let close = closeIndex else { break }
            let candidate = String(text[open...close])

            if let inv = parseSingleJSONInvocation(candidate) {
                results.append(inv)
            }

            let nextStart = text.index(after: close)
            if nextStart >= text.endIndex { break }
            searchRange = nextStart..<text.endIndex
        }

        return results
    }

    private static func parseSingleJSONInvocation(_ jsonString: String) -> Qwen3CoderInvocation? {
        let clean = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitizeJSONString(clean)

        guard let data = sanitized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let name = object["name"] as? String {
            let args = object["arguments"] as? [String: Any] ?? object["parameters"] as? [String: Any] ?? [:]
            return .init(name: name, arguments: stringArguments(args))
        }

        if let function = object["function"] as? [String: Any],
           let name = function["name"] as? String {
            let args = function["arguments"] as? [String: Any] ?? [:]
            return .init(name: name, arguments: stringArguments(args))
        }

        return nil
    }

    private static func parseFirstJSONObject(_ text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open <= close else { return nil }
        let json = String(text[open...close])
        let sanitized = sanitizeJSONString(json)
        guard let data = sanitized.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringArguments(_ object: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if JSONSerialization.isValidJSONObject(["v": value]),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let string = String(data: data, encoding: .utf8) {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    static func removingToolMarkup(from text: String) -> String {
        var output = text
        while let start = output.range(of: "<tool_call>"),
              let end = output.range(of: "</tool_call>", range: start.upperBound..<output.endIndex) {
            output.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
