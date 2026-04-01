import Foundation

enum OutputMode {
    case human
    case json
}

struct OutputFormat {
    let mode: OutputMode

    func render(_ dict: [String: Any]) -> String {
        switch mode {
        case .human:
            return renderHuman(dict)
        case .json:
            return renderJSON(dict)
        }
    }

    func render(_ items: [[String: Any]], numbered: Bool = true) -> String {
        switch mode {
        case .human:
            return items.enumerated().map { (i, item) in
                let prefix = numbered ? "\(i + 1). " : ""
                return prefix + renderHuman(item)
            }.joined(separator: "\n")
        case .json:
            return renderJSON(items)
        }
    }

    private func renderHuman(_ dict: [String: Any]) -> String {
        let values = dict.values.map { "\($0)" }
        return values.joined(separator: " — ")
    }

    private func renderJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
