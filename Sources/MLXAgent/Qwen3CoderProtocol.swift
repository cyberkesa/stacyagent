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
    static func analyze(_ text: String) -> Qwen3CoderParseResult {
        let hasOpen =
            text.contains("<tool_call>") ||
            text.contains("<function=")

        guard hasOpen else {
            if let json = parseJSONInvocation(text) {
                return .complete([json])
            }
            return .none
        }

        // Parse complete function blocks FIRST. Qwen/MLX may end generation after
        // a semantically complete function call without emitting the outer
        // </tool_call> wrapper. Rejecting that valid inner call caused repeated
        // "incomplete tool-call" passes in v0.21.2.
        let completeFunctions = parseCompleteFunctions(text)
        if !completeFunctions.isEmpty {
            return .complete(completeFunctions)
        }

        // A second safe recovery path: function closing markup may be missing,
        // while every parameter is already completely closed. In that case the
        // invocation is structurally recoverable and ToolRegistry still performs
        // normal schema validation before execution.
        if let recovered = recoverClosedParametersFunction(text) {
            return .complete([recovered])
        }

        if let json = parseJSONInvocation(text) {
            return .complete([json])
        }

        // Never execute genuinely truncated parameter content.
        return .incomplete(String(text.suffix(2_000)))
    }

    private static func parseCompleteFunctions(
        _ text: String
    ) -> [Qwen3CoderInvocation] {
        var invocations: [Qwen3CoderInvocation] = []
        var cursor = text.startIndex

        while let functionOpen = text.range(
                  of: "<function=",
                  range: cursor..<text.endIndex
              ),
              let nameEnd = text[
                  functionOpen.upperBound...
              ].firstIndex(of: ">"),
              let functionClose = text.range(
                  of: "</function>",
                  range: nameEnd..<text.endIndex
              ) {

            let name = text[
                functionOpen.upperBound..<nameEnd
            ].trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            let bodyStart = text.index(after: nameEnd)
            let body = String(
                text[
                    bodyStart..<functionClose.lowerBound
                ]
            )

            var args = parseXMLParameters(body)

            if args.isEmpty,
               let object = parseJSONObject(body) {
                args = stringArguments(object)
            }

            if !name.isEmpty {
                invocations.append(
                    .init(
                        name: name,
                        arguments: args
                    )
                )
            }

            cursor = functionClose.upperBound
        }

        return invocations
    }

    private static func recoverClosedParametersFunction(
        _ text: String
    ) -> Qwen3CoderInvocation? {
        guard let functionOpen = text.range(
                  of: "<function="
              ),
              let nameEnd = text[
                  functionOpen.upperBound...
              ].firstIndex(of: ">") else {
            return nil
        }

        let name = text[
            functionOpen.upperBound..<nameEnd
        ].trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !name.isEmpty else {
            return nil
        }

        let bodyStart = text.index(after: nameEnd)
        var bodyEnd = text.endIndex

        if let toolClose = text.range(
            of: "</tool_call>",
            range: bodyStart..<text.endIndex
        ) {
            bodyEnd = toolClose.lowerBound
        }

        let body = String(text[bodyStart..<bodyEnd])

        let normalizedBody = body.lowercased()
        let openCount =
            normalizedBody.components(
                separatedBy: "<parameter="
            ).count - 1

        let alternateOpenCount =
            normalizedBody.components(
                separatedBy: "<parameter name=\""
            ).count - 1

        let closeCount =
            normalizedBody.components(
                separatedBy: "</parameter>"
            ).count - 1

        let expectedOpenCount =
            max(openCount, alternateOpenCount)

        guard expectedOpenCount > 0,
              expectedOpenCount == closeCount else {
            return nil
        }

        let args = parseXMLParameters(body)
        guard !args.isEmpty else {
            return nil
        }

        return .init(
            name: name,
            arguments: args
        )
    }

    static func removingToolMarkup(from text: String) -> String {
        var output = text
        while let start = output.range(of: "<tool_call>"),
              let end = output.range(of: "</tool_call>", range: start.upperBound..<output.endIndex) {
            output.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseXMLParameters(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = body.startIndex

        while let start = body.range(
                  of: "<parameter=",
                  options: [.caseInsensitive],
                  range: cursor..<body.endIndex
              ),
              let keyEnd = body[start.upperBound...].firstIndex(of: ">") {
            let key = body[start.upperBound..<keyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = body.index(after: keyEnd)
            guard let close = body.range(
                of: "</parameter>",
                options: [.caseInsensitive],
                range: valueStart..<body.endIndex
            ) else {
                break
            }
            var value = String(body[valueStart..<close.lowerBound])
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }
            result[key] = value
            cursor = close.upperBound
        }

        // Alternate XML spelling: <parameter name="path">...</parameter>
        if result.isEmpty {
            cursor = body.startIndex
            while let start = body.range(
                      of: "<parameter name=\"",
                      options: [.caseInsensitive],
                      range: cursor..<body.endIndex
                  ),
                  let quoteEnd = body[start.upperBound...].firstIndex(of: "\""),
                  let tagEnd = body[quoteEnd...].firstIndex(of: ">") {
                let key = String(body[start.upperBound..<quoteEnd])
                let valueStart = body.index(after: tagEnd)
                guard let close = body.range(
                    of: "</parameter>",
                    options: [.caseInsensitive],
                    range: valueStart..<body.endIndex
                ) else { break }
                result[key] = String(body[valueStart..<close.lowerBound])
                    .trimmingCharacters(in: .newlines)
                cursor = close.upperBound
            }
        }

        return result
    }

    private static func parseJSONInvocation(_ text: String) -> Qwen3CoderInvocation? {
        guard let object = parseJSONObject(text) else { return nil }

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

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open <= close else { return nil }
        let json = String(text[open...close])
        guard let data = json.data(using: .utf8) else { return nil }
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
}
