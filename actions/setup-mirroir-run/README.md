# setup-mirroir-run

A GitHub Action that installs [`mirroir-run`](../../runner/README.md), the CLI
that replays mirroir scenarios against web (Playwright), process, and HTTP
targets, on a GitHub Actions runner.

The action:

1. Resolves the release. `latest` means the highest published, non-prerelease
   `runner-v*` release of `jfarcand/mirroir-mcp`. The repository's own
   "latest" release is the Swift MCP server, so the action does not use it.
2. Downloads the archive for the runner's OS and architecture.
3. Verifies the archive against the `.sha256` file the release publishes next
   to it.
4. Installs the binary into the runner tool cache and adds it to `PATH`.
5. Fails the step unless `mirroir-run --version` reports the expected version.

## Usage

```yaml
jobs:
  scenarios:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: jfarcand/mirroir-mcp/actions/setup-mirroir-run@main
        id: mirroir
        with:
          version: latest        # or an exact version: 0.4.0

      # Walks up to the nearest .mirroir/mirroir.yaml and replays its samples.
      - run: mirroir-run
```

To get reproducible CI, pin both the action ref and `version`.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `version` | `latest` | `latest`, or an exact `MAJOR.MINOR.PATCH`. `v0.4.0` and `runner-v0.4.0` also work. |
| `github-token` | `${{ github.token }}` | Token for the release API calls and downloads. The default job token works for the public release. |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The installed version without a leading `v`, e.g. `0.4.0`. |
| `path` | Absolute path of the installed `mirroir-run` executable. |

## Supported runners

| `runner.os` / `runner.arch` | Release target |
|-----------------------------|----------------|
| Linux / X64 | `x86_64-unknown-linux-musl` (static, so it does not depend on the runner's glibc) |
| macOS / ARM64 | `aarch64-apple-darwin` |
| macOS / X64 | `x86_64-apple-darwin` |
| Windows / X64 | `x86_64-pc-windows-msvc` |

On any other platform the step fails and names the supported list. There you
can install from source with `cargo install mirroir-run`.

The GitHub CLI (`gh`) must be on `PATH`. GitHub-hosted runners include it.

## Web targets need Playwright

`mirroir-run` turns web steps into a Playwright `.spec.ts` and runs it with
`npx playwright test`. This action installs only the binary. Jobs that run web
scenarios also need Node, `@playwright/test`, and the browsers, all under
`$MIRROIR_PLAYWRIGHT_HOME`. This repository's CI sets those up with its own
composite action:

```yaml
env:
  MIRROIR_PLAYWRIGHT_HOME: ${{ github.workspace }}/.mirroir-pw

steps:
  - uses: jfarcand/mirroir-mcp/actions/setup-mirroir-run@main
  - uses: jfarcand/mirroir-mcp/.github/actions/setup-playwright@main
    with:
      browsers: chromium
```

For the details of how `MIRROIR_PLAYWRIGHT_HOME` is used, see
[runner/docs/playwright-setup.md](../../runner/docs/playwright-setup.md).

Process and HTTP targets do not need Playwright.

## Other ways to install

- Homebrew: `brew install jfarcand/tap/mirroir-run`
- crates.io: `cargo install mirroir-run`
