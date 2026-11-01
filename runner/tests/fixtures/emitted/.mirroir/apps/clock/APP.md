# Clock — iOS capture (mirroir-mcp)

The **iOS leg** of this app dir is emitted by mirroir-mcp from an
iPhone Mirroring walk: `generate_skill` (explore, or start/capture/finish),
`save_compiled` (a skill run step by step), or `mirroir-mcp record` (a
hand-driven session). Each `scenarios/<flow>.ios.yaml` is a faithful
**linear** record of the walk, opened by
`target: { kind: ios }`, waiting for each screen a tap reaches.
The emitter owns those files: re-emitting a flow overwrites its
`.ios.yaml`, so record a changed walk rather than edit one by hand.
`mirroir-run` hands that block to
`mirroir-mcp test` on a macOS host with iPhone Mirroring connected, and
refuses it by name on any other host. `SAMPLE.md` declares every flow
under `must_pass`.

To hold the app's **web leg** to the same screen, add this flow's iOS
block to the web scenario and end it with a `cross_surface:` step that
captures both surfaces live — a web `selector` scrape and the iOS
block's final screen — and compares them.

This `.mirroir/` directory is the runner's consumer dotfile, distinct from
the Swift MCP's `~/.mirroir-mcp/` home.