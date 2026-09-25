import XCTest
import KoffeeLidCore

final class WebSocketFrameTests: XCTestCase {
    /// Reads a client frame back by hand: FIN + text, the mask bit, the length in its 7-, 16- or 64-bit
    /// form, the four-byte key, then the payload XORed with it.
    func unmask(_ frame: Data) -> (lengthForm: Int, payload: Data)? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 2, bytes[0] == 0x81, bytes[1] & 0x80 != 0 else { return nil }
        var length = Int(bytes[1] & 0x7F), offset = 2, form = 7
        if length == 126 {
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4; form = 16
        } else if length == 127 {
            length = (0..<8).reduce(0) { $0 << 8 | Int(bytes[2 + $1]) }; offset = 10; form = 64
        }
        guard bytes.count == offset + 4 + length else { return nil }
        let key = Array(bytes[offset..<offset + 4])
        let payload = bytes[(offset + 4)...].enumerated().map { $0.element ^ key[$0.offset % 4] }
        return (form, Data(payload))
    }

    func testAClientTextFrameIsMaskedAndFramed() {
        for (count, form) in [(5, 7), (200, 16), (70_000, 64)] {
            let text = String(repeating: "a", count: count - 1) + "z"
            let frame = WebSocketFrame.encodeText(text)
            guard let read = unmask(frame) else { return XCTFail("frame of \(count) bytes is not a masked text frame") }
            XCTAssertEqual(read.lengthForm, form, "length form for \(count) bytes")
            XCTAssertEqual(read.payload, Data(text.utf8))
        }
        let json = #"{"jsonrpc":"2.0","method":"initialized"}"#
        XCTAssertEqual(unmask(WebSocketFrame.encodeText(json))?.payload, Data(json.utf8))
    }

    func testAServerTextFrameDecodes() {
        let hello = Data([0x81, 0x05]) + Data("hello".utf8) + Data([0x81])
        XCTAssertEqual(WebSocketFrame.decode(hello), .frame(payload: Data("hello".utf8), consumed: 7),
                       "the next frame's first byte is left in the buffer")

        let medium = Data(repeating: 0x62, count: 300)
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 126, 0x01, 0x2C]) + medium), .frame(payload: medium, consumed: 304))

        let large = Data(repeating: 0x63, count: 70_000)
        let sixtyFour = Data([0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70]) + large
        XCTAssertEqual(WebSocketFrame.decode(sixtyFour), .frame(payload: large, consumed: 70_010), "a binary frame decodes too")
    }

    func testAShortFragmentDecodesToNil() {
        XCTAssertEqual(WebSocketFrame.decode(Data()), .incomplete)
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81])), .incomplete)
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 0x05]) + Data("hel".utf8)), .incomplete, "shorter than its length")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 126, 0x01])), .incomplete, "its 16-bit length is cut")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 127, 0, 0, 0])), .incomplete, "its 64-bit length is cut")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x89, 0x04, 0x01])), .incomplete, "a ping still arriving")
    }

    func testAPingBeforeTheReplyIsSkipped() {
        let reply = Data([0x81, 0x02]) + Data("{}".utf8)
        let stream = Data([0x89, 0x04]) + Data("ping".utf8) + reply
        XCTAssertEqual(WebSocketFrame.decode(stream), .skip(consumed: 6))
        XCTAssertEqual(WebSocketFrame.decode(stream.dropFirst(6)), .frame(payload: Data("{}".utf8), consumed: 4))
        XCTAssertEqual(WebSocketFrame.decode(Data([0x8A, 0x00]) + reply), .skip(consumed: 2), "a pong is skipped too")
    }

    func testACloseEndsTheCall() {
        XCTAssertEqual(WebSocketFrame.decode(Data([0x88, 0x02, 0x03, 0xE8])), .closed)
        XCTAssertEqual(WebSocketFrame.decode(Data([0x88, 0x00])), .closed)
    }

    func testAMaskedFrameIsInvalid() {
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 0x85, 1, 2, 3, 4]) + Data("hello".utf8)), .invalid, "a server frame is never masked")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 0x85])), .invalid, "known from its second byte, before the rest arrives")
    }

    func testAFrameThatCanNeverBeAnAnswerIsInvalid() {
        XCTAssertEqual(WebSocketFrame.decode(Data([0x01, 0x05]) + Data("hello".utf8)), .invalid, "the first fragment of a longer message")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x80, 0x05]) + Data("hello".utf8)), .invalid, "a continuation")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x83, 0x00])), .invalid, "a reserved opcode")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x09, 0x00])), .invalid, "a fragmented control frame")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x89, 126, 0x00, 0x7E])), .invalid, "a control frame longer than 125 bytes")
        XCTAssertEqual(WebSocketFrame.decode(Data([0x81, 127, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])), .invalid, "a length no answer has")
    }
}
