// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for SkillMdParser: YAML front matter parsing and markdown body extraction.
// ABOUTME: Validates header field extraction, defaults, and edge cases.

import XCTest
@testable import mirroir_mcp

final class SkillMdParsingTests: XCTestCase {

    // MARK: - parseHeader

    func testParseSimpleHeader() {
        let content = """
        ---
        version: 1
        name: Email Triage
        app: Mail
        ios_min: "17.0"
        locale: "en_US"
        tags: ["mail", "workflow", "conditional"]
        ---

        Check inbox for unread email and triage it.

        ## Steps

        1. Launch **Mail**
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.name, "Email Triage")
        XCTAssertEqual(header.app, "Mail")
        XCTAssertEqual(header.iosMin, "17.0")
        XCTAssertEqual(header.locale, "en_US")
        XCTAssertEqual(header.tags, ["mail", "workflow", "conditional"])
    }

    func testParseMissingFields() {
        let content = """
        ---
        name: Minimal Scenario
        ---

        Just a description paragraph.
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.version, SkillMdParser.currentVersion)
        XCTAssertEqual(header.name, "Minimal Scenario")
        XCTAssertEqual(header.app, "")
        XCTAssertEqual(header.iosMin, "")
        XCTAssertEqual(header.locale, "")
        XCTAssertTrue(header.tags.isEmpty)
        XCTAssertEqual(header.description, "Just a description paragraph.")
    }

    func testParseMissingName() {
        let content = """
        ---
        app: Weather
        ---

        Check the forecast.
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "check-weather")
        XCTAssertEqual(header.name, "check-weather")
        XCTAssertEqual(header.app, "Weather")
    }

    func testParseDescriptionFromFrontMatter() {
        let content = """
        ---
        name: With Description
        description: Explicit front matter description
        ---

        This body paragraph should be ignored since front matter has description.
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.description, "Explicit front matter description")
    }

    func testParseDescriptionFromBody() {
        let content = """
        ---
        name: No Description Field
        ---

        Body paragraph becomes the description when front matter has no description field.

        ## Steps

        1. Launch **App**
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.description,
            "Body paragraph becomes the description when front matter has no description field.")
    }

    func testParseNoFrontMatter() {
        let content = """
        This is plain markdown with no front matter.

        ## Steps

        1. Do something
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "plain-scenario")
        XCTAssertEqual(header.version, SkillMdParser.currentVersion)
        XCTAssertEqual(header.name, "plain-scenario")
        XCTAssertEqual(header.description, "This is plain markdown with no front matter.")
    }

    func testParseTagsSingleQuoted() {
        let content = """
        ---
        name: Test Tags
        tags: ['alpha', 'beta', 'gamma']
        ---

        Test.
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.tags, ["alpha", "beta", "gamma"])
    }

    // MARK: - parseBody

    func testParseBody() {
        let content = """
        ---
        version: 1
        name: Test
        ---

        This is the body.

        ## Steps

        1. Do something
        """

        let body = SkillMdParser.parseBody(content: content)
        XCTAssertTrue(body.hasPrefix("This is the body."))
        XCTAssertTrue(body.contains("## Steps"))
    }

    func testParseBodyNoFrontMatter() {
        let content = "Just plain markdown content."
        let body = SkillMdParser.parseBody(content: content)
        XCTAssertEqual(body, "Just plain markdown content.")
    }

    func testParseBodyEmptyAfterFrontMatter() {
        let content = """
        ---
        name: Empty Body
        ---
        """

        let body = SkillMdParser.parseBody(content: content)
        XCTAssertEqual(body, "")
    }

    func testParseMultiParagraphBody() {
        let content = """
        ---
        name: Multi
        ---

        First paragraph.

        Second paragraph.
        """

        let body = SkillMdParser.parseBody(content: content)
        XCTAssertTrue(body.contains("First paragraph."))
        XCTAssertTrue(body.contains("Second paragraph."))
    }

    func testDescriptionStopsAtHeading() {
        let content = """
        ---
        name: Heading Stop
        ---

        First paragraph as description.

        ## Steps

        1. Not part of the description
        """

        let header = SkillMdParser.parseHeader(content: content, fallbackName: "fallback")
        XCTAssertEqual(header.description, "First paragraph as description.")
    }
}
