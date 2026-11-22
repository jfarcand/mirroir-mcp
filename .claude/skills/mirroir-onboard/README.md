# mirroir-onboard

Claude Code Agent Skill that onboards a web consumer repository to
[mirroir](../../../README.md)'s `.mirroir/` dotfile system.

## Install

Project-scoped (this clone of `iphone-mirroir-mcp` only):
```bash
# Nothing to do — Claude Code auto-discovers .claude/skills/* in the cwd.
```

Global (any project on this machine):
```bash
ln -s "$(pwd)/.claude/skills/mirroir-onboard" "$HOME/.claude/skills/mirroir-onboard"
```

## Use

In Claude Code, in the target consumer's repository:

```
/mirroir-onboard
```

Or hand the agent the consumer path explicitly:

```
Onboard /path/to/consumer-repo to mirroir using the mirroir-onboard skill.
```

## What it does

The **web explorer**: drives the consumer's running app via
`mcp__chrome-devtools__*` — derives real selectors from the accessibility
tree, exercises each surface's *primary action* (not just "page renders"),
emits the `.mirroir/` tree, and **validates by live `mirroir-run` replay**,
**self-healing** any selector that doesn't resolve against the real DOM.
The same loop a human would run, mechanized.

See [`SKILL.md`](./SKILL.md) for the full algorithm.

## What it does NOT do

- Replace your mocked suite — mirroir is the *real-stack* complement (it
  catches backend/seed/proxy/auth-gate breakage a mocked suite can't).
- Generate iOS skills (use `mcp__mirroir__generate_skill` instead).
- Author archetypes — the cross-app multiplier, but a separate task
  (see [`runner/docs/archetype-authoring.md`](../../../runner/docs/archetype-authoring.md)).
- Commit anything (it stops after a green replay, awaits your review).
