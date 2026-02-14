// ABOUTME: Tests for MCP protocol types including JSON-RPC parsing, JSONValue accessors, and tool result encoding.
// ABOUTME: Validates roundtrip encoding/decoding and correct behavior of convenience methods.

import Foundation
import Testing
@testable import HelperLib

@Suite("JSONValue")
struct JSONValueTests {

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    // MARK: - Decoding

    @Test("decodes string values")
    func decodeString() throws {
        let data = Data(#""hello""#.utf8)
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .string(let s) = value else {
            Issue.record("Expected .string, got \(value)")
            return
        }
        #expect(s == "hello")
    }

    @Test("decodes number values")
    func decodeNumber() throws {
        let data = Data("42.5".utf8)
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .number(let n) = value else {
            Issue.record("Expected .number, got \(value)")
            return
        }
        #expect(n == 42.5)
    }

    @Test("decodes boolean values")
    func decodeBool() throws {
        let trueData = Data("true".utf8)
        let trueVal = try decoder.decode(JSONValue.self, from: trueData)
        guard case .bool(let b) = trueVal else {
            Issue.record("Expected .bool, got \(trueVal)")
            return
        }
        #expect(b == true)
    }

    @Test("decodes null")
    func decodeNull() throws {
        let data = Data("null".utf8)
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .null = value else {
            Issue.record("Expected .null, got \(value)")
            return
        }
    }

    @Test("decodes arrays")
    func decodeArray() throws {
        let data = Data(#"[1, "two", true]"#.utf8)
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .array(let items) = value else {
            Issue.record("Expected .array, got \(value)")
            return
        }
        #expect(items.count == 3)
    }

    @Test("decodes objects")
    func decodeObject() throws {
        let data = Data(#"{"key": "value", "num": 99}"#.utf8)
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .object(let dict) = value else {
            Issue.record("Expected .object, got \(value)")
            return
        }
        #expect(dict.count == 2)
    }

    // MARK: - Encoding Roundtrip

    @Test("roundtrip encodes and decodes all value types")
    func roundtrip() throws {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .number(7),
            "active": .bool(false),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null,
        ])
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        // Re-encode and compare JSON strings for structural equality
        let reEncoded = try encoder.encode(decoded)
        #expect(data == reEncoded)
    }

    // MARK: - Accessor Methods

    @Test("getString returns string for matching key")
    func getStringSuccess() {
        let value: JSONValue = .object(["name": .string("tool1")])
        #expect(value.getString("name") == "tool1")
    }

    @Test("getString returns nil for missing key")
    func getStringMissing() {
        let value: JSONValue = .object(["name": .string("tool1")])
        #expect(value.getString("other") == nil)
    }

    @Test("getString returns nil for non-string value")
    func getStringWrongType() {
        let value: JSONValue = .object(["name": .number(42)])
        #expect(value.getString("name") == nil)
    }

    @Test("getString returns nil for non-object JSONValue")
    func getStringOnNonObject() {
        let value: JSONValue = .string("not an object")
        #expect(value.getString("name") == nil)
    }

    @Test("getNumber returns double for matching key")
    func getNumberSuccess() {
        let value: JSONValue = .object(["x": .number(3.14)])
        #expect(value.getNumber("x") == 3.14)
    }

    @Test("getNumber returns nil for missing key")
    func getNumberMissing() {
        let value: JSONValue = .object(["x": .number(1)])
        #expect(value.getNumber("y") == nil)
    }

    @Test("getArguments extracts nested arguments dictionary")
    func getArgumentsSuccess() {
        let value: JSONValue = .object([
            "name": .string("screenshot"),
            "arguments": .object(["format": .string("png")]),
        ])
        let args = value.getArguments()
        #expect(args != nil)
        guard case .string(let fmt) = args?["format"] else {
            Issue.record("Expected string format argument")
            return
        }
        #expect(fmt == "png")
    }

    @Test("getArguments returns nil when no arguments key")
    func getArgumentsMissing() {
        let value: JSONValue = .object(["name": .string("screenshot")])
        #expect(value.getArguments() == nil)
    }

    @Test("getToolName extracts name from params object")
    func getToolName() {
        let value: JSONValue = .object(["name": .string("tap")])
        #expect(value.getToolName() == "tap")
    }
}

@Suite("JSONRPCRequest")
struct JSONRPCRequestTests {

    private let decoder = JSONDecoder()

    @Test("decodes a valid request with integer ID")
    func decodeWithIntID() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.jsonrpc == "2.0")
        #expect(request.method == "initialize")
        guard case .number(let id) = request.id else {
            Issue.record("Expected integer ID")
            return
        }
        #expect(id == 1)
    }

    @Test("decodes a valid request with string ID")
    func decodeWithStringID() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        guard case .string(let id) = request.id else {
            Issue.record("Expected string ID")
            return
        }
        #expect(id == "abc")
    }

    @Test("decodes a notification (no ID)")
    func decodeNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.id == nil)
        #expect(request.method == "notifications/initialized")
    }

    @Test("decodes tools/call with name and arguments")
    func decodeToolsCall() throws {
        let json = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tap","arguments":{"x":100,"y":200}}}"#
        let request = try decoder.decode(JSONRPCRequest.self, from: Data(json.utf8))
        #expect(request.method == "tools/call")
        #expect(request.params?.getToolName() == "tap")
        let args = request.params?.getArguments()
        #expect(args != nil)
        guard case .number(let x) = args?["x"] else {
            Issue.record("Expected number for x")
            return
        }
        #expect(x == 100)
    }
}

@Suite("JSONRPCResponse")
struct JSONRPCResponseTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("encodes a success response with result")
    func encodeSuccess() throws {
        let response = JSONRPCResponse(
            id: .number(1),
            result: .object(["status": .string("ok")]),
            error: nil
        )
        let data = try encoder.encode(response)
        let dict = try decoder.decode([String: JSONValue].self, from: data)
        guard case .string(let ver) = dict["jsonrpc"] else {
            Issue.record("Expected jsonrpc string")
            return
        }
        #expect(ver == "2.0")
    }

    @Test("encodes an error response")
    func encodeError() throws {
        let response = JSONRPCResponse(
            id: .number(1),
            result: nil,
            error: JSONRPCError(code: -32601, message: "Method not found")
        )
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8)
        #expect(json != nil)
        #expect(json!.contains("-32601"))
        #expect(json!.contains("Method not found"))
    }
}

@Suite("JSONRPCError")
struct JSONRPCErrorResponseTests {

    private let encoder = JSONEncoder()

    @Test("method-not-found error uses code -32601")
    func methodNotFoundError() throws {
        let response = JSONRPCResponse(
            id: .number(1),
            result: nil,
            error: JSONRPCError(code: -32601, message: "Method not found: unknown_method")
        )
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("-32601"))
        #expect(json.contains("unknown_method"))
    }

    @Test("parse error uses code -32700")
    func parseError() throws {
        let response = JSONRPCResponse(
            id: nil,
            result: nil,
            error: JSONRPCError(code: -32700, message: "Parse error: invalid UTF-8")
        )
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("-32700"))
        #expect(json.contains("invalid UTF-8"))
    }

    @Test("invalid params error uses code -32602")
    func invalidParamsError() throws {
        let response = JSONRPCResponse(
            id: .string("req-42"),
            result: nil,
            error: JSONRPCError(code: -32602, message: "Missing tool name")
        )
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("-32602"))
        #expect(json.contains("Missing tool name"))
    }
}

@Suite("MCPToolResult")
struct MCPToolResultTests {

    @Test("text result has correct content and isError false")
    func textResult() {
        let result = MCPToolResult.text("hello")
        #expect(result.isError == false)
        #expect(result.content.count == 1)
        guard case .text(let t) = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(t == "hello")
    }

    @Test("error result has isError true")
    func errorResult() {
        let result = MCPToolResult.error("something failed")
        #expect(result.isError == true)
        guard case .text(let t) = result.content.first else {
            Issue.record("Expected text content in error")
            return
        }
        #expect(t == "something failed")
    }

    @Test("image result has correct MIME type")
    func imageResult() {
        let result = MCPToolResult.image("base64data", mimeType: "image/png")
        #expect(result.isError == false)
        guard case .image(let data, let mime) = result.content.first else {
            Issue.record("Expected image content")
            return
        }
        #expect(data == "base64data")
        #expect(mime == "image/png")
    }
}

@Suite("MCPContent")
struct MCPContentTests {

    @Test("text content produces correct JSON structure")
    func textToJSON() {
        let content = MCPContent.text("hello world")
        let json = content.toJSON()
        #expect(json.getString("type") == "text")
        #expect(json.getString("text") == "hello world")
    }

    @Test("image content produces correct JSON structure")
    func imageToJSON() {
        let content = MCPContent.image("abc123", mimeType: "image/jpeg")
        let json = content.toJSON()
        #expect(json.getString("type") == "image")
        #expect(json.getString("data") == "abc123")
        #expect(json.getString("mimeType") == "image/jpeg")
    }
}

@Suite("RequestID")
struct RequestIDTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("integer ID roundtrips correctly")
    func intRoundtrip() throws {
        let id = RequestID.number(42)
        let data = try encoder.encode(id)
        let decoded = try decoder.decode(RequestID.self, from: data)
        guard case .number(let n) = decoded else {
            Issue.record("Expected .number")
            return
        }
        #expect(n == 42)
    }

    @Test("string ID roundtrips correctly")
    func stringRoundtrip() throws {
        let id = RequestID.string("req-001")
        let data = try encoder.encode(id)
        let decoded = try decoder.decode(RequestID.self, from: data)
        guard case .string(let s) = decoded else {
            Issue.record("Expected .string")
            return
        }
        #expect(s == "req-001")
    }
}
