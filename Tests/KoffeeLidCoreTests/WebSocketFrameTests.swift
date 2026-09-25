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
        let decoded = WebSocketFrame.decode(hello)
        XCTAssertEqual(decoded?.payload, Data("hello".utf8))
        XCTAssertEqual(decoded?.consumed, 7, "the next frame's first byte is left in the buffer")

        let medium = Data(repeating: 0x62, count: 300)
        let sixteen = Data([0x81, 126, 0x01, 0x2C]) + medium
        XCTAssertEqual(WebSocketFrame.decode(sixteen)?.payload, medium)
        XCTAssertEqual(WebSocketFrame.decode(sixteen)?.consumed, 304)

        let large = Data(repeating: 0x63, count: 70_000)
        let sixtyFour = Data([0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70]) + large
        XCTAssertEqual(WebSocketFrame.decode(sixtyFour)?.payload, large, "a binary frame decodes too")
        XCTAssertEqual(WebSocketFrame.decode(sixtyFour)?.consumed, 70_010)
    }

    func testAShortFragmentDecodesToNil() {
        XCTAssertNil(WebSocketFrame.decode(Data()))
        XCTAssertNil(WebSocketFrame.decode(Data([0x81])))
        XCTAssertNil(WebSocketFrame.decode(Data([0x81, 0x05]) + Data("hel".utf8)), "shorter than its length")
        XCTAssertNil(WebSocketFrame.decode(Data([0x81, 126, 0x01])), "its 16-bit length is cut")
        XCTAssertNil(WebSocketFrame.decode(Data([0x81, 127, 0, 0, 0])), "its 64-bit length is cut")
    }

    func testAFrameThatIsNotAWholeServerAnswerDecodesToNil() {
        XCTAssertNil(WebSocketFrame.decode(Data([0x81, 0x85, 1, 2, 3, 4]) + Data("hello".utf8)), "a server frame is never masked")
        XCTAssertNil(WebSocketFrame.decode(Data([0x01, 0x05]) + Data("hello".utf8)), "a fragment of a longer message")
        XCTAssertNil(WebSocketFrame.decode(Data([0x88, 0x02, 0x03, 0xE8])), "a close frame carries no answer")
        XCTAssertNil(WebSocketFrame.decode(Data([0x81, 127, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])), "a length no answer has")
    }
}
