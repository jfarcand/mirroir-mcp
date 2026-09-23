#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: bilan — the session's balance sheet: what this session left undone, measured not narrated
# ABOUTME: Every completion number this repo reports is this script's number, computed from git, the carnet ledger and CI
#
# The 0-10 completion number used to come from the model's story of the session, so a session
# that believed it was done said 10 while it still held open carnet issues. Every fact behind
# that number is machine-checkable, and this script checks it.
#
# The score is min() over caps. A cap is a fact that makes "done" false; each one prints its own
# evidence and its own remedy, so the number is never a verdict without a reason.
#
# Portability: shared through the repo like carnet.sh, and it runs on a developer's macOS and in
# a Linux container alike — macOS bash 3.2 (no associative arrays, no mapfile), sed, jq, git.
# `gh` is used only in full mode; --cheap touches no network, because it is the form a hook or a
# status line runs on the hot path of every turn, and hosts kill a hook at ~10s.
#
# Where the two platforms' tools disagree, the rule is one spelling both accept — or, failing
# that, a fallback chain ordered so the FIRST form is the one that fails cleanly on the other
# platform. Never a uname branch, and never an order chosen by habit: `a || b` is only a
# fallback when `a` actually reports failure, and the stat case below is the counter-example
# that has to be read before adding another pair.
#   - mktemp: an explicit "$TMPDIR/name.XXXXXX" template, never `-t <prefix>`. BSD invents the
#     X's from a bare prefix and GNU refuses it ("too few X's in template"), which made every
#     run in a Linux container die on line one before a single fact was measured.
#   - stat: `stat -c %Y` (GNU) falling back to `stat -f %m` (BSD), in that order and validated
#     as digits — see file_mtime, where the reverse order silently succeeded on GNU.
#   - date: parsing a stamp is `date -j -u -f` (BSD) falling back to `date -u -d` (GNU).
set -uo pipefail

CHEAP=0
JSON=0
QUIET=0

usage() {
    cat <<'EOF'
bilan — what this session left undone

  bilan.sh [--cheap] [--json] [--session <uuid>]   score this session in this checkout
  bilan.sh sweep                                    what dead sessions left across every worktree
  bilan.sh ack --why "<whose and why>"              declare uncommitted files not this session's
  bilan.sh baseline                                 record what was already dirty (SessionStart)

  --cheap     local facts only: no gh, no network (what a hook or status line runs)
  --json      machine form: {"score":N,"caps":[…],"friction":{…}}
  --quiet     print nothing when the score is 10

Exit: 0 = 10/10 · 1 = incomplete · 2 = error
EOF
}

# ------------------------------------------------------------------ output helpers
say()  { [ "$JSON" = 1 ] || printf '%s\n' "$*"; }
die()  { printf '❌ %s\n' "$1" >&2; exit 2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v jq  >/dev/null 2>&1 || die "jq is required"

# ------------------------------------------------------------------ context
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
LEDGER_DIR="$CFG/carnet-claims"
SESSION_ID=${CLAUDE_CODE_SESSION_ID:-}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "run this inside a git checkout"
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

# One line per cap: <cap>\t<icon>\t<evidence>\t<remedy>. A temp file rather than an array so
# the checks can run in subshells and bash 3.2 stays happy.
# The register this repo files into, resolved the way carnet.sh resolves it: registre.toml at
# the checkout root, overridable by the environment. Empty is fine — every use is guarded, and a
# repo that names no register simply skips the tracker checks.
TRACKER=${REGISTRE_TRACKER:-}
if [ -z "$TRACKER" ] && [ -f "$REPO_ROOT/registre.toml" ]; then
    TRACKER=$(sed -n 's/^tracker[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/registre.toml" | head -1)
fi

# `mktemp -t PREFIX` is BSD/macOS syntax. GNU coreutils reads the argument as a
# template and rejects one without trailing X's ("too few X's in template"), so
# this aborted on every Linux session — which is every cloud session, i.e. exactly
# where a completion number is least likely to be checked by hand. An explicit
# path with X's behaves identically on both.
CAPS=$(mktemp "${TMPDIR:-/tmp}/bilan.XXXXXX") || die "mktemp failed"
trap 'rm -f "$CAPS" "$NOTES" "$SCOPE"' EXIT

cap() { # <cap> <icon> <evidence> <remedy>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CAPS"
}

# A note is a fact worth printing that is NOT this session's incompleteness, so it never
# reaches the score. Without this channel the only way to mention something was to cap on it,
# which is how a peer's mid-edit file came to hold three sessions at 7 with nothing they could
# do about it.
NOTES=$(mktemp "${TMPDIR:-/tmp}/bilan-notes.XXXXXX") || die "mktemp failed"
say_note() { printf '%s\n' "$1" >> "$NOTES"; }

# The register's scope, fetched at most once per run (see register_scope). A file rather than a
# variable for the same reason CAPS is one: the checks run in subshells.
SCOPE=$(mktemp "${TMPDIR:-/tmp}/bilan-scope.XXXXXX") || die "mktemp failed"

# ------------------------------------------------------------------ session facts
ledger_file() { [ -n "$SESSION_ID" ] && printf '%s' "$LEDGER_DIR/$SESSION_ID.jsonl"; }

session_started_epoch() {
    local f
    f=$(ledger_file) || return 1
    [ -s "$f" ] || return 1
    # -u: the ledger stamp is UTC, and BSD date otherwise reads it as local time, which put
    # the session's start hours in the future and made every stash look older than the session.
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(head -1 "$f" | jq -r '.at // empty')" +%s 2>/dev/null \
        || date -u -d "$(head -1 "$f" | jq -r '.at // empty')" +%s 2>/dev/null
}

transcript_path() {
    local slug
    [ -n "$SESSION_ID" ] || return 1
    slug=$(printf '%s' "$REPO_ROOT" | sed 's#[/.]#-#g')
    for d in "$CFG/projects/$slug" "$CFG/projects"/*; do
        [ -f "$d/$SESSION_ID.jsonl" ] && { printf '%s' "$d/$SESSION_ID.jsonl"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------------ acknowledgement
# Ownership of an uncommitted file is NOT machine-decidable here, and that was tested rather
# than assumed: Claude Code records the paths a session touched in the transcript's
# `file-history-snapshot.trackedFileBackups`, but only for the Edit/Write tools. Sessions in
# this repo work Bash-first, so that map came back EMPTY for a session that had just written
# nine files — attribution would have called its own work a peer's and stopped blocking, which
# is the worst direction to be wrong in.
#
# So the judgement stays with the session, and `ack` is what makes it cost one line instead of
# a paragraph on every run. It is keyed to the exact set of files: dirty one more and the cap
# comes back. It never applies to anything but the shared-checkout case, because every other
# cap is about state this session can actually change.
ack_file() { [ -n "$SESSION_ID" ] && printf '%s' "$CFG/bilan/$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9._-' '_').ack.json"; }

signature_of() { printf '%s' "$1" | sort | shasum 2>/dev/null | cut -d' ' -f1; }

ack_reason_for() { # <field> <signature>
    local f
    f=$(ack_file) || return 1
    [ -f "$f" ] || return 1
    jq -r --arg k "$1" --arg s "$2" 'select(.[$k] == $s) | .why // empty' "$f" 2>/dev/null | grep . || return 1
}

# Written by the SessionStart hook. A path already dirty when the session opened belongs to
# whoever dirtied it, which was not this session — the one piece of ownership that IS decidable.
# Paths, not content: a peer who keeps editing the same file is still that peer, and treating a
# changed hash as "now mine" would hand their work back to the cap it was meant to escape.
baseline_file() { [ -n "$SESSION_ID" ] && printf '%s' "$CFG/bilan/$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9._-' '_').baseline"; }

# A session with NO baseline cannot attribute anything, and defaulting to "it is all yours" is
# how one unpushed commit in the shared checkout came to block every other session in the fleet
# over work none of them had done — a session doing design-only research was told to push two
# commits it had never made. When the baseline is missing entirely, bilan has not been watching
# this session, so it starts watching now: the state it finds on its first run is the state it
# inherited. It can only ever measure change from the moment it began observing, and claiming
# otherwise is what did the damage.
ensure_baseline() {
    local f
    f=$(baseline_file) || return 0
    [ -f "$f" ] && return 0
    cmd_baseline >/dev/null 2>&1
    say_note "no baseline existed for this session — everything already uncommitted or unpushed is treated as inherited, and only changes from here are this session's"
}

cmd_baseline() {
    local f u up
    f=$(baseline_file) || return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    git status --porcelain 2>/dev/null | grep -v '^??' | sed 's/^...//' > "$f"
    # Commits carry the same inheritance as files: a peer's cherry-pick sitting unpushed in the
    # shared checkout when this session opened is not this session's to push.
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -n "$up" ]; then
        git rev-list "$up..HEAD" 2>/dev/null > "${f}.commits"
    else
        : > "${f}.commits"
    fi
    # HEAD at session start, so "did this session commit anything at all" is answerable.
    git rev-parse HEAD 2>/dev/null > "${f}.head" || : > "${f}.head"
    u=$(grep -c . "${f}.commits" 2>/dev/null); u=${u:-0}
    local d; d=$(grep -c . "$f" 2>/dev/null); d=${d:-0}
    say "baseline: $d file(s) dirty and $u commit(s) unpushed at session start"
    return 0
}

# Split a newline-separated path list into what this session must answer for and what it
# inherited. A session that opened into someone else's mid-edit answers for neither.
not_mine() { # <paths>  -> prints the inherited subset
    local f
    f=$(baseline_file) || return 0
    [ -s "$f" ] || return 0
    printf '%s\n' "$1" | grep -Fxf "$f" 2>/dev/null || true
}

not_mine_commits() { # <shas> -> prints the inherited subset
    local f
    f=$(baseline_file) || return 0
    [ -s "${f}.commits" ] || return 0
    printf '%s\n' "$1" | grep -Fxf "${f}.commits" 2>/dev/null || true
}

cmd_ack() { # <why>
    local why=$1 f tracked commits up sig csig
    [ -n "$why" ] || die "ack needs --why: say whose work this is and why you are leaving it"
    f=$(ack_file) || die "not inside a Claude Code session"
    tracked=$(git status --porcelain 2>/dev/null | grep -v '^??' | sed 's/^...//')
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    commits=""
    [ -n "$up" ] && commits=$(git rev-list "$up..HEAD" 2>/dev/null || true)
    [ -n "$tracked$commits" ] || { say "nothing uncommitted or unpushed to account for"; return 0; }
    sig=$(signature_of "$tracked"); csig=$(signature_of "$commits")
    mkdir -p "$(dirname "$f")"
    jq -n --arg s "$sig" --arg c "$csig" --arg w "$why" --arg at "$(now)" \
       --arg files "$(printf '%s' "$tracked" | tr '\n' ' ')" \
       '{signature:$s, commit_signature:$c, why:$w, at:$at, files:$files}' > "$f"
    say "📌 accounted for: $(printf '%s\n' "$tracked" | grep -c .) file(s), $(printf '%s\n' "$commits" | grep -c .) commit(s) — $why"
    say "   this covers exactly that set; dirty one more file or make one more commit and the cap returns."
    return 0
}

# ------------------------------------------------------------------ checks · git
# Several sessions share the main worktree, so "5 tracked files modified" is not enough to act
# on: the first live block bilan's former Stop gate issued was for a peer's embacle pin bump, and
# the count alone gave no way to see that. Name the files. Ownership is not decidable from here —
# most edits in this repo go through Bash, so the transcript's file_path arguments see only some
# of them, and mtime is not authorship — so bilan names what it found and leaves the judgement
# to the session.
name_files() { # <max> <newline-separated paths>
    local max=$1 list names count
    list=$(printf '%s\n' "$2" | grep -v '^$')
    count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    names=$(printf '%s\n' "$list" | head -"$max" | tr '\n' ' ')
    if [ "$count" -gt "$max" ]; then
        printf '%s and %s more' "$names" "$((count - max))"
    else
        printf '%s' "${names% }"
    fi
}

check_worktree() {
    local porcelain tracked untracked inherited owned t_n u_n i_n why
    porcelain=$(git status --porcelain 2>/dev/null)
    [ -n "$porcelain" ] || return 0
    tracked=$(printf '%s\n' "$porcelain" | grep -v '^??' | sed 's/^...//')
    untracked=$(printf '%s\n' "$porcelain" | grep '^??' | sed 's/^...//')

    inherited=$(not_mine "$tracked")
    if [ -n "$inherited" ]; then
        owned=$(printf '%s\n' "$tracked" | grep -Fxv -f <(printf '%s\n' "$inherited") 2>/dev/null || true)
    else
        owned=$tracked
    fi
    i_n=$(printf '%s\n' "$inherited" | grep -cv '^$')
    t_n=$(printf '%s\n' "$owned" | grep -cv '^$')
    u_n=$(printf '%s\n' "$untracked" | grep -cv '^$')

    # Inherited dirt is stated, never scored. It is not this session's completion.
    [ "${i_n:-0}" -gt 0 ] && say_note "$i_n file(s) were already uncommitted when this session opened — not its work: $(name_files 5 "$inherited")"

    if [ "${t_n:-0}" -gt 0 ]; then
        # An ack is a recorded statement of ownership, so it CLEARS rather than softens: a
        # peer's file is not this session's incompleteness, and leaving it at 9 meant a session
        # that had done everything right still could not reach 10. It stays visible in every
        # later report, is keyed to the exact path set, and returns the moment one more file
        # goes dirty.
        if why=$(ack_reason_for signature "$(signature_of "$owned")"); then
            say_note "$t_n uncommitted file(s) declared not this session's: $why"
        else
            cap 7 "❌" "$t_n tracked file(s) modified and uncommitted: $(name_files 8 "$owned")" \
                  "commit them — or, if they are a peer's in this shared checkout, bilan.sh ack --why '…'"
        fi
    fi
    if [ "${u_n:-0}" -gt 0 ]; then
        cap 9 "⚠️" "$u_n untracked file(s): $(name_files 8 "$untracked")" \
              "add them, delete them, or move them to the scratchpad"
    fi
}

# Prints this session's own unpushed shas: everything ahead of upstream, minus what was already
# unpushed when the session opened, minus what an ack has declared. Empty means this session has
# nothing of its own waiting to go out — whatever else is sitting in the shared checkout.
owned_unpushed() {
    local upstream shas inherited owned
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    [ -n "$upstream" ] || return 0
    # The full run can settle it; the cheap run has to say it cannot.
    if [ "$CHEAP" = 0 ]; then
        git fetch -q origin 2>/dev/null || true
    elif [ "$(fetch_age)" -gt 300 ]; then
        stale=1
    fi
    shas=$(git rev-list "$upstream..HEAD" 2>/dev/null)
    [ -n "$shas" ] || return 0
    ack_reason_for commit_signature "$(signature_of "$shas")" >/dev/null 2>&1 && return 0
    inherited=$(not_mine_commits "$shas")
    if [ -n "$inherited" ]; then
        owned=$(printf '%s\n' "$shas" | grep -Fxv -f <(printf '%s\n' "$inherited") 2>/dev/null || true)
    else
        owned=$shas
    fi
    printf '%s' "$owned"
}

# Epoch mtime of a file, or 0 when it cannot be read.
#
# The BSD spelling must NOT be tried first. On GNU, `-f` is --file-system and `%m` is read as
# another FILE operand, so `stat -f %m <file>` SUCCEEDS — printing multi-line human text that
# begins `File: "…"` — and a `|| stat -c %Y` fallback behind it never runs. That text then
# reached an arithmetic expansion, where `File:` is a bare word: every Linux run printed
# `File: unbound variable` twice and measured the fetch age as garbage, which in turn made
# `[ "$(fetch_age)" -gt 300 ]` fail with "integer expression expected".
#
# So: GNU spelling first, BSD second, and the answer is used only once it is all digits —
# because the lesson of the original is that an exit status alone did not distinguish the two.
file_mtime() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=""
    case $m in
        '' | *[!0-9]*) printf '%s' 0 ;;
        *) printf '%s' "$m" ;;
    esac
}

# Seconds since the last fetch, or a large number when there has never been one.
fetch_age() {
    local f="$GIT_DIR/FETCH_HEAD"
    [ -f "$f" ] || { printf '%s' 999999; return 0; }
    printf '%s' "$(( $(date +%s) - $(file_mtime "$f") ))"
}

check_unpushed() {
    local upstream ahead shas inherited owned n why stale=0
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -z "$upstream" ]; then
        [ "$BRANCH" = main ] && return 0
        git rev-parse --verify -q origin/main >/dev/null 2>&1 || return 0
        ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
        [ "$ahead" -gt 0 ] || return 0
        cap 8 "❌" "branch $BRANCH has $ahead commit(s) and no upstream — never pushed" \
              "git push -u origin $BRANCH"
        return 0
    fi
    # The full run can settle it; the cheap run has to say it cannot.
    if [ "$CHEAP" = 0 ]; then
        git fetch -q origin 2>/dev/null || true
    elif [ "$(fetch_age)" -gt 300 ]; then
        stale=1
    fi
    shas=$(git rev-list "$upstream..HEAD" 2>/dev/null)
    [ -n "$shas" ] || return 0

    # A peer's commit already sitting unpushed when this session opened is not this session's
    # to push — the same inheritance the dirty-file baseline records, one level up. A peer's
    # cherry-pick landing mid-session held this session at 8 until ack covered it.
    inherited=$(not_mine_commits "$shas")
    if [ -n "$inherited" ]; then
        owned=$(printf '%s\n' "$shas" | grep -Fxv -f <(printf '%s\n' "$inherited") 2>/dev/null || true)
        say_note "$(printf '%s\n' "$inherited" | grep -c .) commit(s) were already unpushed when this session opened — not its work"
    else
        owned=$shas
    fi
    n=$(printf '%s\n' "$owned" | grep -cv '^$')
    [ "${n:-0}" -gt 0 ] || return 0

    if why=$(ack_reason_for commit_signature "$(signature_of "$shas")"); then
        say_note "$n unpushed commit(s) declared not this session's: $why"
        return 0
    fi
    if [ "$stale" = 1 ]; then
        cap 9 "⚠️" "$n commit(s) look unpushed, but origin/main was last fetched $(( $(fetch_age) / 60 ))m ago — they may already be on the remote" \
              "run bilan.sh without --cheap, which fetches first, before acting on this"
        return 0
    fi
    cap 8 "❌" "$n commit(s) not pushed to $upstream ($(printf '%s\n' "$owned" | cut -c1-8 | tr '\n' ' '))" \
          "git push — or, if they are a peer's in this shared checkout, bilan.sh ack --why '…'"
}

check_stash() {
    local start line ts count=0
    start=$(session_started_epoch 2>/dev/null) || return 0
    [ -n "$start" ] || return 0
    while IFS= read -r line; do
        ts=${line%% *}
        [ -n "$ts" ] || continue
        [ "$ts" -ge "$start" ] 2>/dev/null && count=$((count + 1))
    done <<< "$(git log -g --format='%ct %gs' refs/stash 2>/dev/null)"
    [ "$count" -gt 0 ] || return 0
    cap 9 "⚠️" "$count stash entr(y|ies) created during this session" \
          "apply or drop them — a stash left behind is invisible work"
}

# The reliable squash-merge tell: `git push origin --delete` is what clears the upstream, so a
# local branch whose upstream is gone is one the cleanup half-finished. A squash rewrites the
# sha, so `git branch --merged` cannot see it and is not used here.
check_branch_cleanup() {
    local gone
    gone=$(git branch -vv 2>/dev/null | grep ': gone\]' | awk '{print $1}' | tr -d '*' | tr '\n' ' ')
    [ -n "${gone// /}" ] || return 0
    cap 9 "⚠️" "local branch(es) whose upstream is deleted: ${gone% }" \
          "git branch -D ${gone% }"
}

check_validation_marker() {
    local marker epoch sha age
    # Only this session's own commits. A peer's inherited cherry-pick is not something this
    # session can or should validate, and capping on it was the third place the same category
    # error turned up.
    [ -n "$(owned_unpushed)" ] || return 0
    marker="$GIT_DIR/validation-passed"
    if [ ! -f "$marker" ]; then
        cap 9 "⚠️" "commits to push but no .git/validation-passed marker" \
              "runner/scripts/ci/pre-push-validate.sh"
        return 0
    fi
    read -r epoch sha < "$marker"
    if [ "$sha" != "$HEAD_SHA" ]; then
        cap 9 "⚠️" "validation marker is for ${sha:0:8}, HEAD is ${HEAD_SHA:0:8}" \
              "runner/scripts/ci/pre-push-validate.sh (it pins the sha)"
        return 0
    fi
    age=$(( $(date +%s) - epoch ))
    [ "$age" -le 900 ] || cap 9 "⚠️" "validation marker is $((age / 60))m old (TTL 15m)" \
                                "runner/scripts/ci/pre-push-validate.sh"
}

# ------------------------------------------------------------------ checks · carnet
check_carnet_held() {
    local f n list=""
    f=$(ledger_file) || return 0
    [ -s "$f" ] || return 0
    for n in $(jq -r 'select(.kind == "claim") | .issue' "$f" 2>/dev/null); do
        list="$list carnet#$n"
    done
    [ -n "${list// /}" ] || return 0
    cap 6 "❌" "still holding${list} — claimed by this session, neither closed nor released" \
          "carnet.sh close <n> --why … --commit <sha>, or release <n> --reason …"
}

# `create` writes a "filed" line and `close` removes it, so what remains is what this session
# opened and did not fix. That caps at 6 — level with an issue still held, so the session cannot
# quietly walk away from issues it opened.
#
# The standing rule is fix first and file only the residue; this is what makes the second half
# of it visible. If something genuinely cannot be fixed here, that is a decision to put in front
# of ChefFamille, not a cap to slip past.
# A registered limitation is the one filed issue that is NOT work owed, and it has to be exempt.
# The LIMITATION procedure REQUIRES an open issue for as long as a marker names it — a marker must
# be "backed by an issue" in the tracker — so a session that followed that procedure correctly was
# capped at 6 for complying, with no action available to it. carnet#406 is the case that surfaced
# it on 2026-09-11: keyword narrowing was deleted for starving a turn, an LLM classifier was
# rejected for failing the same way, static category narrowing is already done and the tools are
# provider-agnostic, so there was nothing to fix AND nothing honest to close. The score sat at 6
# for a whole session over an issue whose own body says it is a registration and not a task.
#
# The exemption needs BOTH halves, which is what keeps it from being a loophole:
#   - the `limitation` label on the issue, and
#   - a LIMITATION(registre#n) marker naming that same issue, in a file the register scans.
# A label alone still caps, so a bug cannot be relabelled out of the score. A marker naming a dead
# issue is already caught by check_limitation_markers, from the other side. Both together mean the
# issue is a register entry rather than deferred work — and it is printed as a NOTE, so the gap
# stays visible instead of disappearing into a clean pass, which is the whole point of registering.
#
# Both halves are answerable without the network, and have to be: the status line runs --cheap,
# and while the label could only be read from GitHub, --cheap capped every correctly registered
# limitation at 6 for as long as the register required it to stay open — carnet#493, 2026-09-21,
# against a documented promise that the two runs give the same number. carnet.sh records the label
# in the session ledger when it applies it (`create --label limitation`, `label +limitation`), so
# --cheap reads that line, and the full run still asks the tracker, which is the authority.
labelled_limitation() { # <issue-number>
    local f
    if [ "$CHEAP" = 0 ] && command -v gh >/dev/null 2>&1; then
        gh issue view "$1" -R "$TRACKER" --json labels \
            -q '.labels[].name' 2>/dev/null | grep -qx limitation
        return
    fi
    f=$(ledger_file) || return 1
    [ -f "$f" ] || return 1
    jq -c --argjson n "$1" 'select(.kind == "limitation" and .issue == $n)' "$f" 2>/dev/null | grep -q .
}

registered_limitation() { # <issue-number> -> 0 when this is a register entry, not work owed
    labelled_limitation "$1" && marker_in_scope "$1"
}

check_carnet_filed() {
    local f n list="" state
    f=$(ledger_file) || return 0
    [ -s "$f" ] || return 0
    for n in $(jq -r 'select(.kind == "filed") | .issue' "$f" 2>/dev/null); do
        # Someone else may have closed it. Only the full run can tell; --cheap keeps the cap,
        # which is the safe direction for a rule about not walking away from your own issues.
        if [ "$CHEAP" = 0 ] && command -v gh >/dev/null 2>&1; then
            state=$(gh issue view "$n" -R "$TRACKER" \
                    --json state -q .state 2>/dev/null || echo OPEN)
            [ "$state" = CLOSED ] && continue
        fi
        if registered_limitation "$n"; then
            say_note "carnet#$n is a registered limitation, not work owed: labelled \`limitation\` and named by a LIMITATION(registre#$n) marker in the register's scope, which the register contract requires to stay open"
            continue
        fi
        list="$list carnet#$n"
    done
    [ -n "${list// /}" ] || return 0
    cap 6 "❌" "filed this session and still open:${list}" \
          "fix them and close with carnet.sh close <n> --why … --commit <sha> — a session does not file its way out of work"
}

# A LIMITATION marker is the sanctioned way to ship a gap, but only when it names a live issue.
#
# Where a marker counts is the register's decision, not bilan's. The gates scan the directories
# registre.toml declares (scan_dirs), for the configured source extensions, minus test, bench,
# example and generated trees — and `limitation-gates.sh --list-files` prints exactly that set.
# bilan asks for it rather than keeping a copy. It kept one until 2026-09-21, and the copy had
# drifted both ways: it skipped Markdown and its own tree, which the gate never scanned anyway,
# and scanned benches, examples, vendored and generated code, which the gate does not. A marker
# one tool honoured was invisible to the other, and a limitation registered by the book was never
# credited (carnet#493). Asking cannot drift.
#
# The self-match that motivated the old skip list stays impossible: bilan's own tree is shell and
# Markdown, neither of which the register scans.
REGISTRE_GATES="$REPO_ROOT/.registre/limitation-gates.sh"
SCOPE_UNKNOWN="#unknown"

register_scope() { # -> 0 with every in-scope path in $SCOPE; 1 when the register cannot say
    if [ ! -s "$SCOPE" ]; then
        if [ -x "$REGISTRE_GATES" ] \
           && ( cd "$REPO_ROOT" && "$REGISTRE_GATES" --list-files ) > "$SCOPE" 2>/dev/null; then
            :
        else
            printf '%s\n' "$SCOPE_UNKNOWN" > "$SCOPE"
        fi
    fi
    [ "$(head -1 "$SCOPE")" != "$SCOPE_UNKNOWN" ]
}

marker_in_scope() { # <issue-number> -> 0 when a marker in a scanned file names that issue
    register_scope || return 1
    ( cd "$REPO_ROOT" && tr '\n' '\0' < "$SCOPE" \
        | xargs -0 grep -l -F "LIMITATION(registre#$1):" 2>/dev/null | grep -q . )
}

# The gate's own format check already fails a malformed marker; what no gate does is ask the
# tracker whether the issue a marker names exists. That is this check, and it asks only about the
# markers this session added. The loose `[^)]*` is kept so a marker naming no issue at all is
# reported here too, in the session that wrote it.
check_limitation_markers() {
    local upstream changed files=() p added marker n bad=""
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo origin/main)
    # Both halves of the session's work: committed but unpushed, and still in the tree.
    changed=$( { git diff --name-only "$upstream..HEAD"; git diff --name-only HEAD; } 2>/dev/null | sort -u )
    [ -n "$changed" ] || return 0
    if ! register_scope; then
        # The register cannot say what it scans — the vendored gate is missing, or it listed
        # nothing. That leaves a marker this session wrote unverifiable, so fail closed on
        # exactly that case, and stay silent for every session that wrote none.
        if { git diff -U0 "$upstream..HEAD"; git diff -U0 HEAD; } 2>/dev/null \
             | grep '^+' | grep -q 'LIMITATION('; then
            cap 6 "❌" "added a LIMITATION marker the register cannot scope" \
                  "git submodule update --init (bilan asks .registre which files it scans), then rerun"
        fi
        return 0
    fi
    while IFS= read -r p; do
        [ -n "$p" ] && grep -qxF "$p" "$SCOPE" && files+=("$p")
    done <<< "$changed"
    [ "${#files[@]}" -gt 0 ] || return 0
    added=$( { git diff -U0 "$upstream..HEAD" -- "${files[@]}"; git diff -U0 HEAD -- "${files[@]}"; } 2>/dev/null \
             | grep '^+' | grep -o 'LIMITATION(registre#[^)]*)' | sort -u )
    [ -n "$added" ] || return 0
    while IFS= read -r marker; do
        [ -n "$marker" ] || continue
        n=$(printf '%s' "$marker" | sed 's/[^0-9]//g')
        if [ -z "$n" ] || [ "$n" = 0 ]; then
            bad="$bad $marker"
        elif [ "$CHEAP" = 0 ] && command -v gh >/dev/null 2>&1; then
            gh issue view "$n" -R "$TRACKER" --json number \
                >/dev/null 2>&1 || bad="$bad #$n(no such issue)"
        fi
    done <<< "$added"
    [ -n "${bad// /}" ] || return 0
    cap 6 "❌" "LIMITATION marker(s) naming no live issue:${bad}" \
          "run the register-limitation skill — an unregistered gap is invisible debt"
}

# ------------------------------------------------------------------ checks · in-flight work
# The failure that prompted this: a session reported 10/10 from --cheap while four subagents and
# a CI watcher were still running. Closing it would have thrown all of that away. Background
# work is the one kind of incompleteness that leaves NO trace in git, the ledger or CI — the
# session is the only thing that knows, and it is exactly what a session forgets when it thinks
# it is finished.
#
# Claude Code writes each background task's stream to <scratchpad>/tasks/<id>.output and closes
# it with "[exited with code N]" or "[killed]". No marker means it never ended.
task_dir() {
    local c
    for c in "${CLAUDE_SCRATCHPAD_DIR:-}/../tasks" \
             "/private/tmp/claude-$(id -u)/$(printf '%s' "$REPO_ROOT" | sed 's#[/.]#-#g')/$SESSION_ID/tasks" \
             "/tmp/claude-$(id -u)/$(printf '%s' "$REPO_ROOT" | sed 's#[/.]#-#g')/$SESSION_ID/tasks"; do
        [ -d "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Every pid from this shell up to init. bilan runs inside one of those task streams itself, and
# its own output file is open and unmarked exactly like a live task's — the third self-match
# this file has had to answer for. A file held only by this process tree is this invocation.
my_pids() {
    local p=$$ out=""
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        out="$out $p"
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    printf '%s' "$out"
}

check_running_tasks() {
    local dir f pids p mine running=0 names="" id
    command -v lsof >/dev/null 2>&1 || return 0
    dir=$(task_dir) || return 0
    mine=$(my_pids)
    for f in "$dir"/*.output; do
        [ -f "$f" ] || continue
        grep -q '\[exited with code\|\[killed\]' "$f" 2>/dev/null && continue
        pids=$(lsof -t -- "$f" 2>/dev/null) || continue
        [ -n "$pids" ] || continue        # nobody holds it: ended without writing a marker
        # ANY holder in this process's ancestry means the stream is this very invocation —
        # bilan is itself running inside one. Testing for a holder that is *not* mine reads
        # backwards: the shell's own subshells are descendants, so they never match the
        # ancestry walk and every run reported itself as a live task.
        local is_mine=0
        for p in $pids; do
            printf '%s' " $mine " | grep -q " $p " && { is_mine=1; break; }
        done
        [ "$is_mine" = 1 ] && continue
        id=$(basename "$f" .output)
        running=$((running + 1)); names="$names $id"
    done
    [ "$running" -gt 0 ] || return 0
    cap 7 "❌" "$running background task(s) still running:${names}" \
          "wait for them, or TaskStop them deliberately — closing the session loses the work"
}

# The deepest blind spot, named by a session that scored 10/10 with its artifact unwritten:
# "bilan measures repo state, and this session deliberately touches none of it — the 10 is
# honest about the repo and silent about the deliverable." A session whose work is research, a
# document, or a published artifact commits nothing, holds no issue and triggers no CI, so every
# check came back clean and the number said done.
#
# The session's own todo list is the missing measurement. It is the session declaring what it
# set out to do, Claude Code keeps it per session under tasks/<session-id>/, and an item still
# pending or in progress is the session's own statement that it is not finished.
check_open_todos() {
    local dir n subjects
    dir="$CFG/tasks/$SESSION_ID"
    [ -d "$dir" ] || return 0
    n=$(jq -r 'select(.status == "pending" or .status == "in_progress") | .subject // .description // "?"' \
        "$dir"/*.json 2>/dev/null | grep -c . ) || return 0
    [ "${n:-0}" -gt 0 ] || return 0
    subjects=$(jq -r 'select(.status == "pending" or .status == "in_progress") | .subject // .description // "?"' \
        "$dir"/*.json 2>/dev/null | head -3 | cut -c1-60 | tr '\n' '·' | sed 's/·/ · /g; s/ · $//')
    cap 7 "❌" "$n todo(s) still open: $subjects" \
          "finish them, or drop the ones you are not doing — an open todo is this session saying it is not done"
}

# A score of 10 means "everything I checked is done". When nothing was checkable, 10 means
# nothing at all — and that is how a session scored 10/10 with its artifact unwritten. bilan
# reads the repo, the register and CI; a session whose work is research, a design, a document or
# a published artifact touches none of the three, and every check came back clean because every
# check came back empty.
#
# So it says so. A session that made no commit and declared no todo is unmeasured, not complete,
# and cannot reach 10. It caps at 9 rather than blocking, because answering a question really is
# a complete session; what it must not do is produce a verdict it never earned.
#
# Unmeasured is a verdict on a session that was asked something. The status line renders before
# the first prompt arrives, so this cap read "this session made no commit" on a session nobody
# had yet asked anything of — every session opened at 9 on the strength of its own silence. No
# ask, no verdict: the request is the thing the verdict would be measured against.
check_measurable() {
    local f start_head todos=0
    [ -d "$CFG/tasks/$SESSION_ID" ] && \
        todos=$(command ls "$CFG/tasks/$SESSION_ID"/*.json 2>/dev/null | grep -c . )
    [ "${todos:-0}" -gt 0 ] && return 0                 # the session declared what it set out to do
    f=$(baseline_file) || return 0
    start_head=$(cat "${f}.head" 2>/dev/null || true)
    [ -n "$start_head" ] || return 0                    # no baseline: cannot tell, do not claim
    [ "$start_head" = "$HEAD_SHA" ] || return 0         # it committed something: that is measurable
    [ -n "$(opening_ask)" ] || return 0                 # nothing asked yet: nothing to measure against
    cap 9 "⚠️" "nothing measurable — no commit, no todo" \
          "say plainly whether the work is done — bilan checked the repo, the register and CI, and this session touched none of them"
}

# The opening ask, printed with every report. bilan cannot judge whether the work satisfies it —
# that would be narration again, which is the disease it treats — but it can refuse to let a
# session claim completion without the request in front of it. Extracted the way the session
# index does it: a session often opens with pasted output, which names it worse than nothing.
opening_ask() {
    local tx
    tx=$(transcript_path 2>/dev/null) || return 0
    [ -f "$tx" ] || return 0
    jq -r 'select(.type == "user")
           | (if (.message.content | type) == "string" then .message.content
              else ([.message.content[]? | select(.type == "text") | .text] | join("\n")) end)
           | select(test("<command-name>|<local-command|<system-reminder>|<task-notification>|<cross-session-message")|not)
           | select(test("^\\s*$")|not)' "$tx" 2>/dev/null \
      | grep -vE '^\s*$' | grep -vE '^\s*[│┌└├─╭╰|+=#]' | grep -vE '│.*│' \
      | head -1 | tr '\t\n' '  ' | sed -e 's/  */ /g' -e 's/^ //' | cut -c1-150
}

# The latest thing ChefFamille typed, which is what the session is being measured against NOW.
# The opening ask alone named a long session by its first words: one that opened on "Another
# session reported" and went on to ship four fixes still reported under them. Only typed
# prompts count: a scheduled wakeup, a task notification or a peer message is text the session
# or the harness wrote, and the transcript says so (`promptSource: "system"`, `isMeta`,
# `scheduledTaskId` — the same fields carnet's claim hook reads to refuse a self-written claim).
latest_ask() {
    local tx
    tx=$(transcript_path 2>/dev/null) || return 0
    [ -f "$tx" ] || return 0
    jq -r 'select(.type == "user")
           | select((.promptSource // "") != "system" and (.isMeta // false) != true
                    and ((.scheduledTaskId // "") | tostring) == "")
           | (if (.message.content | type) == "string" then .message.content
              else ([.message.content[]? | select(.type == "text") | .text] | join("\n")) end)
           | select(test("<command-name>|<local-command|<system-reminder>|<task-notification>|<cross-session-message")|not)
           | [splits("\n") | select(test("^\\s*$")|not) | select(test("^\\s*[│┌└├─╭╰|+=#]")|not)]
           | first // empty' "$tx" 2>/dev/null \
      | tail -1 | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' | cut -c1-150
}

# ------------------------------------------------------------------ checks · CI (network)
# `gh run list --commit` returns zero rows on this org even when runs exist, so rows are filtered
# by headSha out of a wide branch window. Absence is its own outcome: a sha with no row is NOT
# green, because "nothing pending" and "not present" are indistinguishable in this query.
# CI is REPORTED, never scored. Twice now an attempt to attribute a checkout's CI to the session
# reading it has been wrong, and both times the cost landed on other people:
#
#   * grading the tip outright capped every session in the shared main worktree at 5 when one
#     peer's commit was red, and the Stop gate then blocked all of them — an evening lost.
#   * grading it only when HEAD moved since session start was no better: main moves because
#     PEERS push. A session that had pushed its own commit was then graded on a peer's tip that
#     landed afterwards, which is the failure that prompted this.
#
# There is no third try. A shared checkout has one HEAD and ten sessions; whose commit it is
# cannot be recovered from git, because every session commits as the same author. So the verdict
# is printed — it is genuinely useful to see — and the number stays about work this session can
# actually act on. A session that wants CI on its own commit asks for that sha by name.
check_ci() {
    local upstream slug runs total running bad cancelled
    command -v gh >/dev/null 2>&1 || return 0
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    [ -n "$upstream" ] || return 0
    slug=$(git remote get-url origin 2>/dev/null \
           | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##; s#/$##')
    [ -n "$slug" ] || return 0

    # Addressed by sha, not by a branch window: `gh run list --branch main --limit N` loses a row
    # the moment peers push past it, and "zero pending" is indistinguishable there from "fell out
    # of the window", which reads as green.
    runs=$(gh api "repos/$slug/commits/$HEAD_SHA/check-runs" 2>/dev/null) || return 0
    total=$(printf '%s' "$runs" | jq -r '.total_count // 0' 2>/dev/null)
    [ "${total:-0}" != 0 ] || return 0

    running=$(printf '%s' "$runs" | jq -r '[.check_runs[] | select(.status != "completed") | .name] | unique | join(", ")')
    bad=$(printf '%s' "$runs" | jq -r '[.check_runs[] | select(.conclusion | IN("failure","timed_out","action_required","startup_failure")) | .name] | unique | join(", ")')
    cancelled=$(printf '%s' "$runs" | jq -r '[.check_runs[] | select(.conclusion == "cancelled") | .name] | unique | join(", ")')

    [ -z "$bad" ]       || say_note "CI RED on the checkout head ${HEAD_SHA:0:8}: $bad — check whether that commit is yours"
    [ -z "$running" ]   || say_note "CI still running on the checkout head ${HEAD_SHA:0:8} ($total checks): $running"
    [ -z "$cancelled" ] || say_note "CI cancelled on the checkout head ${HEAD_SHA:0:8}: $cancelled — cancelled is unvalidated, not green"
    [ -n "$bad$running$cancelled" ] || say_note "CI green on the checkout head ${HEAD_SHA:0:8}: $total checks"
}

# ------------------------------------------------------------------ friction (informational)
# Borrowed from Tencent's teamai-cli, which scores a session by how much it struggled. It is NOT
# a cap: a failure found and fixed is just work and never deducts. It is printed because a
# session with 30 tool errors claiming a clean 10 is worth a second look.
friction_line() {
    local tx counts
    # One jq pass over a transcript that can reach tens of MB, so it is skipped on the
    # --cheap path: friction never caps the score, and a hook that overruns is killed at ~10s.
    [ "$CHEAP" = 0 ] || return 0
    tx=$(transcript_path 2>/dev/null) || return 0
    [ -f "$tx" ] || return 0
    counts=$(jq -rs '
        def blocks: .message.content? | if type == "array" then .[] else empty end;
        def user_text: select(.type == "user") | blocks
                       | select(.type == "text") | .text;
        def results:   select(.type == "user") | blocks
                       | select(.type == "tool_result");
        [ ([ .[] | results | select(.is_error == true) ] | length),
          ([ .[] | user_text
             | select(startswith("[Request interrupted by user")) ] | length),
          ([ .[] | results | .content
             | (if type == "array" then (.[]? | .text? // "") else (. // "") end)
             | select(type == "string")
             | select(startswith("The user doesn'"'"'t want to proceed")) ] | length)
        ] | @tsv' "$tx" 2>/dev/null)
    [ -n "$counts" ] || return 0
    printf '%s\n' "$counts"
}

# ------------------------------------------------------------------ run
run_checks() {
    ensure_baseline
    check_worktree
    check_unpushed
    check_stash
    check_branch_cleanup
    check_validation_marker
    check_carnet_held
    check_carnet_filed
    check_limitation_markers
    check_running_tasks
    check_open_todos
    check_measurable
    # A measurement taken with checks switched off must not be allowed to say "done". --cheap
    # skips CI entirely, and a session quoted its cheap 10/10 as completion while a lane was
    # still red and four agents were running. The reduced measurement now cannot reach 10 by
    # construction, and says why.
    # CI is a note either way now, so --cheap and the full run give the same number; the only
    # difference is whether the CI line is printed.
    [ "$CHEAP" = 1 ] || check_ci
}

score() {
    local min=10 c
    while IFS=$'\t' read -r c _ _ _; do
        [ -n "$c" ] || continue
        [ "$c" -lt "$min" ] && min=$c
    done < "$CAPS"
    printf '%s' "$min"
}

score_file() { [ -n "$SESSION_ID" ] && printf '%s' "$CFG/bilan/$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9._-' '_').score"; }

publish_score() { # <score>
    local f top
    f=$(score_file) || return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    # The status line has room for one short phrase, and it has to name the thing to act on.
    # Two things spoiled that. The --cheap notice is a standing cap at 9 that says only "this is
    # not a verdict", so whenever it was the lowest it filled the line with nothing actionable;
    # it is skipped here and the score alone carries that meaning. And a cap that lists full
    # paths was cut mid-path — ".claude/skills/b" identifies nothing — so paths shrink to
    # basenames before the width limit applies, and the cut lands on a word boundary.
    top=$(grep -v 'local facts only' "$CAPS" 2>/dev/null | sort -n | head -1 | cut -f3 \
          | sed -E 's#[^ ]*/([^ /]+)#\1#g' \
          | awk '{ if (length($0) <= 56) print; else { s = substr($0, 1, 56);
                   sub(/[^ ]*$/, "", s); sub(/ $/, "", s); print s "…" } }')
    printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "${top:-nothing outstanding}" > "$f" 2>/dev/null || true
}

report() {
    local s f_errors f_interrupts f_denials fr icon ev rem c line
    s=$(score)
    publish_score "$s"
    fr=$(friction_line)
    [ -n "$fr" ] || fr=$(printf '0\t0\t0')
    IFS=$'\t' read -r f_errors f_interrupts f_denials <<< "$fr"

    if [ "$JSON" = 1 ]; then
        jq -n --argjson score "$s" \
              --rawfile notes "$NOTES" \
              --arg session "${SESSION_ID:-manual}" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" \
              --argjson errors "${f_errors:-0}" --argjson interrupts "${f_interrupts:-0}" \
              --argjson denials "${f_denials:-0}" \
              --rawfile caps "$CAPS" \
          '{score:$score, session:$session, branch:$branch, sha:$sha,
            friction:{tool_errors:$errors, interrupts:$interrupts, denials:$denials},
            notes: ($notes | split("\n") | map(select(length>0))),
            caps: ($caps | split("\n") | map(select(length>0) | split("\t")
                   | {cap:(.[0]|tonumber), icon:.[1], evidence:.[2], remedy:.[3]}))}'
        [ "$s" = 10 ] && return 0 || return 1
    fi

    if [ "$s" = 10 ] && [ "$QUIET" = 1 ]; then return 0; fi

    say "BILAN · ${SESSION_ID:0:8} · $(basename "$REPO_ROOT") @ $BRANCH ${HEAD_SHA:0:8}"
    local ask latest; ask=$(opening_ask); latest=$(latest_ask)
    [ -n "$latest" ] || latest=$ask
    [ -z "$latest" ] || say "asked: $latest"
    [ -z "$ask" ] || [ "$ask" = "$latest" ] || say "opened: $ask"
    say ""
    if [ ! -s "$CAPS" ]; then
        say "  ✅ nothing outstanding — tree clean, nothing unpushed, no issue held"
    else
        sort -n "$CAPS" | while IFS=$'\t' read -r c icon ev rem; do
            say "  $icon $ev"
            say "     → $rem  (caps at $c)"
        done
    fi
    if [ -s "$NOTES" ]; then
        say ""
        while IFS= read -r line; do [ -n "$line" ] && say "  ℹ️  $line"; done < "$NOTES"
    fi
    say ""
    [ "${f_errors:-0}" = 0 ] && [ "${f_interrupts:-0}" = 0 ] && [ "${f_denials:-0}" = 0 ] || \
        say "  friction: ${f_errors} tool error(s) · ${f_interrupts} interrupt(s) · ${f_denials} denial(s)   (informational — a fixed failure never deducts)"
    say ""
    say "COMPLETION: $s/10"
    [ "$s" = 10 ] && return 0 || return 1
}

# ------------------------------------------------------------------ sweep
# The only thing that catches a session that died: a kill -9 fires no exit hook, so the dead
# session can never report on itself. Reads every ledger on this machine and every worktree of
# this repo, and names what a session that is no longer running left behind.
is_session_alive() { # <session-id> <pid>
    local f
    for f in "$HOME"/.claude*/sessions/"$2".json; do
        [ -f "$f" ] || continue
        [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$1" ] || continue
        kill -0 "$2" 2>/dev/null && return 0
    done
    return 1
}

# A worktree with an agent actively working in it is not something a dead session left behind.
# The sweep checked liveness for ledgers and not for worktrees, so it reported every checkout
# with uncommitted work — including one ChefFamille confirmed was in active use. Same false
# alarm as the closed issue, one level over.
#
# A session's own cwd is NOT the signal, and that was measured: every dravr-platform session on
# this machine sits in the main checkout and reaches a worktree by path, so the worktree that
# was actually busy had no session pointing at it. Two things do show it:
#
#   * a live process whose cwd is inside it — a dev server started from that checkout,
#   * a file modified there recently — an agent editing by path leaves no process at all.
#
# Either one means someone is there. Abandoned work is quiet AND untouched.
worktree_is_live() { # <path>
    local recent
    if command -v lsof >/dev/null 2>&1 && lsof -a -d cwd -- "$1" >/dev/null 2>&1; then
        return 0
    fi
    # -mmin -120: two hours is long enough that a pause for thought does not read as abandonment,
    # and short enough that yesterday's leftovers still surface.
    recent=$(find "$1" -type f -mmin -120 -not -path '*/.git/*' -not -path '*/target/*' \
             -not -path '*/node_modules/*' -print -quit 2>/dev/null)
    [ -n "$recent" ]
}

cmd_sweep() {
    local dir f id pid name at issues found=0 busy=0 path="" branch="" dirty ahead line n tmp healed="" seen=""
    say "BILAN SWEEP · $(basename "$REPO_ROOT")"
    say ""
    # Both accounts' config dirs, plus this session's own if CLAUDE_CONFIG_DIR points somewhere
    # the glob does not reach — a session configured outside $HOME was invisible to its own
    # sweep. Deduped, since the common case is that $CFG is already one of the globbed dirs.
    for dir in "$HOME"/.claude*/carnet-claims "$LEDGER_DIR"; do
        [ -d "$dir" ] || continue
        case " $seen " in *" $dir "*) continue ;; esac
        seen="$seen $dir"
        for f in "$dir"/*.jsonl; do
            [ -s "$f" ] || continue
            id=$(basename "$f" .jsonl)
            [ "$id" = "${SESSION_ID:-}" ] && continue
            pid=$(head -1 "$f" | jq -r '.pid // 0')
            is_session_alive "$id" "$pid" && continue
            name=$(head -1 "$f" | jq -r '.name // "?"')
            at=$(head -1 "$f"   | jq -r '.at // "?"')
            # A dead session's ledger outlives the issue. carnet#236 was closed by somebody on
            # 2026-09-03 and MCPNext's ledger still named it, so every session start since has
            # reported an abandoned issue that no longer exists — a recurring false alarm that
            # trains the reader to skip the line the sweep exists to print. Ask the tracker, and
            # drop what has been resolved: SessionEnd would have cleaned this ledger up, and it
            # is only here because the session was killed before it could.
            issues=""
            for n in $(jq -r 'select(.kind == "claim") | .issue' "$f" 2>/dev/null); do
                if [ -n "$TRACKER" ] && command -v gh >/dev/null 2>&1 \
                   && [ "$(gh issue view "$n" -R "$TRACKER" --json state -q .state 2>/dev/null)" = CLOSED ]; then
                    tmp=$(mktemp)
                    jq -c --argjson n "$n" 'select((.kind == "claim" and .issue == $n) | not)' "$f" > "$tmp" \
                        && mv "$tmp" "$f"
                    healed="$healed carnet#$n"
                    continue
                fi
                issues="$issues carnet#$n"
            done
            # A ledger with nothing left to hold is finished, exactly as ledger_drop treats it.
            [ "$(jq -c 'select(.kind == "claim" or .kind == "filed")' "$f" 2>/dev/null | grep -c .)" = 0 ] && rm -f "$f"
            [ -n "${issues// /}" ] || continue
            found=1
            say "  ☠️  session $name (${id:0:8}, last claim $at) ended holding:${issues}"
            say "     → carnet.sh status <n> to see it; a plain claim takes over a stale one"
        done
    done

    while IFS= read -r line; do
        case "$line" in
            worktree\ *) path=${line#worktree } ;;
            branch\ *)
                branch=${line#branch refs/heads/}
                dirty=$(git -C "$path" status --porcelain 2>/dev/null | grep -cv '^??' || true)
                ahead=$(git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
                if [ "${dirty:-0}" -gt 0 ] || [ "${ahead:-0}" -gt 0 ]; then
                    if worktree_is_live "$path"; then
                        busy=$((busy + 1))
                    else
                        found=1
                        say "  📂 $branch ($path): ${dirty:-0} uncommitted, ${ahead:-0} unpushed"
                    fi
                fi ;;
        esac
    done <<< "$(git worktree list --porcelain 2>/dev/null)"

    [ -z "${healed// /}" ] || say "  🧹 cleared from a dead session's ledger, already closed on the tracker:${healed}"
    [ "$busy" = 0 ] || say "  👷 $busy worktree(s) in active use (a live process or edits in the last 2h) — not reported"
    [ "$found" = 1 ] || [ -n "${healed// /}" ] || say "  ✅ nothing left behind by a dead session"
    return 0
}

# ------------------------------------------------------------------ argv
CMD=report
WHY=""
while [ $# -gt 0 ]; do
    case "$1" in
        sweep)      CMD=sweep ;;
        ack)        CMD=ack ;;
        baseline)   CMD=baseline ;;
        --why)      shift; WHY=${1:-} ;;
        --cheap)    CHEAP=1 ;;
        --json)     JSON=1 ;;
        --quiet)    QUIET=1 ;;
        --session)  shift; SESSION_ID=${1:-} ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
    shift
done

case "$CMD" in
    sweep)  cmd_sweep ;;
    ack)    cmd_ack "$WHY" ;;
    baseline) cmd_baseline ;;
    report) run_checks; report ;;
esac
