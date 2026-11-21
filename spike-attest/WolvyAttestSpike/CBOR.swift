import Foundation

/// Just enough CBOR (RFC 8949, definite lengths) to read App Attest objects. Spike code.
indirect enum CBOR: CustomStringConvertible {
    case uint(UInt64), nint(Int64), bytes(Data), text(String), array([CBOR]), map([(CBOR, CBOR)])
    case bool(Bool), null, other(UInt8)

    subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { if case .text(let k) = $0.0 { return k == key } else { return false } }?.1
    }
    var data: Data? { if case .bytes(let d) = self { return d } else { return nil } }

    var description: String {
        switch self {
        case .uint(let v): return "\(v)"
        case .nint(let v): return "\(v)"
        case .bytes(let d): return d.count <= 32 ? "h'\(d.hex)'" : "<\(d.count) bytes>"
        case .text(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .map(let m): return "{" + m.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "}"
        case .bool(let b): return "\(b)"
        case .null: return "null"
        case .other(let b): return "simple(\(b))"
        }
    }

    enum Failure: Error { case truncated, unsupported(UInt8) }

    /// Decodes one item starting at `offset`; returns it and the offset just past it.
    static func decode(_ d: Data, at offset: Int = 0) throws -> (CBOR, Int) {
        let b = [UInt8](d)
        var i = offset
        func byte() throws -> UInt8 { guard i < b.count else { throw Failure.truncated }; defer { i += 1 }; return b[i] }
        func arg(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25, 26, 27:
                let n = info == 25 ? 2 : info == 26 ? 4 : 8
                var v: UInt64 = 0
                for _ in 0..<n { v = (v << 8) | UInt64(try byte()) }
                return v
            default: throw Failure.unsupported(info)
            }
        }
        func take(_ n: Int) throws -> Data {
            guard n >= 0, i + n <= b.count else { throw Failure.truncated }
            defer { i += n }
            return Data(b[i..<(i + n)])
        }
        func item() throws -> CBOR {
            let first = try byte()
            let major = first >> 5, info = first & 0x1f
            switch major {
            case 0: return .uint(try arg(info))
            case 1: return .nint(-1 - Int64(try arg(info)))
            case 2: return .bytes(try take(Int(try arg(info))))
            case 3: return .text(String(decoding: try take(Int(try arg(info))), as: UTF8.self))
            case 4: return .array(try (0..<Int(try arg(info))).map { _ in try item() })
            case 5: return .map(try (0..<Int(try arg(info))).map { _ in (try item(), try item()) })
            case 6: _ = try arg(info); return try item() // tag: keep the value
            default:
                switch info { case 20: return .bool(false); case 21: return .bool(true); case 22: return .null
                default: return .other(info) }
            }
        }
        let value = try item()
        return (value, i)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
