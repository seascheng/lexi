import Foundation

/// Launcher calculator: raw query → answer, or nil when the input isn't
/// a calculation. Design adapted from tinycast's `CalcParser` —
/// precedence-climbing (no AST), `%` as a percent value rather than
/// modulo, and silence on anything malformed or non-finite, so a
/// search-intent query ("notes", "42") never flashes a card.
///
/// Pure Foundation on purpose: no AppKit, no state — the panel calls
/// `evaluate` on every keystroke.
///
/// Grammar (binding powers: additive 10, multiplicative 20, unary 25,
/// power 30 right-associative, postfix tightest):
///
///     expression := operand ( binop expression | juxtaposition )*
///     operand    := prefix postfix*            // postfix = %
///     prefix     := number | -expr | +expr | ( expr ) | constant
///                 | fn ( expr [, expr]* ) | unaryfn [ ( expr ) | operand ]
///
/// Juxtaposition multiplies only next to `(` and known names, so
/// `2(3+4)`, `2pi` and `6/2(1+2)` work while `2 3` and `1password`
/// stay search input.
enum CalcEngine {

    // MARK: entry

    /// The evaluated answer, or nil when the query is not a calculation.
    /// A bare number ("42") is search input, not a calculation.
    static func evaluate(_ raw: String) -> Double? {
        guard let tokens = tokenize(raw),
              tokens.contains(where: isCalcToken)
        else { return nil }
        var parser = Parser(tokens: tokens)
        return parser.parseRoot()
    }

    /// Human-facing answer: ≤10 significant digits, trailing zeros
    /// trimmed, thousands separators.
    static func display(_ value: Double) -> String {
        grouped(copyText(value))
    }

    /// Same rounding, no grouping — what lands on the pasteboard.
    static func copyText(_ value: Double) -> String {
        let v = value == 0 ? 0 : value  // normalize -0
        // Past 2^53 the precision is genuinely gone, so exponent form is
        // the honest answer there. Every integer up to it is exact.
        if v.rounded() == v, abs(v) <= maxExactInteger {
            return String(format: "%.0f", v)
        }
        return String(format: "%.10g", v)
    }

    // MARK: tokenizer

    private enum Token: Equatable {
        case number(Double)
        /// Lowercased word: a constant or function name, or a reject.
        case ident(String)
        /// + - * / ^ ( ) , %
        case op(Character)
    }

    /// nil on any character that can't be calculator input — "not a
    /// calculation", not an error.
    private static func tokenize(_ input: String) -> [Token]? {
        let chars = Array(input)
        var tokens: [Token] = []
        var i = 0
        // Comma disambiguation: inside the parens of a function call a
        // comma separates arguments ("max(1,5)"); everywhere else, a
        // comma between digits is a thousands separator ("1,000+2").
        // One bool per open paren — "was it opened by a function name?"
        var parenStack: [Bool] = []

        func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }

            if isDigit(ch) || (ch == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
                var text = ""
                var seenDot = false
                while i < chars.count {
                    let c = chars[i]
                    if isDigit(c) {
                        text.append(c)
                    } else if c == ",", i + 1 < chars.count, isDigit(chars[i + 1]),
                        !parenStack.contains(true) {
                        // grouping separator between digits — skip
                    } else if c == ".", !seenDot {
                        seenDot = true
                        text.append(c)
                    } else {
                        break
                    }
                    i += 1
                }
                // Exponent only while it hugs the mantissa; a spaced `2 e`
                // stays 2 × e.
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    var end = j
                    while end < chars.count, isDigit(chars[end]) { end += 1 }
                    if end > j {
                        text += String(chars[i..<end])
                        i = end
                    }
                }
                // An overflowing literal ("1e400") isn't calculator input.
                guard let value = Double(text), value.isFinite else { return nil }
                tokens.append(.number(value))
                continue
            }

            if ch.isLetter {
                var text = ""
                while i < chars.count, chars[i].isLetter { text.append(chars[i]); i += 1 }
                tokens.append(.ident(text.lowercased()))
                continue
            }

            switch ch {
            case "+":
                tokens.append(.op("+"))
            case "-", "−":
                tokens.append(.op("-"))
            case "*", "×":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    tokens.append(.op("^"))  // ** is ^ (shell/JS spelling)
                    i += 2
                    continue
                }
                tokens.append(.op("*"))
            case "/", "÷":
                tokens.append(.op("/"))
            case "^":
                tokens.append(.op("^"))
            case "%":
                tokens.append(.op("%"))
            case "(":
                // A function name directly before the paren makes this a
                // call — its commas are argument separators.
                let opensCall: Bool
                if case .ident(let name)? = tokens.last {
                    opensCall = unaryFunctions[name] != nil || name == "min" || name == "max"
                } else {
                    opensCall = false
                }
                tokens.append(.op("("))
                parenStack.append(opensCall)
            case ")":
                tokens.append(.op(")"))
                if !parenStack.isEmpty { parenStack.removeLast() }
            case ",":
                tokens.append(.op(","))
            case "=":
                // Tolerate a trailing "=" ("2+2="); anywhere else it's
                // not calculator input.
                guard i == chars.count - 1 else { return nil }
            default:
                return nil
            }
            i += 1
        }
        return tokens
    }

    /// A query needs at least one operator, function or constant before
    /// it counts as a calculation — a bare number is search input.
    private static func isCalcToken(_ token: Token) -> Bool {
        switch token {
        case .op(let c): return "+-*/^%".contains(c)
        case .ident(let name):
            return unaryFunctions[name] != nil || name == "min" || name == "max"
                || constants[name] != nil
        case .number: return false
        }
    }

    // MARK: names

    private static let unaryFunctions: [String: (Double) -> Double] = [
        "sqrt": sqrt,
        "abs": abs,
        "round": { $0.rounded() },
    ]

    private static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "e": M_E,
    ]

    /// Every integer up to 2^53 is exactly representable as a Double.
    private static let maxExactInteger = 9_007_199_254_740_992.0

    // MARK: parser

    /// A value that may still be a "percent": relative for additive ops,
    /// value/100 everywhere else.
    private struct Value {
        var value: Double
        var isPercent = false
        var effective: Double { isPercent ? value / 100 : value }
    }

    private struct Parser {
        let tokens: [Token]
        var pos = 0

        private static let unaryBP = 25
        private static let mulBP = 20

        init(tokens: [Token]) { self.tokens = tokens }

        private var current: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseRoot() -> Double? {
            guard let value = parseExpression(minBP: 0), pos == tokens.count,
                value.effective.isFinite
            else { return nil }
            return value.effective
        }

        mutating func parseExpression(minBP: Int) -> Value? {
            guard var lhs = parseOperand() else { return nil }
            while true {
                if let binary = peekBinary(), binary.bindingPower >= minBP {
                    pos += 1
                    guard let rhs = parseExpression(minBP: binary.rightBindingPower),
                        let combined = apply(binary.op, lhs, rhs)
                    else { return nil }
                    lhs = combined
                    continue
                }
                // Juxtaposition is the operator here, so there's no token
                // to consume before the rhs.
                if impliesMultiplication(), Self.mulBP >= minBP {
                    guard let rhs = parseExpression(minBP: Self.mulBP + 1),
                        let combined = apply("*", lhs, rhs)
                    else { return nil }
                    lhs = combined
                    continue
                }
                break
            }
            return lhs
        }

        /// Deliberately narrow: only `(` and known names multiply.
        private func impliesMultiplication() -> Bool {
            switch current {
            case .op("("): return true
            case .ident(let name):
                return CalcEngine.unaryFunctions[name] != nil
                    || name == "min" || name == "max"
                    || CalcEngine.constants[name] != nil
            default: return false
            }
        }

        private struct BinaryOp {
            let op: Character
            let bindingPower: Int
            let rightBindingPower: Int
        }

        private func peekBinary() -> BinaryOp? {
            switch current {
            case .op(let op) where op == "+" || op == "-":
                return BinaryOp(op: op, bindingPower: 10, rightBindingPower: 11)
            case .op(let op) where op == "*" || op == "/":
                return BinaryOp(op: op, bindingPower: Self.mulBP, rightBindingPower: Self.mulBP + 1)
            case .op("^"):
                return BinaryOp(op: "^", bindingPower: 30, rightBindingPower: 30)
            default:
                return nil
            }
        }

        private func apply(_ op: Character, _ lhs: Value, _ rhs: Value) -> Value? {
            let result: Double
            switch op {
            // `50+10%` reads as a relative change: 50 × 1.1. With a plain
            // rhs it's ordinary math.
            case "+":
                result = rhs.isPercent
                    ? lhs.effective * (1 + rhs.value / 100) : lhs.effective + rhs.effective
            case "-":
                result = rhs.isPercent
                    ? lhs.effective * (1 - rhs.value / 100) : lhs.effective - rhs.effective
            case "*": result = lhs.effective * rhs.effective
            case "/": result = lhs.effective / rhs.effective
            case "^": result = pow(lhs.effective, rhs.effective)
            default: return nil
            }
            return Value(value: result)
        }

        /// One prefix item plus its postfixes — `%` binds tightest.
        private mutating func parseOperand() -> Value? {
            guard var value = parsePrefix() else { return nil }
            while case .op("%") = current {
                guard !value.isPercent else { return nil }
                value.isPercent = true
                pos += 1
            }
            return value
        }

        private mutating func parsePrefix() -> Value? {
            switch current {
            case .number(let n):
                pos += 1
                return Value(value: n)
            case .op("-"):
                pos += 1
                guard let operand = parseExpression(minBP: Self.unaryBP) else { return nil }
                return Value(value: -operand.effective)
            case .op("+"):
                pos += 1
                return parseExpression(minBP: Self.unaryBP)
            case .op("("):
                pos += 1
                guard let inner = parseExpression(minBP: 0), case .op(")") = current else {
                    return nil
                }
                pos += 1
                return inner
            case .ident(let name):
                if let constant = CalcEngine.constants[name] {
                    pos += 1
                    return Value(value: constant)
                }
                if name == "min" || name == "max" {
                    pos += 1
                    return parseVariadic(name)
                }
                if let fn = CalcEngine.unaryFunctions[name] {
                    pos += 1
                    let argument: Value?
                    if case .op("(") = current {
                        pos += 1
                        argument = parseExpression(minBP: 0)
                        guard case .op(")") = current else { return nil }
                        pos += 1
                    } else {
                        // Bare application takes one operand, so
                        // `sqrt 64 + 36` is sqrt(64) + 36.
                        argument = parseOperand()
                    }
                    guard let argument else { return nil }
                    let out = fn(argument.effective)
                    guard out.isFinite else { return nil }
                    return Value(value: out)
                }
                return nil
            default:
                return nil
            }
        }

        /// `min`/`max` need parens and at least two arguments.
        private mutating func parseVariadic(_ name: String) -> Value? {
            guard case .op("(") = current else { return nil }
            pos += 1
            var args: [Double] = []
            while true {
                guard let value = parseExpression(minBP: 0) else { return nil }
                args.append(value.effective)
                if case .op(",") = current { pos += 1; continue }
                break
            }
            guard case .op(")") = current, args.count >= 2 else { return nil }
            pos += 1
            return Value(value: name == "min" ? args.min()! : args.max()!)
        }
    }

    // MARK: grouping (display side)

    /// Insert `,` every three integer digits. Exponent-form strings pass
    /// through untouched.
    private static func grouped(_ text: String) -> String {
        guard !text.contains("e"), !text.contains("E") else { return text }
        let sign = text.hasPrefix("-") ? "-" : ""
        let unsigned = sign.isEmpty ? text : String(text.dropFirst())
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intDigits = Array(parts[0])
        guard intDigits.count > 3 else { return text }

        var groupedInt = ""
        for (i, digit) in intDigits.enumerated() {
            if i > 0 && (intDigits.count - i) % 3 == 0 { groupedInt.append(",") }
            groupedInt.append(digit)
        }
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        return sign + groupedInt + fraction
    }
}
