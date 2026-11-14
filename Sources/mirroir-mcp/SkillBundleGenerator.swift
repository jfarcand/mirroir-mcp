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
// ABOUTME: Generates multiple SKILL.md files from a GraphSnapshot by finding interesting paths.
// ABOUTME: Wraps SkillMdGenerator to produce one skill per distinct flow through the app.

import Foundation
import HelperLib

/// A bundle of SKILL.md files produced from a single exploration session.
struct SkillBundle: Sendable {
    /// The app that was explored.
    let appName: String
    /// Individual skills, each representing a distinct flow.
    let skills: [(name: String, content: String)]
    /// Optional markdown manifest indexing all skills (generated when skills.count >= 2).
    let manifest: String?
}

/// Generates a bundle of SKILL.md files from a graph snapshot.
/// Each interesting path through the graph becomes a separate skill.
enum SkillBundleGenerator {

    /// Generate a skill bundle from a graph snapshot.
    /// Falls back to a single skill from the full screen list when the graph
    /// has only one path or no interesting paths.
    ///
    /// - Parameters:
    ///   - appName: The app that was explored.
    ///   - goal: Optional goal description.
    ///   - snapshot: The navigation graph snapshot.
    ///   - allScreens: Complete flat list of screens (fallback for single-path graphs).
    /// - Returns: A SkillBundle with one or more skills.
    static func generate(
        appName: String,
        goal: String,
        snapshot: GraphSnapshot,
        allScreens: [ExploredScreen],
        recipeMatch: RecipeMatch? = nil,
        appDescription: AppDescription? = nil
    ) -> SkillBundle {
        let paths = GraphPathFinder.findInterestingPaths(in: snapshot)

        // If fewer than 2 interesting paths, generate a single skill from the flat list
        guard paths.count >= 2 else {
            let content = SkillMdGenerator.generate(
                appName: appName, goal: goal, screens: allScreens,
                recipeMatch: recipeMatch, appDescription: appDescription
            )
            let name = SkillMdGenerator.deriveName(appName: appName, goal: goal)
            return SkillBundle(appName: appName, skills: [(name: name, content: content)], manifest: nil)
        }

        // Generate one skill per interesting path
        var skills: [(name: String, content: String)] = []
        for path in paths {
            let screens = GraphPathFinder.pathToExploredScreens(
                path: path.edges, snapshot: snapshot
            )
            guard !screens.isEmpty else { continue }

            let pathGoal = path.name
            let content = SkillMdGenerator.generate(
                appName: appName, goal: pathGoal, screens: screens,
                recipeMatch: recipeMatch, appDescription: appDescription
            )
            let name = SkillMdGenerator.deriveName(appName: appName, goal: pathGoal)
            skills.append((name: name, content: content))
        }

        // Fallback if all paths produced empty screen lists
        if skills.isEmpty {
            let content = SkillMdGenerator.generate(
                appName: appName, goal: goal, screens: allScreens,
                recipeMatch: recipeMatch, appDescription: appDescription
            )
            let name = SkillMdGenerator.deriveName(appName: appName, goal: goal)
            return SkillBundle(appName: appName, skills: [(name: name, content: content)], manifest: nil)
        }

        // Generate manifest index when multiple skills produced
        let manifest = skills.count >= 2
            ? SkillManifestGenerator.generate(appName: appName, skills: skills)
            : nil

        return SkillBundle(appName: appName, skills: skills, manifest: manifest)
    }
}
