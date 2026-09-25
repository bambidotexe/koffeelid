import Foundation

/// The two halves of RFC 6455 framing that talking to Codex's daemon needs: a client's text frame (always
/// masked) and a server's frames (never masked). A ping or pong is read past, a close ends the call, and
/// fragments and extensions are not spoken: a frame of that kind is no answer, and the call fails closed.
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

    /// What the bytes at the start of a server stream hold.
    public enum Decoded: Equatable {
        /// Not all of the next frame has arrived: read more.
        case incomplete
        /// A final, unmasked text or binary frame, `consumed` bytes long with its header.
        case frame(payload: Data, consumed: Int)
        /// A ping or a pong, `consumed` bytes long: drop it and read on. No pong is sent back.
        case skip(consumed: Int)
        /// A close frame: the daemon is ending the connection, and no answer follows.
        case closed
        /// A frame no more bytes can make an answer: masked, a fragment or continuation, a reserved opcode, a
        /// fragmented or over-long control frame, or a length above `maxPayloadBytes`. End the call.
        case invalid
    }

    /// The server frame at the start of `data`. Whatever can be judged from the header is judged as soon as
    /// the header is there: an invalid or closing frame ends the call without waiting for its payload.
    public static func decode(_ data: Data) -> Decoded {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count >= 2 else { return .incomplete }
        let final = bytes[0] & 0x80 != 0, reserved = bytes[0] & 0x70, opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        let control = opcode >= 0x8
        guard !masked, reserved == 0, final, [0x1, 0x2, 0x8, 0x9, 0xA].contains(opcode) else { return .invalid }
        if opcode == 0x8 { return .closed }
        var length = UInt64(bytes[1] & 0x7F), header = 2
        if control, length > 125 { return .invalid }
        if length == 126 {
            guard bytes.count >= 4 else { return .incomplete }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); header = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .incomplete }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }; header = 10
        }
        guard length <= UInt64(maxPayloadBytes) else { return .invalid }
        guard data.count >= header + Int(length) else { return .incomplete }
        if control { return .skip(consumed: header + Int(length)) }
        let start = data.startIndex + header
        return .frame(payload: Data(data[start..<start + Int(length)]), consumed: header + Int(length))
    }
}
