import Foundation

enum ConversationDirectRouter {
    enum Match: Sendable {
        case greeting(String)
        case rememberName(name: String, response: String)
        case recallName
    }

    static func match(_ input: String) -> Match? {
        let trimmed = InputNormalizer.sanitize(input)
        let lower = InputNormalizer.lexical(trimmed)

        let greetings: Set<String> = [
            "привет", "привет!", "здравствуй", "здравствуйте",
            "добрый день", "добрый вечер", "доброе утро",
            "hi", "hello", "hey"
        ]

        if greetings.contains(lower) {
            if lower == "hi" || lower == "hello" || lower == "hey" {
                return .greeting("Hello!")
            }
            return .greeting("Привет!")
        }

        let acknowledgements: [String: String] = [
            "супер": "Супер.",
            "отлично": "Отлично.",
            "класс": "Класс.",
            "ок": "Ок.",
            "окей": "Ок.",
            "спасибо": "Пожалуйста.",
            "thanks": "You're welcome.",
            "great": "Great."
        ]

        if let response = acknowledgements[lower] {
            return .greeting(response)
        }

        let recallQueries = [
            "как меня зовут", "ты помнишь как меня зовут",
            "помнишь как меня зовут", "what is my name",
            "what's my name", "do you remember my name"
        ]

        if recallQueries.contains(where: lower.contains) {
            return .recallName
        }

        if let name = extractRussianName(trimmed) {
            return .rememberName(
                name: name,
                response: "Хорошо, \(name). Запомню это в рамках текущего диалога."
            )
        }

        if let name = extractEnglishName(trimmed) {
            return .rememberName(
                name: name,
                response: "Got it, \(name). I'll remember that for this conversation."
            )
        }

        return nil
    }

    private static func extractRussianName(_ text: String) -> String? {
        let patterns = [
            #"(?i)^\s*меня\s+зовут\s+([A-Za-zА-Яа-яЁё'-]{1,40})"#,
            #"(?i)^\s*мое\s+имя\s+([A-Za-zА-Яа-яЁё'-]{1,40})"#,
            #"(?i)^\s*моё\s+имя\s+([A-Za-zА-Яа-яЁё'-]{1,40})"#
        ]
        return firstCapture(text, patterns: patterns)
    }

    private static func extractEnglishName(_ text: String) -> String? {
        firstCapture(
            text,
            patterns: [
                #"(?i)^\s*my\s+name\s+is\s+([A-Za-z'-]{1,40})"#,
                #"(?i)^\s*i(?:'m| am)\s+([A-Za-z'-]{1,40})"#
            ]
        )
    }

    private static func firstCapture(_ text: String, patterns: [String]) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2 else {
                continue
            }

            let value = ns.substring(with: match.range(at: 1))
            return value.prefix(1).uppercased() + value.dropFirst()
        }

        return nil
    }
}
