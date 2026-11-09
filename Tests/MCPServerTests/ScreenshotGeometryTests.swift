// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the geometry reported with a screenshot and the conversion of an image point to a window point.
// ABOUTME: Also covers the screenshot tool's reply and the tap tool's image_size and image_region arguments.

import CoreGraphics
import ImageIO
import XCTest
import HelperLib
@testable import mirroir_mcp

/// A valid PNG of the given pixel size.
private func makePNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(
              data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

final class ScreenshotGeometryTests: XCTestCase {

    private let window = CGSize(width: 410, height: 898)

    func testFullFrameAtTwoX() throws {
        let png = try XCTUnwrap(makePNG(width: 820, height: 1796))
        let geometry = try XCTUnwrap(ScreenshotGeometry.of(png: png, windowSize: window, region: nil))
        XCTAssertEqual(geometry.pixelSize, CGSize(width: 820, height: 1796))
        XCTAssertEqual(geometry.shownRect, CGRect(origin: .zero, size: window))
        XCTAssertEqual(geometry.pixelsPerPoint, 2)
    }

    func testFullFrameAtOneX() throws {
        let png = try XCTUnwrap(makePNG(width: 410, height: 898))
        let geometry = try XCTUnwrap(ScreenshotGeometry.of(png: png, windowSize: window, region: nil))
        XCTAssertEqual(geometry.pixelsPerPoint, 1)
    }

    /// The factor is read from the image that was returned, so the scale argument is covered.
    func testScaledFrame() throws {
        let full = try XCTUnwrap(makePNG(width: 820, height: 1796))
        let scaled = try XCTUnwrap(ScreenshotRegionScaler.transform(
            pngData: full, windowSize: window, region: nil, scale: 0.5))
        let geometry = try XCTUnwrap(ScreenshotGeometry.of(png: scaled, windowSize: window, region: nil))
        XCTAssertEqual(geometry.pixelSize, CGSize(width: 410, height: 898))
        XCTAssertEqual(geometry.pixelsPerPoint, 1)
    }

    func testRegionFrame() throws {
        let full = try XCTUnwrap(makePNG(width: 820, height: 1796))
        let region = CGRect(x: 100, y: 200, width: 200, height: 300)
        let cropped = try XCTUnwrap(ScreenshotRegionScaler.transform(
            pngData: full, windowSize: window, region: region, scale: nil))
        let geometry = try XCTUnwrap(ScreenshotGeometry.of(png: cropped, windowSize: window, region: region))
        XCTAssertEqual(geometry.pixelSize, CGSize(width: 400, height: 600))
        XCTAssertEqual(geometry.shownRect, region)
        XCTAssertEqual(geometry.pixelsPerPoint, 2)
    }

    func testRegionIsClampedToTheWindow() {
        let shown = ScreenshotGeometry.shownRect(
            region: CGRect(x: 300, y: 800, width: 400, height: 400), windowSize: window)
        XCTAssertEqual(shown, CGRect(x: 300, y: 800, width: 110, height: 98))
    }

    func testUnreadablePNGIsNil() {
        XCTAssertNil(ScreenshotGeometry.of(png: Data([1, 2, 3]), windowSize: window, region: nil))
        XCTAssertNil(ScreenshotGeometry.of(png: Data(), windowSize: window, region: nil))
    }

    func testSummaryNamesPixelsPointsAndFactor() {
        let geometry = ScreenshotGeometry(
            pixelSize: CGSize(width: 820, height: 1796), windowSize: window,
            shownRect: CGRect(origin: .zero, size: window))
        XCTAssertEqual(
            geometry.summary,
            "Screenshot: 820x1796 px showing the whole 410x898 pt window (2 px per point). "
            + "tap takes points, not pixels: to tap something seen here, pass its position in this "
            + "image as x and y with image_size [820, 1796].")
    }

    func testSummaryForARegionNamesTheRegion() {
        let geometry = ScreenshotGeometry(
            pixelSize: CGSize(width: 200, height: 300), windowSize: window,
            shownRect: CGRect(x: 100, y: 200, width: 200, height: 300))
        XCTAssertEqual(
            geometry.summary,
            "Screenshot: 200x300 px showing window points x 100-300, y 200-500 of the 410x898 pt "
            + "window (1 px per point). tap takes points, not pixels: to tap something seen here, "
            + "pass its position in this image as x and y with image_size [200, 300] and "
            + "image_region [100, 200, 200, 300].")
    }

    func testSummaryKeepsAFractionalFactor() {
        let geometry = ScreenshotGeometry(
            pixelSize: CGSize(width: 615, height: 1347), windowSize: window,
            shownRect: CGRect(origin: .zero, size: window))
        XCTAssertTrue(geometry.summary.contains("(1.5 px per point)"), geometry.summary)
    }

    func testWindowPointFromAFullFrame() {
        let point = ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: 410, y: 898), imageSize: CGSize(width: 820, height: 1796),
            shownRect: CGRect(origin: .zero, size: window))
        XCTAssertEqual(point, CGPoint(x: 205, y: 449))
    }

    /// The image the model saw may have been resized by its client: the size it names decides.
    func testWindowPointFromADownsizedImage() {
        let whole = CGRect(origin: .zero, size: window)
        XCTAssertEqual(ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: 205, y: 449), imageSize: window, shownRect: whole),
            CGPoint(x: 205, y: 449))
        let point = ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: 358, y: 784), imageSize: CGSize(width: 716, height: 1568),
            shownRect: whole)
        XCTAssertEqual(point.x, 205, accuracy: 0.5)
        XCTAssertEqual(point.y, 449, accuracy: 0.5)
    }

    func testWindowPointFromARegion() {
        let point = ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: 100, y: 150), imageSize: CGSize(width: 200, height: 300),
            shownRect: CGRect(x: 100, y: 200, width: 200, height: 300))
        XCTAssertEqual(point, CGPoint(x: 200, y: 350))
    }
}

/// The screenshot and tap tools, through their MCP handlers.
final class ScreenshotPointToolTests: XCTestCase {

    private var server: MCPServer!
    private var input: StubInput!
    private var capture: StubCapture!

    override func setUp() {
        super.setUp()
        server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        let bridge = StubBridge()
        bridge.processRunning = true
        input = StubInput()
        capture = StubCapture()
        let registry = makeTestRegistry(bridge: bridge, input: input, capture: capture)
        MirroirMCP.registerScreenTools(server: server, registry: registry)
        MirroirMCP.registerTapTools(server: server, registry: registry)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> (content: [[String: JSONValue]], isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"] else { return ([], true) }
        let blocks = content.compactMap { block -> [String: JSONValue]? in
            if case .object(let object) = block { return object } else { return nil }
        }
        if case .bool(let isError)? = result["isError"] { return (blocks, isError) }
        return (blocks, false)
    }

    private func text(_ block: [String: JSONValue]?) -> String {
        if case .string(let text)? = block?["text"] { return text }
        return ""
    }

    func testScreenshotStatesItsGeometryBeforeTheImage() throws {
        capture.captureResult = try XCTUnwrap(makePNG(width: 820, height: 1796)).base64EncodedString()
        let reply = call("screenshot", ["settle_ms": .number(0)])
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.content.count, 2)
        XCTAssertTrue(text(reply.content.first).hasPrefix(
            "Screenshot: 820x1796 px showing the whole 410x898 pt window (2 px per point)."))
        XCTAssertEqual(reply.content.last?["type"], .string("image"))
    }

    func testScreenshotOfARegionNamesTheRegion() throws {
        capture.captureResult = try XCTUnwrap(makePNG(width: 820, height: 1796)).base64EncodedString()
        let reply = call("screenshot", [
            "settle_ms": .number(0),
            "region": .array([.number(100), .number(200), .number(200), .number(300)]),
            "scale": .number(0.5),
        ])
        XCTAssertFalse(reply.isError)
        XCTAssertTrue(text(reply.content.first).contains(
            "200x300 px showing window points x 100-300, y 200-500"), text(reply.content.first))
        XCTAssertTrue(text(reply.content.first).hasSuffix(
            "image_size [200, 300] and image_region [100, 200, 200, 300]."))
    }

    func testAnImagePointIsConvertedToWindowPoints() {
        let reply = call("tap", [
            "x": .number(410), "y": .number(898),
            "image_size": .array([.number(820), .number(1796)]),
        ])
        XCTAssertFalse(reply.isError, text(reply.content.first))
        XCTAssertEqual(input.tapCalls.count, 1)
        XCTAssertEqual(input.tapCalls.first?.x, 205)
        XCTAssertEqual(input.tapCalls.first?.y, 449)
        XCTAssertEqual(text(reply.content.first),
                       "Tapped at (205, 449) (from image point (410, 898) in a 820x1796 image)")
    }

    func testAnImageRegionOffsetsThePoint() {
        let reply = call("tap", [
            "x": .number(100), "y": .number(150),
            "image_size": .array([.number(200), .number(300)]),
            "image_region": .array([.number(100), .number(200), .number(200), .number(300)]),
        ])
        XCTAssertFalse(reply.isError, text(reply.content.first))
        XCTAssertEqual(input.tapCalls.first?.x, 200)
        XCTAssertEqual(input.tapCalls.first?.y, 350)
    }

    /// A capture taller than the window it shows (a frame that includes
    /// chrome): the width gives the scale for both axes, as it does for the
    /// points describe_screen lists.
    func testATallerImageUsesTheWidthScaleOnBothAxes() {
        let point = ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: 410, y: 1000), imageSize: CGSize(width: 820, height: 1900),
            shownRect: CGRect(x: 0, y: 0, width: 410, height: 898))
        XCTAssertEqual(point.x, 205)
        XCTAssertEqual(point.y, 500, "1000 px at 2 px per point, not squeezed into the window's height")
    }

    /// Numbers no integer can hold are refused as out of bounds, not crashed on.
    func testHugeNumbersAreRefusedWithoutTrapping() {
        let huge = JSONValue.number(1e19)
        let cases: [[String: JSONValue]] = [
            ["x": huge, "y": .number(10)],
            ["x": huge, "y": huge, "image_size": .array([.number(820), .number(1796)])],
            ["x": .number(10), "y": .number(10), "image_size": .array([huge, huge])],
        ]
        for args in cases {
            let reply = call("tap", args)
            XCTAssertTrue(reply.isError || input.tapCalls.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        XCTAssertEqual(ScreenshotGeometry.whole(1e19), "10000000000000000000")
        XCTAssertEqual(ScreenshotGeometry.whole(.infinity), "inf")
        XCTAssertEqual(ScreenshotGeometry.whole(204.6), "205")
    }

    func testWithoutImageSizeXAndYArePoints() {
        let reply = call("tap", ["x": .number(120), "y": .number(340)])
        XCTAssertEqual(text(reply.content.first), "Tapped at (120, 340)")
        XCTAssertEqual(input.tapCalls.first?.x, 120)
    }

    func testBadImageArgumentsAreRefusedAndNothingIsTapped() {
        let cases: [([String: JSONValue], String)] = [
            (["x": .number(1), "y": .number(1), "image_size": .array([.number(0), .number(10)])],
             "image_size must be [width, height], both greater than 0"),
            (["x": .number(1), "y": .number(1), "image_size": .string("820x1796")],
             "image_size must be [width, height], both greater than 0"),
            (["x": .number(1), "y": .number(1), "image_size": .array([.number(10), .number(10)]),
              "image_region": .array([.number(1), .number(2)])],
             "image_region must be [x, y, width, height] in window points"),
            (["x": .number(1), "y": .number(1), "image_region": .array([.number(1), .number(2), .number(3), .number(4)])],
             "image_region needs image_size"),
            (["text": .string("OK"), "image_size": .array([.number(10), .number(10)])],
             "image_size needs x and y: it converts a point, not text"),
        ]
        for (args, message) in cases {
            let reply = call("tap", args)
            XCTAssertTrue(reply.isError, message)
            XCTAssertEqual(text(reply.content.first), message)
        }
        XCTAssertTrue(input.tapCalls.isEmpty)
    }
}
