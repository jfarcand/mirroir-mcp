---
name: carnet
description: Work the private register (mirroir-carnet) from a session — claim an issue before touching it so peers see who holds it and which session, release or close it when done, file new issues in the one canonical shape. Use whenever an issue number is mentioned, when you start or stop work that an issue tracks, or when you are about to run gh issue against the tracker.
argument-hint: <claim|release|status|mine|create|close|label> [args]
user-invocable: true
---

# Carnet

The register is shared by every repo of the product (registre.toml names it) and by many
Claude Code sessions at once. Nothing on an issue says a session is on it, so peers collide: the same
design was built twice ~35 minutes apart on 2026-08-31, and carnet#197 was found and written
up independently by two sessions. A **claim** fixes that. It is three native GitHub facts
that move together:

| Carrier | Meaning |
|---|---|
| assignee | the human accountable (gh login) |
| label `in-progress` | a live session holds the issue |
| newest `carnet-claim` marker comment | **which** session — id, name, user, host, pid, repo, branch, time |

One script does everything: `.claude/skills/carnet/carnet.sh`.

The incident history quoted in this skill (carnet#197, carnet#279, carnet#436, …) happened in
the dravr-* family, where it was built; those numbers are in `dravr-ai/dravr-carnet`.

Never run `gh issue` against the tracker by hand — the script is the one path that keeps the
three carriers consistent and the title shape uniform.

## The rules

1. **Claim before the first edit — and it now happens without you.** The PreToolUse hook
   claims every issue the prompt named as soon as you touch a write tool, so an issue you
   were told about is held before your first edit lands. Run `claim <n>` yourself when the
   number never appeared in a prompt (you found the issue by searching, or you are picking up
   work mid-session). Not after the commit: a claim made after the work is done protects
   nobody.
2. **A refusal is a peer, not an obstacle.** Exit code 2 means another *live* session holds
   the issue, or a session on another host does. Tell the user who and which session, and
   stop. The auto-claim hook enforces this once: it blocks your first edit and names the
   holder. It does not block again — after that you are accountable, not the hook. Do not `--steal` on your own judgement — stealing is the user's call, and the
   stolen-from session is warned on the issue.
3. **Release when you stop, close when it is fixed.** `release <n>` when you abandon or hand
   off; `close <n> --why "…" --commit <sha>` when the work landed. Both drop the label and
   the assignee and post a marker. A session that ends still holding claims is released by
   the SessionEnd hook, so a forgotten release is not fatal — but do not rely on it.
4. **Every close says why.** `--why` is mandatory and is what the next reader sees first.
   Add `--commit <sha>` whenever a commit resolved it: `carnet#N` in a commit message is
   plain text to GitHub and never closes anything cross-repo.
5. **File through `create`.** It reads the tracker from `registre.toml`, refuses a public
   tracker, prefixes the title `[<project>] `, and always adds the project label. Titles are
   `[<project>] <Thing>` — one shape, no variants, capitalised first word unless it is an
   identifier. The `limitation` label goes only on an issue that a `LIMITATION(registre#n)`
   marker in source will point at; plain findings get the project label alone.

## Commands

```bash
C=.claude/skills/carnet/carnet.sh

$C claim 197                      # hold it: assign me, label, marker comment, local ledger
$C claim 197 --steal              # take it from a live or remote session — user's decision only
$C release 197 --reason "handed to i18Guards"
$C status 197                     # who holds it, is that session alive, which branch
$C status                         # every in-progress issue in the tracker
$C mine                           # what this session holds (no API call); --verify to check the tracker
$C create --title "Tier 1e is blind to a symbol move" --label bug --body-file /tmp/body.md --claim
$C close 197 --why "Tier 1e-move greps the old path" --commit 8720f8343
$C label 197 +critical -bug
```

Add `--dry-run` to any of them to see the `gh` calls without making them.

## What the hooks do for you

- **UserPromptSubmit** (`hooks/prompt-status.sh`): when a prompt names `carnet#N`,
  `registre#N`, or a carnet issue URL, one status line per issue lands in your context
  before you answer — `carnet#197 · held by @jfarcand · session i18Guards (a3f9c2d1) on 1Q84
  [running] · feature/i18n-guards · since …`. Read it. If it says `unclaimed`, claim before
  editing. If it says `[session ended — stale]`, a plain `claim` takes it over. A peer
  message or a background task result gets the status line **plus a note saying it armed
  nothing** — see *A peer naming an issue is not assigning it* below.
- **PreToolUse** (`hooks/auto-claim.sh`): claims those issues for you, on the first
  write-shaped tool call after the prompt that named them. Reading is not working — a
  question about an issue never reaches a write tool and never claims. A `Bash` call counts
  as an edit only when the command looks like one (a redirect into a file, `sed -i`, `mv`,
  `git commit`, …), because a session that edits through bash would otherwise never claim.
  If a live peer holds the issue it blocks that one tool call and names them. Before
  claiming it asks the transcript **who wrote the prompt** that named the issue: a
  `/loop` or ScheduleWakeup re-fire is text the model wrote for itself, and a peer message
  or task result is text no human wrote, so a list armed by any of those claims nothing and
  prints `carnet: NOT claimed — carnet#N came from a scheduled wakeup …` instead. Take it
  deliberately if it is yours: `carnet.sh claim <n>`.
- **SessionEnd** (`hooks/session-end-release.sh`): releases everything this session still
  holds, from its ledger under `$CLAUDE_CONFIG_DIR/carnet-claims/`. Zero calls when nothing
  is held.

All three are wired in the consumer repo's `.claude/settings.json`; the snippet is at the top
of each hook file. The auto-claim hook costs one `stat` when nothing is pending, which is
almost always — it runs before every edit in every session.

**What it deliberately does not do.** It never claims from a prompt alone, so asking about an
issue is free. It never steals. It forgets a pending list an hour old, so an issue mentioned
long ago is not claimed by an unrelated edit. It never claims from a peer message, a
background task result, or a wakeup prompt the session scheduled for itself. And it never
blocks twice for the same issue: a permanent block would deadlock a session over an issue that
was only mentioned in passing.

**A wakeup you write is not an assignment you received.** When you schedule a wakeup
(`/loop`, `ScheduleWakeup`), the prompt that comes back is yours, and the hooks now know it:
the prompt hook cannot tell at submit time (Claude Code 2.1.276 sends no `source` yet and the
transcript entry is written after the hook runs), so it records the prompt id, and the claim
hook reads that entry — `promptSource: "system"`, `isMeta: true`, `scheduledTaskId` — before
claiming. dravr-platform-7f (2026-09-18) wrote "comment the eight coach_id strings on
carnet#436" into its own wakeup and held #436 for 67 minutes, ChefFamille never having typed
the number. Do not put issue numbers into a wakeup prompt as a to-do list for yourself; and
if you are told a claim was refused because the prompt was a wakeup, that is the hook working.

## A peer naming an issue is not assigning it

Sessions message each other, and many of them are working on something else entirely — another
repo, another product, a goal that has nothing to do with the register. When one of those is
asked a question, the whole correct answer is **to answer it**. Do not claim the issue the
sender mentioned, do not assign it to yourself, do not comment on it, do not start fixing it.
If the message does not concern you, one line saying so is a complete reply.

That is now enforced, not just asked for. A peer message arrives in the prompt hook as
`<cross-session-message from="…">`, and a background result as `<task-notification>` — both
byte-identical to something the user typed. They used to arm the claim list, and it went wrong
in both directions:

| | what happened |
|---|---|
| **false claim** | `carnet#279` was claimed 31s after a peer wrote *"do **not** put my point 1 in carnet#325"*; `#321` two minutes after a peer replied *"Not mine."*; `#261` 25s after a peer retracted a diagnosis. Three issues assigned — label, assignee and marker comment — to sessions that were never going to work them. |
| **false block** | one FYI (*"I hold carnet#323, stay off these files"*) blocked a tool call in six separate sessions, each told *"Do not do this work twice"* about work it had never started. Two were obstaque sessions — a different product. |

Both vectors now print the status line and arm nothing: knowing who holds `#323` is exactly
what you need in order to answer the sender, and a peer cannot redirect your session's claim
onto an issue it happened to mention. Taking work a peer hands over is still fine — it is just
explicit now: `carnet.sh claim <n>`.

**When you are the sender**, say which of the three you mean, in the first line:

| Intent | Write it as |
|---|---|
| FYI, no action | `FYI only — I hold carnet#N and am editing <files>. Nothing for you to do; ignore if you are in another repo.` |
| A question | `Question, no action on the issue: <question>. carnet#N is mine and stays mine.` |
| A real handoff | `Handing off carnet#N — I have released it. If you take it, claim it first.` |

The first line is all the recipient's human sees as a preview, and it is what stops an
unrelated session from adopting your work out of helpfulness.

## How liveness is decided

Claude Code writes `sessions/<pid>.json` under the config dir for every running session and
removes it on exit. A claim on this host is **running** when that file exists with the same
session id and the pid answers `kill -0`; otherwise it **ended** and `claim` takes it over
with a "took over" line. A claim from another host cannot be checked, so it is refused
without `--steal`. Outside Claude Code (`session=manual`) a claim is advisory: it records the
human, and nothing auto-releases it.

## Where things are

| | |
|---|---|
| Tracker | `registre.toml` → `tracker` (mirroir: `jfarcand/mirroir-carnet`, PRIVATE) |
| Title prefix | `[<project>]` — `registre.toml` → `project` (`mirroir-mcp`), else the repo name from `origin` — never the checkout's basename, which in a worktree is the branch |
| Ledger | `${CLAUDE_CONFIG_DIR:-~/.claude}/carnet-claims/<session-id>.jsonl` |
| Tests | `.claude/skills/carnet/test.sh` — stub `gh`, every refusal path fires |

## Related

- `register-limitation` files its issue through `create --label limitation`, then writes the
  `LIMITATION(registre#n):` marker.
- An open decision in a plan or audit is filed the same way — one issue per decision, so each
  gets its own close.
