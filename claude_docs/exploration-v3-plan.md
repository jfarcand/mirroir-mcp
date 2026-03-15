# Exploration v3: Reproducible, High-Coverage UI Exploration

## Diagnosis

Based on deep analysis of the codebase and survey of 25+ academic papers and production tools (APE, Fastbot2, STOAT, Sapienz, LLM-Explorer, LLMDroid, Guardian, VisionDroid, PIRLTest, OmniParser, Maestro).

### Why exploration isn't reproducible

1. **No persistent model** -- every run starts from scratch. The same app is re-discovered every time. Fastbot2 (ByteDance) showed that reusable models across runs are the single biggest efficiency win.
2. **No post-action verification** -- after a tap, we OCR and hope we landed where expected. If an alert, loading screen, or animation intercepts, the exploration diverges silently. Guardian (ISSTA 2024) showed that validation + recovery is essential.
3. **Fingerprint brittleness** -- our structural fingerprint filters timestamps/counters but uses a fixed 0.8 Jaccard threshold. Two screens that differ by one dynamic label can either merge (miss a real state) or split (create phantom states). APE (ICSE 2019) solved this with dynamic abstraction refinement (CEGAR loop).
4. **No seed determinism** -- exploration order depends on OCR confidence scores and component detection scoring, which vary between runs.

### Why exploration doesn't reach 100%

1. **Hard budget limits, no plateau detection** -- we stop at `max_screens=30` or `max_time=300s`, not when discovery has actually stalled. LLMDroid (FSE 2025) showed that monitoring discovery rate and switching strategies at plateau is far more effective.
2. **BFS path replay fragility** -- BFS replays the full path from root to reach each frontier screen. One failed backtrack (OCR misses the back chevron, animation timing off) breaks the entire frontier branch. No recovery.
3. **No scroll exhaustion** -- `scrollLimit=3` during exploration means long lists are partially explored. Elements below fold 3 are invisible.
4. **Tab exploration only at root** -- breadth_navigation (tab bars) is explored once globally but not re-explored when tabs lead to different sub-hierarchies depending on app state.
5. **No precondition handling** -- screens behind login, permissions, or specific data states are unreachable without setup actions.
6. **Lost screens on backtrack failure** -- if backtracking to root fails, the entire remaining frontier is abandoned rather than attempting alternative paths.

## Implementation Phases

### Phase 2: Post-Action Verification & Recovery (Guardian pattern)

After every tap/swipe/backtrack, verify we landed where expected. If not, detect and recover.

**Implementation:**
- After each action, OCR the result and check:
  - Did we land on the expected screen? (fingerprint match against graph prediction)
  - Did an alert/dialog appear? (detect known patterns: "Allow", "Don't Allow", "OK", "Cancel", system alert components)
  - Did we stay on the same screen? (dead tap -- element wasn't tappable)
  - Did the app crash/reset to home? (detect Springboard/home screen)
- Recovery actions:
  - **Alert detected** -> dismiss it (tap "OK"/"Allow"/"Don't Allow"), then re-verify
  - **Same screen** -> mark element as `dead`, try next element
  - **Unexpected screen** -> search graph for matching node, update backtrack stack
  - **App crash** -> relaunch, replay path from root
- Log all recoveries for diagnosis

**Key files:**
- New: `Sources/mirroir-mcp/PostActionVerifier.swift` (enum namespace, pure transformation pattern)
- Modified: `BFSExplorer.swift`, `DFSExplorer.swift` -- wrap each action with verify-and-recover
- Modified: `NavigationGraph.swift` -- add `markEdgeDead()` for dead taps

### Phase 1: Persistent Navigation Model (Fastbot2 pattern)

Save the navigation graph to disk after exploration. Subsequent runs load it, skip known screens, and focus on unexplored edges.

**Implementation:**
- Serialize `NavigationGraph` (nodes, edges, fingerprints) to JSON at session end
- Store in `~/.mirroir-mcp/graphs/<app_bundle_id>.json`
- On `generate_skill(action: "explore")`, load existing graph if present
- Mark edges as `explored` / `unexplored` / `stale` (last verified timestamp)
- BFS frontier is seeded from unexplored edges instead of starting from scratch
- Add `fresh: true` parameter to force clean exploration

**Key files:**
- New: `Sources/mirroir-mcp/GraphPersistence.swift` (protocol in Protocols.swift + concrete implementation)
- Modified: `NavigationGraph.swift` -- Codable conformance, edge status tracking
- Modified: `ExplorationSession.swift` -- load/save lifecycle
- Modified: `GenerateSkillTools.swift` -- `fresh` parameter, graph loading
- Modified: `BFSExplorer.swift` -- seed frontier from persisted unexplored edges

### Phase 6: Full-Page Coverage with Smart Scrolling

Replace fixed scroll limits with content-aware scrolling.

**Implementation:**
- **Scroll exhaustion detection**: compare OCR output before and after scroll. If <10% new elements, stop scrolling (the page is fully revealed)
- **Bidirectional scroll**: scroll up after scrolling down to catch elements above the initial viewport
- **Infinite scroll detection**: if every scroll reveals new content (feeds), cap at N scrolls and mark the screen as `infinite_scroll` in the graph
- **Lazy-load handling**: after scroll, wait for content stabilization (OCR stability check) before recording elements

**Key files:**
- Modified: `CalibrationScroller.swift` -- scroll exhaustion detection, bidirectional scroll
- Modified: `BFSExplorerHelpers.swift` -- use smart scrolling in calibration pipeline
- Modified: `ScreenNode` in `NavigationGraph.swift` -- `isInfiniteScroll` flag
- Modified: `ExplorationBudget.swift` -- remove fixed `scrollLimit`, add `maxScrollsPerScreen` with exhaustion override

### Phase 7: Edge Classification & Smart Backtracking

Classify navigation edges for intelligent backtracking.

**Implementation:**
- Classify each edge after taking it:
  - `push`: new screen pushed onto nav stack (back chevron appears)
  - `tab`: tab bar selection (no back chevron, tab bar persists)
  - `modal`: modal presentation (dismiss button appears, or swipe-down dismisses)
  - `toggle`: same screen, element state changed (switch flipped)
  - `dead`: no visible change (element wasn't interactive)
  - `external`: left the app (Safari opened, App Store, etc.)
- Backtrack strategy per edge type:
  - `push` -> tap back chevron
  - `tab` -> tap previous tab
  - `modal` -> tap dismiss / swipe down
  - `toggle` -> no backtrack needed (same screen)
  - `external` -> relaunch original app
- Store edge types in persistent graph

**Key files:**
- Modified: `NavigationEdge` in `NavigationGraph.swift` -- enum `edgeType` already exists, flesh it out
- New: `Sources/mirroir-mcp/EdgeClassifier.swift` (enum namespace, pure transformation pattern)
- Modified: `DFSExplorerBacktrack.swift` -- use edge type for backtrack strategy selection
- Modified: `BFSExplorer.swift` -- use edge type for return-to-root strategy

### Phase 4: Coverage Plateau Detection & Strategy Switching (LLMDroid pattern)

Monitor discovery rate. When it stalls, switch from systematic BFS to targeted LLM-guided exploration.

**Implementation:**
- Track `new_screens_per_minute` as a rolling window
- Define phases:
  - **Discovery phase** (rate > 1 screen/min): continue systematic BFS
  - **Plateau phase** (rate < 0.5 screen/min for 2+ minutes): switch to LLM guidance
  - **Exhaustion phase** (no new screens for 3+ minutes despite LLM guidance): stop
- In plateau phase, ask the AI vision model (via embacle):
  - "Given these explored screens and these unexplored edges, what action would reach new functionality?"
  - "This screen has elements X, Y, Z that haven't been tapped. Which is most likely to lead to new screens?"
- Score LLM suggestions and try them before resuming systematic BFS

**Key files:**
- New: `Sources/mirroir-mcp/CoverageMonitor.swift` (session accumulator pattern)
- Modified: `BFSExplorer.swift` -- check coverage monitor, switch strategy at plateau
- Modified: `ExplorationBudget.swift` -- replace hard `maxTime` with plateau-based stopping
- New: `Sources/mirroir-mcp/LLMExplorationAdvisor.swift` (protocol abstraction pattern)

### Phase 3: Dynamic State Abstraction (APE/CEGAR pattern)

Replace fixed-threshold fingerprinting with adaptive abstraction that refines when it causes problems.

**Implementation:**
- Start with current structural fingerprint (coarse)
- Track "behavioral equivalence": two screens with the same fingerprint should produce the same set of tappable components
- When they don't (same fingerprint, different component plans), **refine**: add a distinguishing attribute to the fingerprint (e.g., nav bar title, specific label presence)
- When state count explodes (>100 states for a single app), **coarsen**: merge states that always produce identical exploration behavior
- Store refinement decisions in the persistent graph

**Abstraction attributes** (ordered by discriminating power):
1. Sorted structural text elements (current)
2. Nav bar title (already extracted but only used for similarity fast-path)
3. Component detection signature (set of matched component types)
4. Screen zone layout (which zones have content: nav_bar + content + tab_bar vs nav_bar + content)

**Key files:**
- New: `Sources/mirroir-mcp/StateAbstraction.swift` (enum namespace, pure transformation pattern)
- Modified: `StructuralFingerprint.swift` -- pluggable abstraction levels
- Modified: `NavigationGraph.swift` -- refinement/coarsening operations, behavioral equivalence tracking

### Phase 5: Reproducible Exploration Mode

Make exploration deterministic for testing/CI use cases.

**Implementation:**
- Add `seed` parameter to `generate_skill(action: "explore", seed: 42)`
- Seed controls: component plan scoring tiebreakers, scroll timing, element selection order
- **State assertions** in generated skills: after each navigation step, verify expected screen fingerprint
- **Canonical element ordering**: when OCR returns elements at similar Y coordinates, sort by X deterministically
- **OCR stabilization**: wait for N consecutive identical OCR results before proceeding (not a fixed delay)

**Key files:**
- Modified: `GenerateSkillTools.swift` -- `seed` parameter
- New: `Sources/mirroir-mcp/ExplorationRNG.swift` (seeded PRNG wrapper)
- Modified: `ScreenPlanner.swift` -- use seeded RNG for tiebreakers
- Modified: `SkillMdGenerator.swift` -- emit `Verify` assertions in generated skills
- Modified: `ScreenDescriber.swift` -- OCR stabilization loop

## Priority Matrix

| Phase | Effort | Reproducibility Impact | Coverage Impact | Dependencies |
|-------|--------|----------------------|----------------|-------------|
| 2. Post-action verification | Medium | Very High | High (recovery) | None |
| 1. Persistent model | Medium | High (incremental) | High (cumulative) | None |
| 6. Smart scrolling | Low | Low | High | None |
| 7. Edge classification | Medium | Medium | High | Phase 2 |
| 4. Plateau detection | Medium | Low | Very High | Phase 1 |
| 3. Dynamic abstraction | High | Very High | Medium | Phase 1 |
| 5. Reproducible mode | Medium | Very High | Low | Phase 2 |

**Implementation order:** Phase 2 -> Phase 1 -> Phase 6 -> Phase 7 -> Phase 4 -> Phase 3 -> Phase 5

## What "100% Coverage" Actually Means

The literature is unambiguous: 100% coverage of a GUI app is undecidable. You cannot enumerate all states without executing all paths, and some states require preconditions you can't infer (login credentials, specific data, network conditions). Every tool in the literature uses heuristic stopping criteria.

What we should target: **exploration completeness** -- all discovered screens have had all visible interactive elements exercised, and no new screens have been found for N consecutive actions despite LLM-guided attempts. This is measurable, achievable, and useful. We should expose it as a metric:

```
Exploration complete: 47 screens, 312 elements, 89 transitions
Coverage: 94% of discovered elements exercised
Unexplored: 3 elements behind login (Settings > Accounts > Add Account)
```

## Key Academic References

| Paper | Year | Key Technique | Relevance |
|-------|------|--------------|-----------|
| APE (ICSE) | 2019 | CEGAR state abstraction refinement | Phase 3 |
| Fastbot2 (ASE) | 2022 | Reusable navigation models, RL event selection | Phase 1 |
| Guardian (ISSTA) | 2024 | Post-action verification, LLM plan validation | Phase 2 |
| LLMDroid (FSE) | 2025 | Coverage plateau detection, LLM fallback | Phase 4 |
| LLM-Explorer (MobiCom) | 2025 | LLM for knowledge, not actions (148x cheaper) | Phase 4 |
| STOAT (FSE) | 2017 | Stochastic FSM, Gibbs sampling | Phase 3 |
| PIRLTest | 2022 | Image embedding state identity (no accessibility tree) | Phase 3 |
| VisionDroid | 2024 | Vision LLM with bounding box prompting | Phase 4 |
| OmniParser (Microsoft) | 2024 | Interactable region detection | Screen Intelligence |
| Sapienz (ISSTA) | 2016 | Multi-objective search, motif patterns | General |

Full bibliography: See research agent output in conversation history.
