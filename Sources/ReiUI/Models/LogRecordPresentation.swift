import Foundation
import ReiLogging

extension AppLogRecord {
    var levelToken: String {
        level.rawValue
    }

    var categoryToken: String {
        category.rawValue
    }

    var categoryDisplayLabel: String {
        switch categoryToken {
        case "lifecycle": return "Lifecycle"
        case "persistence": return "Persistence"
        case "application": return "Application"
        case "connection": return "Connection"
        default: return humanizedIdentifier(categoryToken)
        }
    }

    var levelDisplayLabel: String {
        switch levelToken {
        case "trace": return "Trace"
        case "debug": return "Debug"
        case "info", "information": return "Info"
        case "notice": return "Notice"
        case "warning", "warn": return "Warning"
        case "error": return "Error"
        case "critical", "fault": return "Critical"
        default: return humanizedIdentifier(levelToken)
        }
    }

    var levelSortOrder: Int {
        switch levelToken {
        case "trace": return 0
        case "debug": return 1
        case "info", "information": return 2
        case "notice": return 3
        case "warning", "warn": return 4
        case "error": return 5
        case "critical", "fault": return 6
        default: return 7
        }
    }

    var searchText: String {
        [
            event,
            renderedMessage,
            levelToken,
            levelDisplayLabel,
            categoryToken,
            categoryDisplayLabel,
            sessionID.uuidString,
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    var consoleLine: String {
        let timestampText = timestamp.formatted(date: .numeric, time: .standard)
        return
            "\(timestampText) [\(levelDisplayLabel)] [\(categoryDisplayLabel)] \(event) — \(renderedMessage)"
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return consoleLine }
        return String(decoding: data, as: UTF8.self)
    }
}

private func humanizedIdentifier(_ rawValue: String) -> String {
    let separators = CharacterSet(charactersIn: "._-/")
    let separated = rawValue.unicodeScalars.map { scalar -> String in
        separators.contains(scalar) ? " " : String(scalar)
    }
    let normalized = separated.joined()

    var result = ""
    for character in normalized {
        if character.isUppercase, result.last?.isWhitespace == false {
            result.append(" ")
        }
        result.append(character)
    }
    return result.split(whereSeparator: \.isWhitespace)
        .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
        .joined(separator: " ")
}
