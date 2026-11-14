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
// ABOUTME: Loads component definitions from the mirroir-skills marketplace repo.
// ABOUTME: Thin wrapper around ComponentLoader for backward compatibility.

import Foundation

/// Loads component definitions from the mirroir-skills marketplace repo.
/// Component definitions live as COMPONENT.md files in `../mirroir-skills/components/ios/`.
enum ComponentCatalog {

    /// All component definitions loaded from the marketplace.
    /// Returns empty array if no COMPONENT.md files are found on disk.
    static var definitions: [ComponentDefinition] {
        ComponentLoader.loadAll()
    }
}
