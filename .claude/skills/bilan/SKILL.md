---
name: bilan
description: Measure whether this session actually finished — the 0-10 completion number, computed from git, the carnet ledger, LIMITATION markers and CI instead of narrated. Use before reporting a completion number, when asked "where are we", at the end of a piece of work, and to find what a session that died left behind.
argument-hint: "[sweep] [--cheap] [--json]"
user-invocable: true
---

# Bilan

**The completion number is this script's number, never yours.**

The incident history quoted below (carnet#236, carnet#406, carnet#493, …) happened in the
dravr-* family, where this skill was built; those numbers are in `dravr-ai/dravr-carnet`, not in
this repo's register.

It used to be narrated: it came from my account of the session, so a session that *believed* it
was done reported 8 or 10 while it still held open carnet issues, had commits sitting unpushed,
or had left a background task running. Every one of those facts is machine-checkable, and
`bilan.sh` checks them.

```bash
.claude/skills/bilan/bilan.sh            # full: local facts + one CI query
.claude/skills/bilan/bilan.sh --cheap    # local only, no network
.claude/skills/bilan/bilan.sh sweep      # what a session that DIED left behind
```

Exit code: `0` = 10/10 · `1` = incomplete · `2` = the script itself failed.

**`--cheap` and the full run give the same number.** CI is printed, never scored (below), so
skipping it changes what is shown, not the score — and every other check answers from local
evidence in both modes. `--cheap` is the form a hook or a status line runs, which is why that
has to hold: a check that only the full run can pass would hold every cheap reading below it for
as long as the condition stands.

## The rules

1. **Run it before you give a number.** Report the score it prints. If you believe a cap is
   wrong, say so in words *and still report the script's number* — arguing with the measurement
   is a conversation, overriding it silently is the failure this exists to stop.
2. **A cap is a fact, not an opinion.** Each one prints its own evidence and its own remedy.
   The score is `min()` over the caps, so one open carnet issue holds the whole session at 6 no
   matter how much else landed.
3. **Failures never deduct.** A red that is now green, a mistake found and fixed, a rough path —
   none of it lowers the number. The score measures *completion*, and only completion.
4. **Friction is printed, never scored.** Tool errors, interrupts and denials are counted from
   the transcript and shown for context. They do not cap anything.

## What caps the score

| Evidence | Caps at |
|---|---|
| carnet issue claimed by this session, neither closed nor released | **6** |
| carnet issue **filed** by this session and still open (unless a registered limitation) | **6** |
| background task or subagent still running | **7** |
| `LIMITATION(registre#…)` marker added in source naming no live issue | **6** |
| tracked files modified and uncommitted | **7** |
| commits not pushed | **8** |
| todo still `pending` or `in_progress` | **7** |
| nothing measurable — no commit, no todo | **9** |
| untracked files, stash created this session, branch whose upstream is gone | **9** |
| `.git/validation-passed` missing, stale, or for another sha (`runner/scripts/ci/pre-push-validate.sh` stamps it) | **9** |

## Uncommitted files that are not this session's

Several sessions share the main checkout. In bilan's first hour, a peer's mid-edit files held
**three** other sessions at 7 — and those sessions were right to refuse to touch them, so they
could not reach 10 no matter what they did. That was a category error: the score measures *this
session's* completion, and a peer's in-flight file is not this session's incompleteness.

Two mechanisms fix it, and the first needs nothing from you.

**The baseline.** The SessionStart hook records which tracked files were already dirty when the
session opened. A path dirty before the session existed is definitionally not its work — that
much *is* machine-decidable. Those files are stated as a note and never scored.

**`ack`, for what goes dirty afterwards.** A peer editing during your session is not covered by
the baseline, so you say so once:

```bash
bilan.sh ack --why "a peer's embacle pin bump, written into this shared checkout at 10:16"
```

That **clears** the cap rather than softening it, and carries the reason into every later
report. It is keyed to the exact set of paths, so dirtying one more file brings the cap
straight back, and ownership is a property of the files rather than their contents, so a peer
changing those same files again stays covered.

**Why not attribute automatically?** It was tried and it does not work. Claude Code records the
paths a session touched under `file-history-snapshot.trackedFileBackups`, but only for the
Edit/Write tools. Sessions here work Bash-first, and that map came back **empty** for a session
that had just written nine files. Attributing on it would have called a session's own work a
peer's and stopped blocking — the worst direction to be wrong in.

Two other caps deserve a note. **CI absence is its own outcome** — `gh run list --commit` returns
zero rows on this org even when runs exist, so rows are matched by `headSha` out of a wide branch
window, and a sha with no row reads as *absent, not necessarily done*, never as green. And a
**peer's worktree is not yours**: cross-checkout state is reported by `sweep`, never as a cap on
your score.

## The two call sites

**`/bilan`** — on demand, the full measurement including CI.

There is deliberately no Stop gate. dravr-platform ran one that refused a stop while the score
was 8 or below, and disarmed it on 2026-09-09: it once graded every session in a shared worktree
on one peer's red CI and blocked all of them over a commit none of them made. A wrong number
costs a paragraph; a wrong number that can *stop the session* costs a night.

**The startup sweep** (`hooks/session-start-sweep.sh`) — the only cover for a session that was
killed. A `kill -9`, a closed terminal or an exhausted context fires no exit hook, so the dead
session can never report on itself; the next session in the repo looks for it instead, across
every worktree and every ledger on the machine. It found `carnet#236`, held by a session that
died on 2026-09-03, five days after the fact.

## Work that leaves no trace

Two kinds of incompleteness are invisible to git, the ledger and CI, and both have produced a
false 10:

**Background tasks and subagents.** Claude Code writes each one's stream to
`<scratchpad>/<session-id>/tasks/<id>.output` and closes it with `[exited with code N]` or
`[killed]`; no marker and a live holder means it never ended. The path carries the session id,
so ten terminals are ten separate answers — a session is only ever accountable for its own.
Closing a session with one running throws that work away, so it caps at **7**. bilan runs *inside* one of those streams itself, so a file held by anything in its own
process ancestry is this invocation, not a task.

**Issues the session filed.** `carnet.sh create` writes a `filed` line to the ledger and
`close` removes it, so what remains is what this session opened and did not fix. That caps at
**6** — level with an issue still held, because filing instead of fixing is the same unfinished
work wearing a label. The standing rule is *fix first, file only the residue*; if something
genuinely cannot be fixed here, that is a decision to put in front of ChefFamille, not a cap to
slip past.

**Except a registered limitation, which is the one filed issue that is not work owed.** The
LIMITATION procedure *requires* an open issue for as long as a marker names it, so this cap
punished a session for obeying it — and there was nothing the session could do, because the fix
is to close an issue the rules say must stay open. carnet#406 held a session at 6 for hours on
2026-09-11: keyword narrowing of the tool surface had been deleted for starving a turn, a
classifier was rejected for failing the same way, static narrowing was already done and the tools
are provider-agnostic. Nothing to fix, and nothing honest to close.

So the exemption needs **both** halves: the issue carries the `limitation` label, *and* a
`LIMITATION(registre#n)` marker names that issue **in a file the register scans**. A label alone
still caps, so a bug cannot be relabelled out of the score; a marker naming a dead issue is
already caught by the marker check from the other side. Both together mean the issue is a
register entry rather than deferred work, and it prints as a **note** — the gap stays visible
instead of disappearing into a clean pass, which is the entire point of registering it.

**Where a marker counts is the register's decision, not bilan's.** bilan asks
`.registre/limitation-gates.sh --list-files`, which prints the files the gates
scan: the directories `registre.toml` declares in `scan_dirs`, the configured extensions, minus
test, bench, example and generated trees. bilan used to keep its own copy of those exclusions; it
drifted from the gate's both ways, and a marker one tool honoured was invisible to the other. A
test tree is outside both, so a gap in test *coverage* is marked on the production item that goes
uncovered — carnet#493's marker sits on `assemble_prompt_and_messages`, not on the eval driver
that fails to call it. If the gate is missing, a session that wrote a marker caps at 6 (it cannot
be verified) and every other session is unaffected.

**Both halves are local, so `--cheap` credits it too.** The full run reads the label from the
tracker. `--cheap` reads the line `carnet.sh` writes to the session ledger when it applies the
label — `create --label limitation` or `label <n> +limitation` — and removes on `-limitation`.
A label applied any other way (the web UI) reaches only the full run.

## When there is nothing to measure

A score of 10 means *everything I checked is done*. When nothing was checkable, 10 means nothing
at all — and that is how a session reported 10/10 with its artifact unwritten. bilan reads the
repo, the register and CI; a session whose work is research, a design, a document or a published
artifact touches none of the three, so every check came back clean because every check came back
empty.

So a session that made no commit and declared no todo caps at **9**, labelled *nothing
measurable*. It caps rather than blocks, because answering a question really is a complete
session; what it must not do is issue a verdict it never earned. Declaring the work as a todo,
or committing something, makes it measurable again.

The verdict is measured against an ask, so it waits for one. A status line renders before the
first prompt arrives, and until this was gated every session opened at "9/10 nothing measurable"
for having done nothing in its first second. A session nobody has asked anything of scores clean.

Every report also carries the **ask**, verbatim: `asked:` is the latest prompt ChefFamille
typed, and `opened:` the first, when they differ. bilan cannot judge whether the work satisfies
it — that would be narration again, the thing it exists to treat — but it can refuse to let a
session claim completion without the request in view. The latest counts because a long session is
not what it opened with: one that opened on "Another session reported" and shipped four fixes
reported under those words. A scheduled wakeup, a task notification or a peer message is text the
session or the harness wrote, not an ask, and the transcript marks it so.

## CI, and one thing it cannot see

**CI is printed, never scored.** A shared checkout has one HEAD and ten sessions, all committing
as the same author, so whose commit the tip is cannot be recovered from git. Attributing it was
tried twice and misfired onto other people both times — capping the whole fleet at 5 over one
peer's red, then grading a session on a peer's tip that landed after its own push. There is no
third attempt: the verdict is shown, the number stays about work the session can act on.

**Background work is scanned in `<scratchpad>/<session-id>/tasks/` only.** A session reported a
live CI monitor that bilan did not count, and whether a Monitor writes there has not been
confirmed. Treat the running-work cap as covering background Bash tasks; it may not see every
kind of in-flight work, and a session that knows it has one should say so rather than trust the
absence of a cap.

## What it does not do

It cannot tell you whether the work is *good*, only whether it is *finished*. A green bilan on
a wrong implementation is still a wrong implementation — that is what `/code-review` is for.

It cannot see a deliverable the session never declared. A todo, a commit or an issue makes work
visible to it; an artifact written and published with none of those does not. The *nothing
measurable* cap is how it says so out loud instead of scoring an empty check clean.
