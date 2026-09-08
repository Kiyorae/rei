import Foundation
import ReiCore

/// OneBot V11's string representation. Entity decoding is performed exactly once
/// after separating CQ syntax, so escaped text can never become a message segment.
enum OneBotCQCode {
    static func decode(_ string: String) -> [JSONValue] {
        var segments: [JSONValue] = []
        var cursor = string.startIndex
        var textStart = cursor
        while cursor < string.endIndex {
            guard string[cursor...].hasPrefix("[CQ:"),
                let end = string[cursor...].firstIndex(of: "]")
            else {
                cursor = string.index(after: cursor)
                continue
            }
            let bodyStart = string.index(cursor, offsetBy: 4)
            let parts = string[bodyStart..<end].split(separator: ",", omittingEmptySubsequences: false)
            guard let type = parts.first, !type.isEmpty,
                !type.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "=" })
            else {
                cursor = string.index(after: cursor)
                continue
            }
            var data: [String: JSONValue] = [:]
            var valid = true
            for part in parts.dropFirst() {
                guard let equals = part.firstIndex(of: "="), equals != part.startIndex else {
                    valid = false
                    break
                }
                let key = part[..<equals]
                guard !key.contains(where: { $0.isWhitespace || $0 == "[" }) else {
                    valid = false
                    break
                }
                data[String(key)] = .string(unescape(String(part[part.index(after: equals)...]), parameter: true))
            }
            guard valid else {
                cursor = string.index(after: cursor)
                continue
            }
            if textStart < cursor {
                segments.append([
                    "type": "text", "data": ["text": .string(unescape(String(string[textStart..<cursor])))],
                ])
            }
            segments.append(["type": .string(String(type)), "data": .object(data)])
            cursor = string.index(after: end)
            textStart = cursor
        }
        if textStart < string.endIndex {
            segments.append(["type": "text", "data": ["text": .string(unescape(String(string[textStart...])))]])
        }
        return segments
    }

    static func encode(_ segments: [JSONValue]) -> String {
        segments.map { segment in
            let type = segment["type"]?.stringValue ?? ""
            let data = segment["data"]?.objectValue ?? [:]
            if type == "text" { return escape(data["text"]?.stringValue ?? "") }
            let parameters = data.keys.sorted().map { key -> String in
                let value: String
                if key == "content", let content = data[key]?.arrayValue {
                    value = encode(content)
                } else {
                    value = data[key]?.stringValue ?? ""
                }
                return ",\(key)=\(escape(value, parameter: true))"
            }.joined()
            return "[CQ:\(type)\(parameters)]"
        }.joined()
    }

    private static func escape(_ string: String, parameter: Bool = false) -> String {
        var escaped = string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "[", with: "&#91;")
            .replacingOccurrences(of: "]", with: "&#93;")
        if parameter { escaped = escaped.replacingOccurrences(of: ",", with: "&#44;") }
        return escaped
    }

    private static func unescape(_ string: String, parameter: Bool = false) -> String {
        var value = string
        if parameter { value = value.replacingOccurrences(of: "&#44;", with: ",") }
        return value.replacingOccurrences(of: "&#91;", with: "[")
            .replacingOccurrences(of: "&#93;", with: "]")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
