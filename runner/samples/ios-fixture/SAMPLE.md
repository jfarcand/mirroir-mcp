# iOS fixture — one iOS block against FakeMirroring

The iOS counterpart of `web-fixture`: a scenario whose only surface is a
`target: { kind: ios }` block, run through `mirroir-mcp test` against
FakeMirroring — the stand-in iPhone the integration tests drive. It needs a
macOS host with FakeMirroring running (`.github/actions/setup-fake-mirroring`)
and `mirroir-mcp` found through `MIRROIR_MCP_BIN`; on any other host the plan
refuses the block by name.

`expected/settings-list.txt` is FakeMirroring's Settings list as OCR reads
it. `baselines/settings-list.ios.txt` is written by every run from the live
capture, so it is an output, not a fixture.

```yaml
version: 1
name: ios-fixture
description: |
  One iOS block against FakeMirroring; nothing to boot.
session:
  boot:
    command: "true"
  scenarios:
    must_pass:
      - scenarios/settings-list.yaml
```
