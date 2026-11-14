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
// ABOUTME: Walk-up cwd discovery of `.mirroir/mirroir.yaml` — the entry point for bare `mirroir-run`.
// ABOUTME: Bounded by filesystem root; never follows symlinks above the starting cwd.

use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::mirroir::error::MirroirError;

/// Filename of the config inside `.mirroir/`.
pub const CONFIG_FILE: &str = "mirroir.yaml";

/// Filename of the optional local-override file inside `.mirroir/`.
pub const LOCAL_OVERRIDES_FILE: &str = "mirroir.local.yaml";

/// Directory name of the consumer-side mirroir tree.
pub const MIRROIR_DIR: &str = ".mirroir";

/// Walk upward from `start` looking for `<ancestor>/.mirroir/mirroir.yaml`.
///
/// Returns the resolved config path (not just the ancestor directory). The walk
/// stops at the filesystem root. Symlinks within the walked tree are followed
/// by the underlying filesystem APIs; the discoverer itself does not navigate
/// across symlinks beyond what `Path::parent` produces.
///
/// # Errors
///
/// Returns [`MirroirError::ConfigNotFound`] when no ancestor contains the
/// expected file. The error captures the starting directory for diagnostics.
pub fn discover_mirroir_config(start: &Path) -> Result<PathBuf> {
    let mut current = start.to_path_buf();
    loop {
        let candidate = current.join(MIRROIR_DIR).join(CONFIG_FILE);
        if candidate.is_file() {
            return Ok(candidate);
        }
        if !current.pop() {
            // pop() returned false → we were already at the root.
            return Err(MirroirError::ConfigNotFound {
                searched_from: start.to_path_buf(),
            }
            .into());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::fs;
    use std::result::Result as StdResult;

    use super::*;
    use crate::error::RunnerError;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn finds_config_in_current_directory() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path();
        let mirroir_dir = project.join(MIRROIR_DIR);
        fs::create_dir(&mirroir_dir)?;
        let config = mirroir_dir.join(CONFIG_FILE);
        fs::write(&config, "version: 1\nplan: {}\n")?;

        let found = discover_mirroir_config(project)?;
        assert_eq!(found, config);
        Ok(())
    }

    #[test]
    fn finds_config_in_parent_directory() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path();
        let mirroir_dir = project.join(MIRROIR_DIR);
        fs::create_dir(&mirroir_dir)?;
        let config = mirroir_dir.join(CONFIG_FILE);
        fs::write(&config, "version: 1\nplan: {}\n")?;

        let nested = project.join("src").join("deep").join("nested");
        fs::create_dir_all(&nested)?;

        let found = discover_mirroir_config(&nested)?;
        assert_eq!(found, config);
        Ok(())
    }

    #[test]
    fn returns_not_found_when_no_ancestor_has_dir() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let nested = tmp.path().join("a").join("b").join("c");
        fs::create_dir_all(&nested)?;
        match discover_mirroir_config(&nested) {
            Err(RunnerError::Mirroir(MirroirError::ConfigNotFound { .. })) => Ok(()),
            other => Err(format!("expected MirroirConfigNotFound, got {other:?}").into()),
        }
    }
}
