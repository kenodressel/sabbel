import Foundation

/// A TOML value as far as MiniTOML understands it.
public enum TOMLValue: Equatable, Sendable {
    case string(String), integer(Int), float(Double), bool(Bool)
    /// A right-hand side MiniTOML cannot read; the key's validator reports it.
    case invalid(String)
}

public struct MiniTOMLError: Error, Equatable, Sendable { public let message: String }

/// Parses only what Sabbel's config keys need: `[section]` headers, `key = value`
/// with basic or literal strings, integers, floats, booleans, and `#` comments.
///
/// A malformed value on a well-formed `key =` line becomes `.invalid`, so that one
/// bad key is dropped without taking the rest of the file down. A line whose
/// structure cannot be read at all (a broken header, no `=`) makes the whole file
/// unparseable, because everything after it could belong to the wrong section.
public enum MiniTOML {
    public typealias Document = [String: [String: TOMLValue]]

    public static func parse(_ text: String) throws -> Document {
        var doc: Document = [:]
        var section: String? = nil
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let n = index + 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else {
                    throw MiniTOMLError(message: "line \(n): unterminated section header")
                }
                let name = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard isBareKey(name), rest.isEmpty || rest.hasPrefix("#") else {
                    throw MiniTOMLError(message: "line \(n): invalid section header")
                }
                section = name
                if doc[name] == nil { doc[name] = [:] }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw MiniTOMLError(message: "line \(n): expected key = value")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else {
                throw MiniTOMLError(message: "line \(n): unsupported key")
            }
            guard let section else {
                throw MiniTOMLError(message: "line \(n): key outside a section")
            }
            let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            doc[section, default: [:]][key] = value(rhs)
        }
        return doc
    }

    private static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func isBlankOrComment(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    private static func value(_ rhs: String) -> TOMLValue {
        guard let first = rhs.first else { return .invalid("missing value") }
        if first == "'" {
            let body = rhs.dropFirst()
            guard let close = body.firstIndex(of: "'"), isBlankOrComment(body[body.index(after: close)...]) else {
                return .invalid("bad string")
            }
            return .string(String(body[..<close]))
        }
        if first == "\"" { return basicString(rhs) }
        let token = rhs.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        let digits = token.replacingOccurrences(of: "_", with: "")
        if digits.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil, let i = Int(digits) {
            return .integer(i)
        }
        let floatShape = #"^[+-]?([0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|inf|nan)$"#
        if digits.range(of: floatShape, options: .regularExpression) != nil, let d = Double(digits) {
            return .float(d)
        }
        return .invalid("unrecognised value")
    }

    private static func basicString(_ rhs: String) -> TOMLValue {
        var out = ""
        var it = rhs.dropFirst().makeIterator()
        while let c = it.next() {
            switch c {
            case "\"":
                let rest = String(it)
                return isBlankOrComment(Substring(rest)) ? .string(out) : .invalid("bad string")
            case "\\":
                guard let e = it.next() else { return .invalid("bad escape") }
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: return .invalid("unsupported escape")
                }
            default: out.append(c)
            }
        }
        return .invalid("unterminated string")
    }
}
