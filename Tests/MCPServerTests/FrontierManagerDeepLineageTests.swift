/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Unit tests for FrontierManager's deep-lineage dequeue priority.
// ABOUTME: Verifies deep-tab subtrees dequeue before FIFO order and that FIFO is untouched without them.

import XCTest
@testable import mirroir_mcp

final class FrontierManagerDeepLineageTests: XCTestCase {

    private func screen(_ fp: String, depth: Int = 1, deep: Bool = false) -> FrontierScreen {
        FrontierScreen(fingerprint: fp, pathFromRoot: [], depth: depth, isDeepLineage: deep)
    }

    /// Without any deep-lineage entries the queue is plain FIFO — the universal
    /// behavior for apps that declare no `## Deep Tabs` section.
    func testFIFOWhenNoDeepLineage() {
        let manager = FrontierManager()
        manager.seed(screen("root", depth: 0))
        manager.enqueue(screen("a"))
        manager.enqueue(screen("b"))
        manager.enqueue(screen("c"))

        let order = (0..<4).compactMap { _ in manager.dequeueNext()?.fingerprint }
        XCTAssertEqual(order, ["root", "a", "b", "c"])
        XCTAssertNil(manager.dequeueNext())
    }

    /// A deep-lineage screen enqueued behind breadth siblings dequeues first.
    func testDeepLineageDequeuesBeforeFIFOOrder() {
        let manager = FrontierManager()
        manager.seed(screen("root", depth: 0))
        manager.enqueue(screen("accueil-child"))
        manager.enqueue(screen("recherche-child"))
        manager.enqueue(screen("profil-child", deep: true))

        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "root")
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "profil-child",
            "Deep-lineage screen must jump the FIFO queue")
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "accueil-child")
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "recherche-child")
    }

    /// A deep child discovered while exploring the deep screen keeps priority
    /// over breadth screens enqueued earlier — the whole subtree explores first.
    func testDeepSubtreeExploresBeforeSiblingBreadth() {
        let manager = FrontierManager()
        manager.seed(screen("root", depth: 0))
        manager.enqueue(screen("breadth-1"))
        manager.enqueue(screen("profil", deep: true))
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "root")
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "profil")

        // Exploring "profil" discovers its settings chain, inheriting lineage.
        manager.enqueue(screen("parametres", depth: 2, deep: true))
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "parametres",
            "The inherited-lineage child must dequeue before older breadth entries")
        XCTAssertEqual(manager.dequeueNext()?.fingerprint, "breadth-1")
    }

    /// Both deep and breadth entries keep their relative discovery order when
    /// deep items jump the queue — the move is an insertion, not a swap.
    func testDeepAndBreadthEntriesPreserveRelativeOrder() {
        let manager = FrontierManager()
        manager.seed(screen("root", depth: 0))
        manager.enqueue(screen("breadth-1"))
        manager.enqueue(screen("deep-1", deep: true))
        manager.enqueue(screen("breadth-2"))
        manager.enqueue(screen("deep-2", deep: true))

        let order = (0..<5).compactMap { _ in manager.dequeueNext()?.fingerprint }
        XCTAssertEqual(order, ["root", "deep-1", "deep-2", "breadth-1", "breadth-2"],
            "Deep entries dequeue first; each group keeps its discovery order")
    }
}
