import Foundation

/// The two halves of RFC 6455 framing that talking to Codex's daemon needs: a client's text frame (always
/// masked) and a server's data frame (never masked). Control frames, fragments and extensions are not
/// spoken: a frame of that kind is no answer, and the call it belonged to fails closed.
public enum WebSocketFrame {
    /// The largest server payload read: an answer to one of the three calls is a few hundred bytes, and a
    /// longer one decides nothing.
    public static let maxPayloadBytes = 1 << 20

    /// `text` as one final, masked text frame, with a fresh random masking key.
    public static func encodeText(_ text: String) -> Data {
        var generator = SystemRandomNumberGenerator()
        let key = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81]
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65_536:
            frame.append(0x80 | 126)
            frame += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (8 * UInt64($0))) & 0xFF) }
        }
        frame += key
        frame += payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        return Data(frame)
    }

    /// The payload of the server frame at the start of `data` and how many bytes it took, or nil while the
    /// frame is not all there. A frame that is not a final, unmasked text or binary frame, or that claims
    /// more than `maxPayloadBytes`, is nil too: no more bytes will make it an answer.
    public static func decode(_ data: Data) -> (payload: Data, consumed: Int)? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count >= 2 else { return nil }
        let final = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0F, masked = bytes[1] & 0x80 != 0
        guard final, opcode == 0x1 || opcode == 0x2, !masked else { return nil }
        var length = UInt64(bytes[1] & 0x7F), header = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); header = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }; header = 10
        }
        guard length <= UInt64(maxPayloadBytes), data.count >= header + Int(length) else { return nil }
        let start = data.startIndex + header
        return (Data(data[start..<start + Int(length)]), header + Int(length))
    }
}
