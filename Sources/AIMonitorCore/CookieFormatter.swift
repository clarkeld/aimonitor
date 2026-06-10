import Foundation

public enum CookieFormatter {
    public static func header(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let jsonHeader = headerFromJSON(trimmed) {
            return jsonHeader
        }

        return trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractValue(for name: String, from cookieString: String) -> String? {
        let header = Self.header(from: cookieString)
        let pairs = header.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 && parts[0] == name {
                var value = String(parts[1])
                // 移除可能存在的引号包裹
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }

    private static func headerFromJSON(_ input: String) -> String? {
        let jsonText: String
        if input.hasPrefix("cookies:") {
            jsonText = String(input.dropFirst("cookies:".count))
        } else {
            jsonText = input
        }

        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let cookieObjects: [[String: Any]]
        if let array = object as? [[String: Any]] {
            cookieObjects = array
        } else if let dictionary = object as? [String: Any],
                  let array = dictionary["cookies"] as? [[String: Any]] {
            cookieObjects = array
        } else {
            return nil
        }

        let pairs = cookieObjects.compactMap { cookie -> String? in
            guard let name = cookie["name"] as? String,
                  let value = cookie["value"] as? String,
                  !name.isEmpty else {
                return nil
            }
            return "\(name)=\(value)"
        }

        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}

extension CharacterSet {
    public static let urlQueryValueAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@"
        let subDelimitersToEncode = "!$&'()*+,;="
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: generalDelimitersToEncode + subDelimitersToEncode)
        return allowed
    }()
}
