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
// ABOUTME: End-to-end proof that a `requires_clean_boot` scenario gets its own boot in a boot_once sample.
// ABOUTME: Each boot appends a line to boots.txt; the count shows when the shared session was and was not reused.

use std::error::Error as StdError;
use std::fs;
use std::path::Path;
use std::result::Result as StdResult;
use std::time::Duration;

use tempfile::TempDir;
use tokio::time::sleep;

use super::run_sample;
use crate::oracle::baseline::BaselineMode;
use crate::oracle::thresholds::DRIFT_DEFAULTS_FILE;
use crate::replay::ReplayRoots;
use crate::scenario_set::ScenarioSet;

type TestResult = StdResult<(), Box<dyn StdError>>;

/// How long a boot gets to append its line before the count is read.
const BOOT_LOG_WAIT: Duration = Duration::from_secs(5);

fn write_sample(dir: &Path, scenarios: &[(&str, bool)]) -> TestResult {
    let must_pass = scenarios.iter().fold(String::new(), |mut list, (name, _)| {
        list.push_str("      - scenarios/");
        list.push_str(name);
        list.push_str(".yaml\n");
        list
    });
    let sample = format!(
        "# Clean boot\n\n```yaml\nversion: 1\nname: clean-boot\nsession:\n  boot_once: true\n  boot:\n    command: \"sh -c 'echo boot >> boots.txt; exec sleep 60'\"\n    cwd: \".\"\n  scenarios:\n    must_pass:\n{must_pass}```\n"
    );
    fs::write(dir.join("SAMPLE.md"), sample)?;
    fs::write(dir.join("fixture.txt"), "ready")?;
    fs::write(
        dir.join(DRIFT_DEFAULTS_FILE),
        "version: 1\nfingerprint_similarity: { min: 0.85 }\n",
    )?;
    fs::create_dir_all(dir.join("scenarios"))?;
    for (name, clean) in scenarios {
        let clean_key = if *clean {
            "requires_clean_boot: true\n"
        } else {
            ""
        };
        let scenario = format!(
            "version: 1\nname: {name}\n{clean_key}steps:\n  - http:\n      method: GET\n      url: \"file://${{MIRROIR_SAMPLE_DIR}}/fixture.txt\"\n      expect_body_contains: [\"ready\"]\n"
        );
        fs::write(dir.join("scenarios").join(format!("{name}.yaml")), scenario)?;
    }
    Ok(())
}

async fn boots_after_run(
    scenarios: &[(&str, bool)],
    expected: usize,
) -> StdResult<usize, Box<dyn StdError>> {
    let dir = TempDir::new()?;
    write_sample(dir.path(), scenarios)?;
    let roots = ReplayRoots {
        skills: None,
        baselines: BaselineMode::Compare,
    };
    run_sample(dir.path(), ScenarioSet::MustPass, roots).await?;
    let log = dir.path().join("boots.txt");
    let mut waited = Duration::ZERO;
    loop {
        let count = fs::read_to_string(&log).map_or(0, |text| text.lines().count());
        if count >= expected || waited >= BOOT_LOG_WAIT {
            return Ok(count);
        }
        sleep(Duration::from_millis(100)).await;
        waited += Duration::from_millis(100);
    }
}

#[tokio::test]
async fn scenarios_share_one_boot_without_requires_clean_boot() -> TestResult {
    let boots =
        boots_after_run(&[("first", false), ("second", false), ("third", false)], 1).await?;
    assert_eq!(boots, 1, "a boot_once sample boots once");
    Ok(())
}

#[tokio::test]
async fn a_clean_boot_scenario_gets_its_own_boot_and_the_rest_a_fresh_shared_one() -> TestResult {
    let boots = boots_after_run(
        &[("first", false), ("destructive", true), ("third", false)],
        3,
    )
    .await?;
    assert_eq!(
        boots, 3,
        "shared boot, the clean scenario's own boot, then a fresh shared boot"
    );
    Ok(())
}
