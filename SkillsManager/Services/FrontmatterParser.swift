import Foundation

/// Tolerant parser for the YAML subset used in SKILL.md frontmatter.
///
/// Handles `key: value` pairs, quoted scalars, folded/literal blocks
/// (`>`, `>-`, `|`, `|-`), simple `- item` lists (joined with ", "), and
/// one level of nesting (flattened to "parent.child"). Lines it cannot
/// make sense of are skipped rather than failing the parse.
enum FrontmatterParser {
    struct Result: Sendable, Equatable {
        var fields: [String: String] = [:]
        var body: String = ""
    }

    static func parse(_ contents: String) -> Result {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first.map(isDelimiter) == true else {
            return Result(fields: [:], body: contents)
        }
        lines = lines.dropFirst()

        var fields: [String: String] = [:]
        var bodyStart: Int?

        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            if isDelimiter(line) {
                bodyStart = index + 1
                break
            }
            index = parseEntry(lines, at: index, prefix: "", into: &fields)
        }

        var body = ""
        if let bodyStart, bodyStart < lines.endIndex {
            body = lines[bodyStart...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Result(fields: fields, body: body)
    }

    // MARK: - Implementation

    private static func isDelimiter(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    private static func indentation(_ line: Substring) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// Parses one mapping entry starting at `index`; returns the index of
    /// the first line it did not consume.
    private static func parseEntry(
        _ lines: ArraySlice<Substring>.SubSequence,
        at index: Int,
        prefix: String,
        into fields: inout [String: String]
    ) -> Int {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return index + 1 }

        guard let colon = trimmed.firstIndex(of: ":") else { return index + 1 }
        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return index + 1 }
        let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
        let rawValue = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)

        let baseIndent = indentation(line)

        // Block scalar: gather indented continuation lines.
        if rawValue == ">" || rawValue == ">-" || rawValue == "|" || rawValue == "|-" {
            var collected: [String] = []
            var next = index + 1
            while next < lines.endIndex {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty {
                    collected.append("")
                    next += 1
                    continue
                }
                guard indentation(candidate) > baseIndent, !isDelimiter(candidate) else { break }
                collected.append(candidateTrimmed)
                next += 1
            }
            let separator = rawValue.hasPrefix("|") ? "\n" : " "
            fields[fullKey] = collected.joined(separator: separator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return next
        }

        // Empty value: either a nested mapping or a list follows.
        if rawValue.isEmpty {
            var next = index + 1
            var listItems: [String] = []
            while next < lines.endIndex {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty { next += 1; continue }
                guard indentation(candidate) > baseIndent, !isDelimiter(candidate) else { break }
                if candidateTrimmed.hasPrefix("- ") || candidateTrimmed == "-" {
                    listItems.append(unquote(String(candidateTrimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)))
                    next += 1
                } else {
                    next = parseEntry(lines, at: next, prefix: fullKey, into: &fields)
                }
            }
            if !listItems.isEmpty {
                fields[fullKey] = listItems.joined(separator: ", ")
            }
            return next
        }

        // Inline list.
        if rawValue.hasPrefix("["), rawValue.hasSuffix("]") {
            let inner = rawValue.dropFirst().dropLast()
            let items = inner.split(separator: ",").map {
                unquote($0.trimmingCharacters(in: .whitespaces))
            }
            fields[fullKey] = items.joined(separator: ", ")
            return index + 1
        }

        fields[fullKey] = unquote(rawValue)
        return index + 1
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
