// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ManifestListInsertion — where an item lands in a YAML list, and when it refuses to guess.
// ABOUTME: Covers block scalars, tabs, empty/missing/anchored lists, CRLF, same-indent items, and the readers.

import XCTest

@testable import mirroir_mcp

final class ManifestListInsertionTests: XCTestCase {

    private let entry = ["- name: b"]

    private func insertPlan(_ document: String, items: [[String]]? = nil) -> String? {
        ManifestListInsertion.insert(
            into: document, lines: ManifestListInsertion.wholeDocument(document),
            keyPath: ["plan", "must_pass"], items: items ?? [entry])
    }

    // MARK: - Happy paths

    func testAppendsAfterTheLastItemOfANestedList() {
        let document = "version: 1\nplan:\n  must_pass:\n    - name: a\n      local: apps/a\n"
        XCTAssertEqual(
            insertPlan(document, items: [["- name: b", "  local: apps/b"]]),
            "version: 1\nplan:\n  must_pass:\n    - name: a\n      local: apps/a\n" +
                "    - name: b\n      local: apps/b\n")
    }

    func testInsertsBeforeKeysThatFollowTheList() {
        let document = "plan:\n  must_pass:\n    - name: a\n\n  nice_to_pass:\n    - name: c\nenv: {}\n"
        XCTAssertEqual(
            insertPlan(document),
            "plan:\n  must_pass:\n    - name: a\n    - name: b\n\n  nice_to_pass:\n    - name: c\nenv: {}\n")
    }

    func testAShallowCommentBeforeTheFirstItemIsKept() {
        let document = "plan:\n  must_pass:\n  # apps\n    - name: a\n"
        XCTAssertEqual(insertPlan(document), "plan:\n  must_pass:\n  # apps\n    - name: a\n    - name: b\n")
    }

    func testInsertsIntoTheFencedBlockOfASample() throws {
        let sample = "# App\n\n```yaml\nsession:\n  scenarios:\n    must_pass:\n" +
            "      - scenarios/a.ios.yaml\n```\n\nmust_pass:\n  - prose\n"
        let block = try XCTUnwrap(ManifestListInsertion.fencedYamlBlock(in: sample))
        XCTAssertEqual(
            ManifestListInsertion.insert(
                into: sample, lines: block, keyPath: ["session", "scenarios", "must_pass"],
                items: [["- scenarios/b.ios.yaml"]]),
            "# App\n\n```yaml\nsession:\n  scenarios:\n    must_pass:\n" +
                "      - scenarios/a.ios.yaml\n      - scenarios/b.ios.yaml\n```\n\nmust_pass:\n  - prose\n")
    }

    /// Items written at the key's own indentation are a list YAML accepts;
    /// the entry joins them at that indentation.
    func testItemsAtTheKeysOwnIndentation() {
        let document = "plan:\n  must_pass:\n  - name: a\n    local: apps/a\n  nice_to_pass: []\n"
        XCTAssertEqual(
            insertPlan(document),
            "plan:\n  must_pass:\n  - name: a\n    local: apps/a\n  - name: b\n  nice_to_pass: []\n")
    }

    // MARK: - Block scalars

    /// A `#` line inside the last item's block scalar is content, not a
    /// comment: the entry goes after it, so the boot command keeps it.
    func testABlockScalarEndingInAHashLineKeepsThatLine() {
        let document = """
            plan:
              must_pass:
                - name: a
                  boot:
                    command: |
                      echo hi
                      # keep me

            """
        XCTAssertEqual(insertPlan(document), """
            plan:
              must_pass:
                - name: a
                  boot:
                    command: |
                      echo hi
                      # keep me
                - name: b

            """)
    }

    func testAFoldedScalarWithABlankLineStaysWhole() {
        let document = "plan:\n  must_pass:\n    - name: a\n      note: >\n        one\n\n        # two\n"
        XCTAssertEqual(
            insertPlan(document),
            "plan:\n  must_pass:\n    - name: a\n      note: >\n        one\n\n        # two\n    - name: b\n")
    }

    // MARK: - Refusals

    func testTabIndentationIsRefused() {
        XCTAssertNil(insertPlan("plan:\n\tmust_pass:\n\t\t- name: a\n"))
        XCTAssertNil(insertPlan("plan:\n  must_pass:\n    - name: a\n  \tlocal: apps/a\n"))
    }

    func testAnEmptyListIsRefused() {
        XCTAssertNil(insertPlan("plan:\n  must_pass:\nenv: {}\n"))
        XCTAssertNil(insertPlan("plan:\n  must_pass: []\n"))
    }

    func testAMissingKeyIsRefused() {
        XCTAssertNil(insertPlan("plan:\n  nice_to_pass:\n    - name: a\n"))
        XCTAssertNil(insertPlan("version: 1\n"))
        XCTAssertNil(insertPlan(""))
    }

    func testAnAnchoredKeyIsRefused() {
        XCTAssertNil(insertPlan("plan:\n  must_pass: &apps\n    - name: a\n"))
    }

    func testCRLFLineEndingsAreRefused() {
        XCTAssertNil(insertPlan("plan:\r\n  must_pass:\r\n    - name: a\r\n"))
    }

    func testARepeatedKeyIsRefused() {
        XCTAssertNil(insertPlan("plan:\n  must_pass:\n    - name: a\n  must_pass:\n    - name: c\n"))
    }

    func testAListHoldingAMappingKeyIsRefused() {
        XCTAssertNil(insertPlan("plan:\n  must_pass:\n    - name: a\n    local: apps/a\n"))
    }

    // MARK: - Readers

    func testScalarItemsSkipCommentsAndUnquote() {
        let document = "scenarios:\n  must_pass:\n    # - scenarios/old.ios.yaml\n" +
            "    - scenarios/a.ios.yaml # first\n    - \"scenarios/b.ios.yaml\"\n    - 'c'\n"
        XCTAssertEqual(
            ManifestListInsertion.scalarItems(
                in: document, lines: ManifestListInsertion.wholeDocument(document),
                keyPath: ["scenarios", "must_pass"]),
            ["scenarios/a.ios.yaml", "scenarios/b.ios.yaml", "c"])
    }

    func testScalarItemsReadFlowStyleEmptyAndCRLFLists() {
        func read(_ document: String) -> [String]? {
            ManifestListInsertion.scalarItems(
                in: document, lines: ManifestListInsertion.wholeDocument(document), keyPath: ["list"])
        }
        XCTAssertEqual(read("list: [a, \"b\"] # two\n"), ["a", "b"])
        XCTAssertEqual(read("list: []\n"), [])
        XCTAssertEqual(read("list:\nnext: 1\n"), [])
        XCTAssertEqual(read("list:\r\n  - a\r\n  - b\r\n"), ["a", "b"])
        XCTAssertNil(read("other:\n  - a\n"))
        XCTAssertNil(read("list: &x\n  - a\n"))
    }

    func testMappingValuesReadEachItemsKeyAtItsOwnLevel() {
        let document = "plan:\n  must_pass:\n    - name: web\n      boot:\n        name: inner\n" +
            "    - local: apps/clock\n      name: \"clock\"\n    # - name: gone\n    - local: apps/nameless\n"
        XCTAssertEqual(
            ManifestListInsertion.mappingValues(
                "name", in: document, lines: ManifestListInsertion.wholeDocument(document),
                keyPath: ["plan", "must_pass"]),
            ["web", "clock"])
    }
}
