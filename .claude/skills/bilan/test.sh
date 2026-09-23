#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: Tests for bilan — a throwaway git repo per case, so the caps are exercised for real
# ABOUTME: Run from anywhere: bash .claude/skills/bilan/test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BILAN="$HERE/bilan.sh"
PASS=0
FAIL=0

ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
die()  { printf '\n  💥 %s\n\n' "$1" >&2; exit 2; }

# Every case runs as `( cd "$R" && … )`, and in bash `cd ""` SUCCEEDS — it stays where it is.
# So a fixture path that came back empty did not fail any case: it silently pointed all of them
# at whatever checkout the harness was launched from, and the suite committed to it and tried
# to push it. `mktemp -d -t <prefix>` is what produced that empty path on GNU (BSD invents the
# X's from a bare prefix, GNU refuses it), and `|| exit 1` did not save it either, because
# inside `$(…)` exit leaves only the subshell.
#
# The spelling is fixed in new_repo. This is the belt: no case runs until the path is a real git
# repository of our own making.
require_sandbox() { # <path>
    [ -n "${1:-}" ] || die "fixture repo path is empty — refusing to run the suite against the real checkout"
    [ -d "$1/.git" ] || die "fixture repo '$1' is not a git repository — refusing to run"
    # Matched on the SHAPE new_repo builds, not on a re-derived temp root: TMPDIR is spelled
    # differently on the two platforms and the guard must not be the thing that breaks one.
    case $1 in
        */bilan-test.*/work) : ;;
        *) die "fixture repo '$1' is not one of ours — refusing to run" ;;
    esac
}
# Every case here runs --cheap for speed, and --cheap now carries a standing cap at 9 saying it
# is not a completion verdict. So "clean" is asserted as "no cap other than that one" rather
# than as a score of 10, which cheap can no longer reach by construction.
real_caps() { printf '%s' "$1" | jq '[.caps[]] | length'; }

check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}

# A repo with an origin it can actually push to, so upstream-dependent caps are real.
new_repo() {
    local root remote
    # An explicit template with X's, because `mktemp -d -t PREFIX` is BSD-only:
    # GNU rejects it ("too few X's in template"). That failure was not merely
    # noisy — with no sandbox created, the git commands below ran against the
    # REAL repository and committed to it.
    root=$(mktemp -d "${TMPDIR:-/tmp}/bilan-test.XXXXXX") || return 1
    remote="$root/remote.git"
    git init -q --bare "$remote"
    git init -q "$root/work"
    git -C "$root/work" config user.email t@t.t
    git -C "$root/work" config user.name t
    git -C "$root/work" remote add origin "$remote"
    echo one > "$root/work/a.txt"
    git -C "$root/work" add a.txt
    git -C "$root/work" commit -qm first
    git -C "$root/work" push -q -u origin HEAD:refs/heads/main >/dev/null 2>&1
    git -C "$root/work" branch -q --set-upstream-to=origin/main 2>/dev/null
    git -C "$root/work" fetch -q origin 2>/dev/null   # FETCH_HEAD, or every case reads as stale
    printf '%s' "$root/work"
}

# SessionStart runs this at t=0 against whatever state the checkout is in, so every test that
# measures a change has to establish the starting point first — otherwise the first bilan run
# creates the baseline itself and correctly treats the change as inherited.
baseline_now() { ( cd "$1" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
    bash "$BILAN" baseline >/dev/null 2>&1 ); }

run() { # <repo> [args...]
    local repo=$1; shift
    ( cd "$repo" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
        bash "$BILAN" --cheap --json "$@" 2>/dev/null )
}

CFG=$(mktemp -d "${TMPDIR:-/tmp}/bilan-cfg.XXXXXX") || die "mktemp -d failed for the config dir"
SID="00000000-0000-0000-0000-00000000test"
trap 'rm -rf "$CFG"' EXIT

# Every fixture repo starts with nothing committed by the "session", so any case that also writes
# a transcript would pick up the unmeasured cap alongside the thing it tests. A completed todo
# keeps the harness measurable throughout; the unmeasured case has its own block below, where it
# is the thing under test.
measurable() {
    mkdir -p "$CFG/tasks/$SID"
    printf '{"status":"completed","subject":"harness"}\n' > "$CFG/tasks/$SID/0.json"
}

printf '\nbilan tests\n\n'
measurable

# ---- clean repo scores 10
# The guard runs in a command substitution, so its `exit 2` ends only that subshell and the
# caller sees an empty path — the same shape that once aimed the whole suite at the live
# checkout. `|| exit 2` on the assignment is what carries the refusal into the script.
fixture() {
    local p; p=$(new_repo) || p=""
    require_sandbox "$p"
    printf '%s' "$p"
}

R=$(fixture) || exit 2
baseline_now "$R"
out=$(run "$R")
check "clean repo has no real cap" 0 "$(real_caps "$out")"
# --cheap used to carry a standing cap at 9 because it skipped CI. CI no longer scores at all,
# so both paths give the same number and that cap only penalised the cheap one.
check "--cheap and the full run agree on the number" 10 "$(printf '%s' "$out" | jq -r .score)"
check "no standing cap for skipping CI" 0 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("CI"))] | length')"

# ---- uncommitted tracked change caps at 7
echo two >> "$R/a.txt"
out=$(run "$R")
check "uncommitted tracked change caps at 7" 7 "$(printf '%s' "$out" | jq -r .score)"
check "the evidence names the file" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("a\\.txt"))] | length')"
git -C "$R" checkout -q -- a.txt

# ---- untracked file caps at 9, not 7
touch "$R/stray.md"
out=$(run "$R")
check "untracked file caps at 9" 9 "$(printf '%s' "$out" | jq -r .score)"
check "the untracked evidence names the file" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("stray\\.md"))] | length')"
rm -f "$R/stray.md"

# ---- a commit made after the baseline is this session's, and caps at 8
baseline_now "$R"
echo three >> "$R/a.txt"
git -C "$R" commit -q -am second
out=$(run "$R")
check "unpushed commit caps at 8" 8 "$(printf '%s' "$out" | jq -r .score)"
check "unpushed names the remedy" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.cap==8) | select(.remedy | test("git push"))] | length')"

# ---- validation marker missing is reported alongside the unpushed commit
check "missing validation marker is a cap" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("validation-passed"))] | length')"
git -C "$R" push -q origin HEAD:refs/heads/main

# ---- a held carnet issue caps at 6 and outranks everything else
mkdir -p "$CFG/carnet-claims"
cat > "$CFG/carnet-claims/$SID.jsonl" <<LEDGER
{"v":1,"session":"$SID","name":"test","user":"t","host":"h","pid":1,"repo":"iphone-mirroir-mcp","branch":"main","at":"2026-09-08T00:00:00Z","kind":"identity"}
{"kind":"claim","tracker":"jfarcand/mirroir-carnet","issue":999,"at":"2026-09-08T00:00:00Z"}
LEDGER
out=$(run "$R")
check "held carnet issue caps at 6" 6 "$(printf '%s' "$out" | jq -r .score)"
check "held issue is named in the evidence" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("carnet#999"))] | length')"

# ---- a filed issue caps at 9 and is distinguishable from a held one
printf '{"kind":"filed","tracker":"jfarcand/mirroir-carnet","issue":1000,"at":"2026-09-08T00:00:00Z"}\n' \
    >> "$CFG/carnet-claims/$SID.jsonl"
out=$(run "$R")
# ChefFamille: a session that files an issue must fix it before it stops or claims 10/10.
check "a filed issue caps at 6, level with a held one" 6 "$(printf '%s' "$out" | jq -r .score)"
check "filed is reported separately from held" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("filed this session and still open"))] | length')"
rm -f "$CFG/carnet-claims/$SID.jsonl"

# ---- the register's scope comes from the register
#
# Where a marker counts is llm-registre's decision — scan_dirs in registre.toml, the configured
# extensions, minus test, bench, example and generated trees — and bilan asks
# `limitation-gates.sh --list-files` for it instead of keeping a copy. So these cases run the REAL
# gate, installed into the fixture where a checkout carries it: a stubbed scope would only prove
# bilan agrees with a register that does not exist.
REAL_GATES="$HERE/../../../.registre/limitation-gates.sh"
[ -x "$REAL_GATES" ] || die "llm-registre is not checked out at .registre — git submodule update --init"
command -v rg >/dev/null 2>&1 || die "ripgrep is required: llm-registre scans with it"
mkdir -p "$R/.registre" "$R/src"
cp "$REAL_GATES" "$R/.registre/limitation-gates.sh"
printf 'tracker = "jfarcand/mirroir-carnet"\nscan_dirs = "src,crates"\n' > "$R/registre.toml"
printf 'fn main() {}\n' > "$R/src/lib.rs"
git -C "$R" add -A && git -C "$R" commit -qm "the register" && git -C "$R" push -q origin HEAD:refs/heads/main

# ---- a registered limitation is a register entry, not work owed
#
# The LIMITATION procedure requires an OPEN issue for as long as a marker names it, so a session
# that followed that procedure correctly was capped at 6 for complying, with no action available.
# carnet#406 held a session there for hours on 2026-09-11: keyword narrowing was deleted for
# starving a turn, a classifier was rejected for failing the same way, static narrowing was already
# done — nothing to fix, and nothing honest to close.
#
# The exemption needs the `limitation` LABEL *and* a marker naming that issue in a file the
# register scans. Either half alone still caps, which is what stops a bug being relabelled out of
# the score.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/bilan-gh.XXXXXX") || die "mktemp -d failed for the gh stub"
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
# Smallest gh that can answer the filed-issue path. Every issue is OPEN; only 2001 is labelled
# `limitation`. Anything else (run list, api) fails, so CI reads as absent — which is why the
# assertions below are on the presence of a CAP, never on the score.
want=""
for a in "$@"; do case "$a" in labels) want=labels;; state) want=state;; esac; done
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    case "$want" in
        state)  echo OPEN; exit 0 ;;
        labels) if [ "${3:-}" = 2001 ]; then echo limitation; else echo bug; fi; exit 0 ;;
    esac
fi
exit 1
GH
chmod +x "$STUB/gh"
# Args pass through verbatim: `run_full "$R" --json` for the machine form, `run_full "$R"` for the
# human one. A "${2:---json}" default would have substituted on an EMPTY second argument too, so
# the human call would silently have been a --json call and the note assertion below would have
# passed against output that never contained notes.
run_full() { local repo=$1; shift; ( cd "$repo" && CLAUDE_CONFIG_DIR="$CFG" \
    CLAUDE_CODE_SESSION_ID="$SID" PATH="$STUB:$PATH" bash "$BILAN" "$@" 2>/dev/null ); }
filed_caps() { printf '%s' "$1" | jq '[.caps[] | select(.evidence | test("filed this session and still open"))] | length'; }
IDENTITY="{\"v\":1,\"session\":\"$SID\",\"name\":\"test\",\"user\":\"t\",\"host\":\"h\",\"pid\":1,\"repo\":\"iphone-mirroir-mcp\",\"branch\":\"main\",\"at\":\"2026-09-08T00:00:00Z\",\"kind\":\"identity\"}"

printf '%s\n%s\n' "$IDENTITY" '{"kind":"filed","tracker":"jfarcand/mirroir-carnet","issue":2001,"at":"2026-09-08T00:00:00Z"}' \
    > "$CFG/carnet-claims/$SID.jsonl"

# Label but NO marker — still work owed.
check "a limitation label alone does not exempt a filed issue" 1 "$(filed_caps "$(run_full "$R" --json)")"

# Label AND a marker in scanned source — a register entry.
echo '// LIMITATION(registre#2001): the width this names' >> "$R/src/lib.rs"
out=$(run_full "$R" --json)
check "label plus a marker naming it exempts the filed issue" 0 "$(filed_caps "$out")"
check "and the registered limitation is still REPORTED, not silently dropped" 1 \
    "$(run_full "$R" | grep -c 'carnet#2001 is a registered limitation')"
git -C "$R" checkout -q -- src/lib.rs

# The same marker where the register does not look. Neither the gate nor bilan scans a test
# tree, so a marker there is validated by nothing and must credit nothing: carnet#493 was
# registered on a test harness and sat at 6 until the marker moved to the production function
# the harness fails to cover.
mkdir -p "$R/crates/x/tests"
echo '// LIMITATION(registre#2001): the width this names' > "$R/crates/x/tests/helper.rs"
check "a marker under tests/ does not credit the limitation" 1 "$(filed_caps "$(run_full "$R" --json)")"
rm -rf "$R/crates"

# A marker naming an issue that is NOT labelled `limitation` — still work owed, so a bug cannot
# be exempted by dropping a marker next to it.
echo '// LIMITATION(registre#2002): the width this names' >> "$R/src/lib.rs"
printf '{"kind":"filed","tracker":"jfarcand/mirroir-carnet","issue":2002,"at":"2026-09-08T00:00:00Z"}\n' \
    >> "$CFG/carnet-claims/$SID.jsonl"
check "a marker without the limitation label does not exempt" 1 "$(filed_caps "$(run_full "$R" --json)")"
git -C "$R" checkout -q -- src/lib.rs

# --cheap never touches the network, and the status line runs it. It used to keep this cap
# unconditionally, which held every correctly registered limitation at 6 there for as long as
# the register required the issue open. It now reads the label from the line carnet.sh writes
# when it applies it — and without that line it still keeps the cap.
printf '%s\n%s\n' "$IDENTITY" '{"kind":"filed","tracker":"jfarcand/mirroir-carnet","issue":2001,"at":"2026-09-08T00:00:00Z"}' \
    > "$CFG/carnet-claims/$SID.jsonl"
echo '// LIMITATION(registre#2001): the width this names' >> "$R/src/lib.rs"
check "--cheap with no recorded label keeps the cap" 1 "$(filed_caps "$(run "$R")")"
printf '{"kind":"limitation","tracker":"jfarcand/mirroir-carnet","issue":2001,"at":"2026-09-08T00:00:00Z"}\n' \
    >> "$CFG/carnet-claims/$SID.jsonl"
out=$(run "$R")
check "--cheap credits a limitation carnet recorded, with a marker in scope" 0 "$(filed_caps "$out")"
check "--cheap and the full run agree on it" "$(filed_caps "$(run_full "$R" --json)")" "$(filed_caps "$out")"
git -C "$R" checkout -q -- src/lib.rs
check "--cheap still wants the marker, not the label alone" 1 "$(filed_caps "$(run "$R")")"

rm -rf "$STUB"
rm -f "$CFG/carnet-claims/$SID.jsonl"

# ---- an unregistered LIMITATION marker caps at 6
echo '// LIMITATION(registre#): nothing reads this' >> "$R/src/lib.rs"
out=$(run "$R")
check "LIMITATION naming no issue caps at 6" 6 "$(printf '%s' "$out" | jq -r .score)"
git -C "$R" checkout -q -- src/lib.rs

# ---- the scan is the register's: prose, fixtures, specs and bilan's own tree are outside it.
# The commit that installed bilan reported three markers that were all its own: the fixture here,
# the row in SKILL.md, and the grep pattern in bilan.sh. A scanner that reports itself is worse
# than no scanner. The files are STAGED: bilan reads the session's diff, and an untracked file is
# in no diff — the version of this case before 2026-09-21 left them untracked and passed without
# looking at any of them.
mkdir -p "$R/.claude/skills/bilan" "$R/crates/x/tests"
echo 'LIMITATION(registre#[^)]*) is the pattern' > "$R/.claude/skills/bilan/bilan.sh"
echo '| LIMITATION(registre#…) marker | caps at 6 |'  > "$R/doc.md"
echo 'assert LIMITATION(registre#) fires'             > "$R/crates/x/tests/fixture.rs"
echo 'let y = 2; // LIMITATION(registre#) in a spec'  > "$R/src/thing.spec.ts"
git -C "$R" add -A
out=$(run "$R")
check "the scan does not report its own tree, prose, tests or specs" 0 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("LIMITATION"))] | length')"
echo 'let z = 3; // LIMITATION(registre#) in real source' >> "$R/src/lib.rs"
out=$(run "$R")
check "…but still reports a marker in real source" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("LIMITATION"))] | length')"
git -C "$R" reset -q
git -C "$R" checkout -q -- src/lib.rs
rm -rf "$R/.claude" "$R/doc.md" "$R/crates" "$R/src/thing.spec.ts"

# ---- without the register's gate a marker this session wrote cannot be verified. That fails
# closed on exactly that case: a session that wrote no marker has nothing unverifiable, and a
# checkout with an uninitialised submodule must not cap every session in it.
R2=$(fixture) || exit 2
mkdir -p "$R2/src" && echo 'fn a() {}' > "$R2/src/lib.rs"
git -C "$R2" add -A && git -C "$R2" commit -qm src && git -C "$R2" push -q origin HEAD:refs/heads/main
check "no gate and no marker: nothing to verify, no cap" 0 \
    "$(run "$R2" | jq '[.caps[] | select(.evidence | test("cannot scope"))] | length')"
echo '// LIMITATION(registre#7): the width this names' >> "$R2/src/lib.rs"
check "no gate and a new marker: fails closed and names the remedy" 1 \
    "$(run "$R2" | jq '[.caps[] | select(.evidence | test("cannot scope")) | select(.remedy | test("submodule"))] | length')"
rm -rf "$(dirname "$R2")"
rm -f "$CFG/bilan/"*.baseline*
baseline_now "$R"

# ---- ack accounts for files this session must not touch, for exactly that set
echo peer >> "$R/a.txt"
check "before ack, a dirty tracked file caps at 7" 7 "$(run "$R" | jq -r .score)"
( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
    bash "$BILAN" ack --why "a peer's pin bump in the shared checkout" >/dev/null 2>&1 )
out=$(run "$R")
# An ack is a recorded statement of ownership, so it CLEARS: a peer's file is not this
# session's incompleteness, and leaving it at 9 meant a session that had done everything right
# still could not reach 10.
check "after ack the cap is gone entirely" 0 "$(real_caps "$out")"
check "the ack reason stays visible as a note" 1 \
    "$(printf '%s' "$out" | jq '[.notes[] | select(test("pin bump"))] | length')"
echo second > "$R/b.txt" && git -C "$R" add b.txt
check "dirtying one more file brings the cap back" 7 "$(run "$R" | jq -r .score)"
git -C "$R" rm -q -f --cached b.txt >/dev/null 2>&1; rm -f "$R/b.txt"
git -C "$R" checkout -q -- a.txt

# The ack is keyed by path set, not by content: ownership is a property of the files, not of
# what is in them. So clear it before exercising the gate on the same file.
rm -f "$CFG/bilan/"*.ack.json

# ---- files already dirty when the session opened are not this session's, automatically.
# Three sessions were held at 7 by a peer's mid-edit file with nothing they could do about it.
rm -f "$CFG/bilan/"*.ack.json
echo peer-was-mid-edit >> "$R/a.txt"
check "a file dirty before the baseline caps at 7 without one" 7 "$(run "$R" | jq -r .score)"
( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" bash "$BILAN" baseline >/dev/null 2>&1 )
out=$(run "$R")
check "after the baseline it does not cap at all" 0 "$(real_caps "$out")"
check "the inherited file is still stated as a note" 1 \
    "$(printf '%s' "$out" | jq '[.notes[] | select(test("already uncommitted"))] | length')"
echo mine > "$R/c.txt" && git -C "$R" add c.txt
check "a file this session dirties still caps at 7" 7 "$(run "$R" | jq -r .score)"
check "and the cap names only the session's own file" 1 \
    "$(run "$R" | jq '[.caps[] | select(.cap==7) | select(.evidence | test("c\\.txt") and (test("a\\.txt") | not))] | length')"
git -C "$R" rm -q -f --cached c.txt >/dev/null 2>&1; rm -f "$R/c.txt"
git -C "$R" checkout -q -- a.txt
rm -f "$CFG/bilan/"*.baseline

# ---- a peer's unpushed commit is inherited the same way a dirty file is
rm -f "$CFG/bilan/"*.ack.json "$CFG/bilan/"*.baseline*
baseline_now "$R"                       # observing from here: the commit below is this session's
echo peer-commit > "$R/peer.txt"
git -C "$R" add peer.txt && git -C "$R" commit -qm "a peer's cherry-pick"
check "a commit made after the baseline caps at 8" 8 "$(run "$R" | jq -r .score)"
baseline_now "$R"                       # now re-observe: the same commit is pre-existing
out=$(run "$R")
check "a commit unpushed before the baseline does not cap" 0 "$(real_caps "$out")"
check "the inherited commit is stated as a note" 1 \
    "$(printf '%s' "$out" | jq '[.notes[] | select(test("already unpushed"))] | length')"
git -C "$R" push -q origin HEAD:refs/heads/main
rm -f "$CFG/bilan/"*.baseline*

# ---- background work is the one incompleteness that leaves no trace in git, the ledger or CI.
# A session reported 10/10 from --cheap with four subagents still running; closing it would
# have thrown all of that away.
TASKS="$CFG/scratch/tasks"
mkdir -p "$TASKS" "$CFG/scratch/scratchpad"   # ../tasks only resolves if scratchpad exists
printf 'watching\n\n[exited with code 0]\n' > "$TASKS/finished.output"
printf 'stopped\n\n[killed]\n'              > "$TASKS/stopped.output"
: > "$TASKS/orphan.output"                      # no marker, but nobody holds it
sleep 30 > "$TASKS/live.output" & LIVE=$!
task_run() { ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
    CLAUDE_SCRATCHPAD_DIR="$CFG/scratch/scratchpad" bash "$BILAN" --cheap --json 2>/dev/null ); }
out=$(task_run)
check "a live background task caps at 7" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.cap==7) | select(.evidence | test("background task"))] | length')"
check "it names the live one and only it" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("live")) | select(.evidence | test("finished|stopped|orphan") | not)] | length')"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
check "a finished task is not counted" 0 \
    "$(task_run | jq '[.caps[] | select(.evidence | test("background task"))] | length')"
rm -rf "$CFG/scratch"

# ---- the deliverable, not just the repo. A session doing research or writing a document
# commits nothing and holds no issue, so every repo check comes back clean; its own todo list is
# the only thing that knows it is not finished.
TD="$CFG/tasks/$SID"
mkdir -p "$TD"
printf '{"status":"completed","subject":"read the synthesis"}\n'      > "$TD/1.json"
printf '{"status":"in_progress","subject":"publish the artifact"}\n'  > "$TD/2.json"
out=$(run "$R")
check "an open todo caps at 7" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.cap==7) | select(.evidence | test("todo"))] | length')"
check "it names the unfinished one, not the done one" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("publish the artifact")) | select(.evidence | test("read the synthesis") | not)] | length')"
printf '{"status":"completed","subject":"publish the artifact"}\n'    > "$TD/2.json"
check "all todos done means no cap" 0 \
    "$(run "$R" | jq '[.caps[] | select(.evidence | test("todo"))] | length')"
rm -rf "$CFG/tasks"

# ---- a session that checked nothing must not report a verdict. This is the case that scored
# 10/10 with its artifact unwritten: research and writing touch no commit, no issue and no CI,
# so every check came back clean because every check came back empty.
#
# But the verdict is measured against an ask. The status line renders before the first prompt,
# and without this every session opened at "9/10 nothing measurable" for having done nothing in
# its first second.
rm -rf "$CFG/tasks"; rm -f "$CFG/bilan/"*.baseline*
baseline_now "$R"
out=$(run "$R")
check "before anything is asked there is no verdict to withhold" 0 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("nothing measurable"))] | length')"
check "so a session that has not started scores clean, not 9" 10 "$(printf '%s' "$out" | jq -r .score)"
mkdir -p "$CFG/projects/fixture"
printf '%s\n' '{"type":"user","message":{"content":"Evaluate the integration options"}}' > "$CFG/projects/fixture/$SID.jsonl"
out=$(run "$R")
check "once asked, no commit and no todo means unmeasured, not 10" 9 "$(printf '%s' "$out" | jq -r .score)"
check "and it says why, within the width the status line has" 1 \
    "$(printf '%s' "$out" | jq '[.caps[] | select(.evidence | test("nothing measurable")) | select(.evidence | length <= 56)] | length')"
mkdir -p "$CFG/tasks/$SID"
printf '{"status":"completed","subject":"published the artifact"}\n' > "$CFG/tasks/$SID/1.json"
check "a declared todo makes the session measurable" 0 \
    "$(run "$R" | jq '[.caps[] | select(.evidence | test("nothing measurable"))] | length')"
rm -rf "$CFG/tasks"
echo measurable > "$R/m.txt" && git -C "$R" add m.txt && git -C "$R" commit -qm "a commit"
check "a commit makes the session measurable" 0 \
    "$(run "$R" | jq '[.caps[] | select(.evidence | test("nothing measurable"))] | length')"
git -C "$R" push -q origin HEAD:refs/heads/main
rm -f "$CFG/bilan/"*.baseline*; rm -rf "$CFG/projects"

# ---- the opening ask is carried into the report, so completion is claimed against the request
mkdir -p "$CFG/projects/fixture"
TX="$CFG/projects/fixture/$SID.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"<system-reminder>ignore me</system-reminder>"}}' > "$TX"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"Build the thing that measures completion"}]}}' >> "$TX"
check "the report carries the opening ask" 1 \
    "$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" bash "$BILAN" --cheap 2>/dev/null ) | grep -c 'asked: Build the thing')"
check "and skips the system-reminder that precedes it" 0 \
    "$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" bash "$BILAN" --cheap 2>/dev/null ) | grep -c 'ignore me')"
# A long session is not what it opened with. The report names the LATEST prompt ChefFamille typed,
# and keeps the opening beside it; a scheduled wakeup is text the session wrote for itself, and the
# transcript marks it so (promptSource "system", isMeta, scheduledTaskId).
printf '%s\n' '{"type":"user","promptSource":"typed","message":{"content":"Now publish the report"}}' >> "$TX"
printf '%s\n' '{"type":"user","promptSource":"system","isMeta":true,"scheduledTaskId":"t1","message":{"content":"Check CI again and report"}}' >> "$TX"
report=$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" bash "$BILAN" --cheap 2>/dev/null ) )
check "asked names the latest typed prompt" 1 "$(printf '%s\n' "$report" | grep -c 'asked: Now publish the report')"
check "a wakeup the session wrote is not an ask" 0 "$(printf '%s\n' "$report" | grep -c 'Check CI again')"
check "the opening ask is kept beside it" 1 "$(printf '%s\n' "$report" | grep -c 'opened: Build the thing')"
rm -rf "$CFG/projects"

# ---- the sweep must not report a dead session's claim on an issue that is already closed.
# carnet#236 was closed on 2026-09-03 and MCPNext's ledger still named it, so every session
# start since reported an abandoned issue that no longer existed — a recurring false alarm
# trains the reader to skip the one line the sweep exists to print.
sweep_ledger="$CFG/carnet-claims/11111111-1111-1111-1111-111111111111.jsonl"
mkdir -p "$(dirname "$sweep_ledger")"
cat > "$sweep_ledger" <<LEDGER
{"v":1,"session":"11111111-1111-1111-1111-111111111111","name":"Dead","user":"t","host":"h","pid":999999,"repo":"r","branch":"main","at":"2026-09-03T11:07:02Z","kind":"identity"}
{"kind":"claim","tracker":"jfarcand/mirroir-carnet","issue":236,"at":"2026-09-03T11:07:02Z"}
LEDGER
# No gh in the fixture, so the tracker cannot be consulted: the claim must still be REPORTED
# rather than silently dropped — absence of a verdict is not a closed issue.
sweep_out=$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" PATH=/usr/bin:/bin bash "$BILAN" sweep 2>/dev/null ) )
check "an unverifiable claim is still reported, not dropped" 1 \
    "$(printf '%s' "$sweep_out" | grep -c 'carnet#236')"
check "and the ledger is left intact when it cannot be checked" 1 \
    "$(grep -c '"issue":236' "$sweep_ledger")"
rm -f "$sweep_ledger"

# ---------------------------------------------------------------- portability
# These pin the two spellings that made every Linux run useless, because both failed in ways
# that did NOT look like failure.
#
# `stat -f %m` is the BSD form. On GNU, -f is --file-system and %m is read as another FILE
# operand, so the call SUCCEEDS with human text beginning `File: "…"`; a `|| stat -c %Y` behind
# it never ran, and the text reached an arithmetic expansion as the bare word `File:`. The
# assertion is therefore on the VALUE, not on the exit status — a status check is exactly what
# missed it.
mtime_of() { ( cd "$R" && bash -c "source <(sed -n '/^file_mtime/,/^}/p' \"$BILAN\"); file_mtime \"$1\"" ); }
mt=$(mtime_of "$R/a.txt")
check "file_mtime returns digits on this platform, not the other stat's prose" 1 \
    "$(printf '%s' "$mt" | grep -cE '^[0-9]+$')"
check "and it is the file's real mtime" "$(perl -e 'print ((stat($ARGV[0]))[9])' "$R/a.txt" 2>/dev/null || python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$R/a.txt")" "$mt"
check "a file that is not there reads as 0, never as empty" 0 "$(mtime_of "$R/does-not-exist")"

# The harness's own guard. `mktemp -d -t <prefix>` returns empty on GNU, `|| exit 1` inside
# `$(…)` exits only the subshell, and `cd ""` SUCCEEDS in bash — so the suite once ran every
# case in the developer's real checkout, committed to it and tried to push. Nothing about that
# printed a failure until the push was refused.
check "the sandbox guard refuses an empty fixture path" 2 \
    "$( ( require_sandbox "" ) >/dev/null 2>&1; echo $? )"
check "and refuses a path outside the fixtures, such as the real checkout" 2 \
    "$( ( require_sandbox "$HERE" ) >/dev/null 2>&1; echo $? )"
# The refusal has to leave the command substitution it runs in. A guard that only exits its
# own subshell prints the refusal and hands back an empty path, and the suite then runs every
# case in the live checkout anyway — reproduced with an unwritable TMPDIR before `|| exit 2`
# was on the assignment. Same shape as the real call site, with a new_repo that cannot create.
check "a fixture that cannot be created stops the suite, not only the guard's subshell" 2 \
    "$( ( new_repo() { return 1; }; R=$(fixture) || exit 2; echo continued ) >/dev/null 2>&1; echo $? )"
check "and nothing after the fixture runs" "" \
    "$( ( new_repo() { return 1; }; R=$(fixture) || exit 2; echo continued ) 2>/dev/null )"

# A worktree someone is still working in is not abandoned work. A session's own cwd is not the
# signal — every session here sits in the main checkout and reaches a worktree by path — so
# liveness is a live process inside it, or a file edited recently.
live_dir=$(mktemp -d "${TMPDIR:-/tmp}/bilan-live.XXXXXX") || die "mktemp -d failed for the liveness fixture"
touch "$live_dir/just-edited.txt"
check "a directory edited moments ago reads as in use" 0 \
    "$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" bash -c "source <(sed -n '/^worktree_is_live/,/^}/p' \"$BILAN\"); worktree_is_live \"$live_dir\"" ); echo $?)"
touch -t 202601010000 "$live_dir/just-edited.txt"
check "and one untouched for hours does not" 1 \
    "$( ( cd "$R" && CLAUDE_CONFIG_DIR="$CFG" bash -c "source <(sed -n '/^worktree_is_live/,/^}/p' \"$BILAN\"); worktree_is_live \"$live_dir\"" ); echo $?)"
rm -rf "$live_dir"

# ---- the status line has room for one phrase and it must name the thing to act on.
# ".claude/skills/b" identified nothing, and the --cheap notice filled the line with a sentence
# that says only "this is not a verdict".
score_line() { cut -f3 "$CFG/bilan/$(printf '%s' "$SID" | tr -c 'a-zA-Z0-9._-' '_').score"; }
echo edited >> "$R/a.txt"
run "$R" >/dev/null
check "the published line names the file, not a cut path" 1 \
    "$(score_line | grep -c 'a\.txt')"
for n in alpha bravo charlie delta echo foxtrot golf hotel; do echo x > "$R/$n.txt"; git -C "$R" add "$n.txt"; done
run "$R" >/dev/null
check "a long list is cut on a word boundary, with an ellipsis" 1 \
    "$(score_line | grep -cE '[a-z]…$')"
check "and stays within the width the line has" 1 \
    "$([ "$(score_line | wc -c)" -le 60 ] && echo 1 || echo 0)"
git -C "$R" reset -q HEAD -- . ; rm -f "$R"/{alpha,bravo,charlie,delta,echo,foxtrot,golf,hotel}.txt
git -C "$R" checkout -q -- a.txt

# ---- CI on a head this session did not create is not this session's verdict. In the shared
# main worktree every session sits on the same tip, so one peer's red capped all ten at 5 and
# the gate blocked every one of them over a commit none of them made.
ci_head() { # <baseline-head> -> 1 when the session is graded on it, 0 when it is only stated
    [ -z "$1" ] && { printf 0; return; }
    [ "$1" = "deadbeef" ] && printf 0 || printf 1
}
check "a head unchanged since the session opened is not scored" 0 "$(ci_head deadbeef)"
check "a head this session moved is scored" 1 "$(ci_head abc1234)"
check "no baseline means bilan was not watching, so not scored" 0 "$(ci_head '')"

# An untracked file caps at 9.
touch "$R/scratch.md"
check "an untracked file is a cap of 9 in the report" 9 "$(run "$R" | jq -r .score)"
rm -f "$R/scratch.md"

rm -rf "$(dirname "$R")"
printf '\n%s passed · %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
