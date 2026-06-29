#!/bin/bash
# Maverything build-loop driver — Codex × Claude × agy, headless, baton-driven.
# Derived from "AI build-loop protocol (Codex × Claude)".
#
# Safety: autonomous agent execution (--dangerously-skip-permissions / sandboxed
# writes) only runs when explicitly opted in with LOOP_YOLO=1. No git push ever.
# Build-green gate: any turn that leaves `swift build` red is auto-reverted to the
# last green commit. HALT on repeated failures / no-progress.
#
# Usage:
#   LOOP_YOLO=1 REPO=/path/to/worktree MAX_TURNS=18 nohup bash loop/driver.sh \
#       > logs/driver.log 2>&1 & echo $! > logs/loop.pid
set -uo pipefail

REPO="${REPO:?set REPO to the worktree dir}"
LOGS="$REPO/logs"
HANDOFF="$REPO/docs/handoff.md"
WORKLOG="$REPO/docs/worklog.md"
MAX_TURNS="${MAX_TURNS:-18}"
TURN_TIMEOUT="${TURN_TIMEOUT:-1200}"   # seconds per agent turn
BUILD_CMD="${BUILD_CMD:-swift build -c release}"
ROTATION=(CLAUDE CODEX AGY)
GIT_ID_NAME="🦁KDR & 🤖loop"
GIT_ID_EMAIL="kdr@namouli.com"

mkdir -p "$LOGS"
cd "$REPO" || { echo "cannot cd $REPO"; exit 1; }

if [ "${LOOP_YOLO:-0}" != "1" ]; then
    echo "REFUSING: set LOOP_YOLO=1 to run autonomous agents (safety opt-in)."; exit 3
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

git_rev() { git rev-parse HEAD 2>/dev/null; }

read_turn() { grep -m1 '^## TURN:' "$HANDOFF" 2>/dev/null | sed 's/^## TURN:[[:space:]]*//' | tr -d '[:space:]'; }

set_turn() {  # $1 = new turn token
    if [ -f "$HANDOFF" ]; then
        perl -i -pe "s/^## TURN:.*/## TURN: $1/ if \$.==1 || /^## TURN:/" "$HANDOFF" 2>/dev/null \
            || sed -i '' "s/^## TURN:.*/## TURN: $1/" "$HANDOFF"
    fi
}

# Build the per-turn instruction handed to each agent.
prompt_for() {  # $1 = AGENT
    cat <<EOF
You are agent "$1" in an autonomous build loop building the macOS app "Maverything"
(a voidtools-Everything clone) in this repo: $REPO

PROTOCOL:
1. Read docs/handoff.md FIRST — it has GOAL, OPEN QUESTIONS, DONE-WHEN, CONSTRAINTS, NEXT.
2. Before adding anything, briefly red-team the previous increment (git log -3, git show HEAD).
3. Do ONE focused, reviewable increment toward an unchecked DONE-WHEN box (or NEXT).
   - When OPEN QUESTIONS list options A/B/C: BUILD ALL OF THEM (the human picks later) —
     never silently choose one. Make variants switchable/toggleable.
4. Keep the build GREEN: run \`$BUILD_CMD\` and fix errors before committing. If you cannot
   get it green, revert your edits — never commit a red build.
5. Commit your increment: git add -A && git commit (your changes only). Use a clear message.
6. Update docs/handoff.md: tick any finished DONE-WHEN boxes, set "## TURN:" (line 1) to the
   NEXT agent in rotation CLAUDE -> CODEX -> AGY -> CLAUDE, refresh the NEXT section.
   If everything in DONE-WHEN is checked, set "## TURN: DONE".
7. Append ONE terse line to docs/worklog.md (turn summary).
CONSTRAINTS: only edit files under $REPO. NEVER git push. One increment per turn. Prefer
"## TURN: BLOCKED" with a crisp question over guessing on irreversible choices.
Be concise in output; the work is in the commits, not the chat.
EOF
}

run_agent() {  # $1 = AGENT, $2 = turnlog
    local agent="$1" turnlog="$2" prompt rc
    prompt="$(prompt_for "$agent")"
    case "$agent" in
        CLAUDE) ( cd "$REPO" && claude --dangerously-skip-permissions -p "$prompt" < /dev/null ) > "$turnlog" 2>&1 & ;;
        CODEX)  ( cd "$REPO" && codex exec --sandbox workspace-write \
                    --add-dir "$(git rev-parse --git-common-dir)" --skip-git-repo-check \
                    -C "$REPO" "$prompt" < /dev/null ) > "$turnlog" 2>&1 & ;;
        AGY)    ( cd "$REPO" && GIT_AUTHOR_NAME="🦁KDR & 👻🤖Antigravity" \
                    command agy -p "$prompt" --dangerously-skip-permissions < /dev/null ) > "$turnlog" 2>&1 & ;;
        *) echo "unknown agent $agent" >> "$turnlog"; return 99 ;;
    esac
    local pid=$!
    ( sleep "$TURN_TIMEOUT"; kill -9 "$pid" 2>/dev/null ) & local wd=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$wd" 2>/dev/null
    return $rc
}

report() {  # $1 = reason
    {
        echo "# Maverything loop report"
        echo "- ended: $(date)"
        echo "- reason: $1"
        echo "- turns run: $TURN"
        echo "- final TURN: $(read_turn)"
        echo "- HEAD: $(git_rev)"
        echo "## DONE-WHEN"
        grep -E '^- \[[ x]\]' "$HANDOFF" 2>/dev/null
        echo "## last build"
        $BUILD_CMD > "$LOGS/final-build.log" 2>&1 && echo "GREEN" || echo "RED (see final-build.log)"
        echo "## recent commits"
        git log --oneline -15
    } > "$LOGS/LOOP-REPORT.md" 2>&1
    log "REPORT written -> $LOGS/LOOP-REPORT.md ($1)"
}

# ---- main loop ----
log "driver start  repo=$REPO  max_turns=$MAX_TURNS  timeout=${TURN_TIMEOUT}s"
$BUILD_CMD > "$LOGS/preflight-build.log" 2>&1 && log "preflight build GREEN" || { log "preflight build RED -> HALT"; report "preflight-red"; exit 1; }
LAST_GREEN="$(git_rev)"
TURN=0
NO_COMMIT_STREAK=0
FAIL_STREAK=0
REVERT_STREAK=0

while [ "$TURN" -lt "$MAX_TURNS" ]; do
    cur="$(read_turn)"
    [ -z "$cur" ] && cur="CLAUDE"
    if [ "$cur" = "DONE" ]; then log "baton DONE -> finishing"; report "done"; break; fi
    if [ "$cur" = "BLOCKED" ]; then log "baton BLOCKED -> HALT for human"; report "blocked"; break; fi

    TURN=$((TURN+1))
    idx=-1; for i in "${!ROTATION[@]}"; do [ "${ROTATION[$i]}" = "$cur" ] && idx=$i; done
    [ "$idx" -lt 0 ] && cur="CLAUDE" && idx=0
    next="${ROTATION[$(((idx+1)%${#ROTATION[@]}))]}"
    turnlog="$LOGS/turn-$(printf %02d "$TURN")-$cur.log"

    log "TURN $TURN: $cur (next=$next)  rev=$(git_rev | cut -c1-8)"
    before="$(git_rev)"
    run_agent "$cur" "$turnlog"; arc=$?
    after="$(git_rev)"
    log "TURN $TURN: $cur exited rc=$arc"

    # build-green gate
    if $BUILD_CMD > "$LOGS/build-$(printf %02d "$TURN").log" 2>&1; then
        LAST_GREEN="$(git_rev)"; REVERT_STREAK=0
        log "TURN $TURN: build GREEN"
    else
        log "TURN $TURN: build RED -> revert to last green $(echo "$LAST_GREEN" | cut -c1-8)"
        git reset --hard "$LAST_GREEN" > /dev/null 2>&1
        after="$LAST_GREEN"
        REVERT_STREAK=$((REVERT_STREAK+1))
        [ "$REVERT_STREAK" -ge 3 ] && { log "3 reverts in a row -> HALT"; report "revert-thrash"; break; }
    fi

    # progress accounting
    if [ "$after" != "$before" ]; then NO_COMMIT_STREAK=0; else NO_COMMIT_STREAK=$((NO_COMMIT_STREAK+1)); fi
    if [ "$arc" -ne 0 ]; then FAIL_STREAK=$((FAIL_STREAK+1)); else FAIL_STREAK=0; fi
    [ "$FAIL_STREAK" -ge 2 ] && { log "2 agent failures in a row -> HALT"; report "agent-fail"; break; }
    [ "$NO_COMMIT_STREAK" -ge 3 ] && { log "3 no-commit turns -> HALT"; report "no-progress"; break; }

    # auto-advance baton if the agent forgot to flip TURN
    now="$(read_turn)"
    if [ "$now" = "$cur" ] || [ -z "$now" ]; then
        log "TURN $TURN: baton not advanced by agent -> auto-advance to $next"
        set_turn "$next"
    fi
done

[ "$TURN" -ge "$MAX_TURNS" ] && { log "max turns reached"; report "max-turns"; }
log "driver done"
