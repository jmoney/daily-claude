#!/bin/bash
# Weekday-morning automation: triggers a headless Claude Code session that
# builds Obsidian daily notes and per-meeting notes from a Microsoft 365
# calendar. This script itself is just scheduling/guard-rail plumbing --
# weekday check, dedup marker, network wait, enterprise backend pin, budget cap.
# The actual note-building logic lives in the jmoney plugin's /daily-notes
# command (https://github.com/jmoney/personal-claude), which this script
# invokes as a prompt. Runs standalone, via a launchd plist, or via
# `brew services` (see Formula/daily-claude.rb).
set -uo pipefail

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<USAGE
Usage: daily-claude [--dry-run] [--force]

  --dry-run   Print the prompt that would be sent to claude, then exit.
              Does not call claude, spend budget, or touch the vault.
  --force     Run even if a same-day marker already exists (see below).
USAGE
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --force)
      FORCE=true
      ;;
  esac
done

# launchd/brew services run with a minimal environment, so PATH needs to be
# rebuilt here rather than relying on an interactive shell's PATH.
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.9.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKDIR="${DAILY_CLAUDE_HOME:-$HOME/.daily-claude}"
LOGDIR="$WORKDIR/logs"
TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%u)"  # 1=Mon .. 7=Sun
LOGFILE="$LOGDIR/run-$TODAY.log"
MARKER="$WORKDIR/.ran-$TODAY"

mkdir -p "$LOGDIR"
cd "$WORKDIR" || exit 1

# Log to a per-day file under $LOGDIR. This deliberately does NOT also send
# lines to macOS unified logging via `logger`: reading those back needs either
# Full Disk Access or membership in the admin group, and on a managed Mac
# (CyberArk EPM and friends) a standard user has neither and cannot grant
# them, so the entries end up write-only. Nothing prunes these files today --
# they run well under 10KB/day, so that is a someday problem.
log_line() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# Optional per-machine config, sourced from the runtime dir rather than this
# repo so credentials/paths are never at risk of being committed. Recognized:
#   DAILY_CLAUDE_SETTINGS  -- path to a settings JSON passed to `claude
#                             --settings`, supplying the enterprise model and
#                             any per-account overrides. Must NOT be a Bedrock
#                             profile; the backend note below explains why and
#                             the check there enforces it.
#   DAILY_CLAUDE_VAULT     -- absolute path to the Obsidian vault, used only to
#                             confirm the note actually landed (see the check
#                             after the run). The run itself reaches the vault
#                             through the obsidian MCP server, so this is the
#                             one place the script needs the path on disk.
#                             Unset means the check is skipped rather than
#                             failing, so an existing install keeps working.
if [ -f "$WORKDIR/env" ]; then
  # shellcheck source=/dev/null
  . "$WORKDIR/env"
fi

if [ "$DOW" -gt 5 ] && [ "$DRY_RUN" = false ]; then
  log_line "skipping: weekend"
  exit 0
fi

# Guards against double-execution if more than one scheduler is active at
# once (for example the manual launchd plist and a brew-managed service
# both loaded). Whichever fires first for the day wins; anything after it
# becomes a no-op unless --force is passed.
if [ -e "$MARKER" ] && [ "$DRY_RUN" = false ] && [ "$FORCE" = false ]; then
  log_line "skipping: already ran today ($MARKER exists) -- pass --force to override"
  exit 0
fi

# The laptop's VPN/network often isn't up yet at the 7am trigger. Rather than
# have launchd fire repeatedly, wait out the gap here, retrying until the
# network is reachable or 11:00 passes (a daily note assembled much later
# than that isn't worth having).
if [ "$DRY_RUN" = false ]; then
  # Any HTTP response at all proves the network is up, so this deliberately
  # omits curl's -f: the API root answers 404, and -f turns that into exit 22,
  # which reads as "no network" and stalls every run until the deadline.
  have_network() {
    curl -sS --max-time 5 -o /dev/null "https://api.anthropic.com" >/dev/null 2>&1
  }
  CONNECTIVITY_DEADLINE=$(date -v11H -v0M -v0S +%s)
  if ! have_network; then
    log_line "no network yet, retrying every 60s until 11:00"
    while ! have_network; do
      if [ "$(date +%s)" -ge "$CONNECTIVITY_DEADLINE" ]; then
        log_line "giving up waiting for network by 11:00, skipping today"
        exit 0
      fi
      sleep 60
    done
    log_line "network is back after waiting"
  fi
fi

# Tool names this run is pre-authorized to call without an interactive prompt.
# Agent(daily-notes) covers the /jmoney:daily-notes slash command dispatching
# its subagent; the note-building logic itself lives in that subagent's
# definition (~/.claude/skills/jmoney/agents/daily-notes.md), not here. The
# calendar/vault tool names still need to be listed too -- the subagent's own
# `tools:` frontmatter caps what it CAN call, but permission to actually call
# them without an interactive prompt is still granted by this session-level
# list. This automation is enterprise-only, which is why the calendar tools are
# listed under the mcp__claude_ai_Microsoft_365__* prefix alone: that connector
# is scoped to the claude.ai org account, and a Bedrock session has no claude.ai
# account at all. Since the calendar IS the input to this run, there is nothing
# useful to fall back to under Bedrock -- so the backend check below refuses to
# run there rather than pretending a fallback exists.
# ToolSearch is listed because MCP tool schemas now arrive deferred: the tool
# names are visible but nothing is callable until its schema is loaded, and a
# subagent without permission to run that search sees no calendar or vault
# tools at all and reports them as missing rather than failing loudly.
ALLOWED_TOOLS="Agent(daily-notes),mcp__obsidian__vault_list,mcp__obsidian__vault_read,mcp__obsidian__vault_write,mcp__obsidian__vault_append,mcp__obsidian__vault_patch,mcp__obsidian__vault_get_document_map,mcp__claude_ai_Microsoft_365__outlook_calendar_search,mcp__claude_ai_Microsoft_365__read_resource,ToolSearch"

# The actual note-building prompt now lives in the jmoney plugin
# (~/.claude/skills/jmoney/agents/daily-notes.md), invoked via its slash
# command. This requires that plugin to be installed -- see
# https://github.com/jmoney/personal-claude.
PROMPT="/jmoney:daily-notes $TODAY"

if [ "$DRY_RUN" = true ]; then
  echo "$PROMPT"
  exit 0
fi

touch "$MARKER"

{
  echo "$(date '+%Y-%m-%d %H:%M:%S') starting run for $TODAY"
  # `--settings` MERGES over the resolved hierarchy rather than replacing it, so
  # ~/.claude/settings.json (the shared base) still contributes any key the
  # chosen profile omits. The base deliberately carries no backend setting at
  # all, so this pins CLAUDE_CODE_USE_BEDROCK=0 rather than relying on absence:
  # this run only works against the enterprise account (see the M365 note
  # above), and a session that came up on Bedrock would have no calendar to read.
  #
  # Deliberately NOT using --setting-sources to isolate from the user file:
  # MCP servers are registered at user scope, so excluding `user` removes the
  # obsidian server and the run has nothing to write to.
  SETTINGS_ARGS=()
  if [ -n "${DAILY_CLAUDE_SETTINGS:-}" ]; then
    if [ -f "$DAILY_CLAUDE_SETTINGS" ]; then
      # Refusing outright beats running with a pinned backend that contradicts
      # the rest of the profile: a Bedrock profile also names a Bedrock model,
      # which the enterprise endpoint would reject anyway.
      if [ "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // "0"' "$DAILY_CLAUDE_SETTINGS")" = "1" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') DAILY_CLAUDE_SETTINGS=$DAILY_CLAUDE_SETTINGS enables Bedrock, but this automation is enterprise-only, aborting"
        exit 1
      fi
      SETTINGS_ARGS=(--settings "$DAILY_CLAUDE_SETTINGS"
                     --settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}')
    else
      # Failing loudly beats silently billing the default account.
      echo "$(date '+%Y-%m-%d %H:%M:%S') DAILY_CLAUDE_SETTINGS=$DAILY_CLAUDE_SETTINGS does not exist, aborting"
      exit 1
    fi
  fi

  # ${A[@]+"${A[@]}"} rather than a bare "${A[@]}": /bin/bash on macOS is 3.2,
  # where expanding an empty array under `set -u` is a fatal unbound-variable
  # error. This form expands to nothing at all when SETTINGS_ARGS is empty.
  # caffeinate holds the assertion for exactly as long as the run: launchd fires
  # this on a maintenance darkwake, and without an assertion the machine goes
  # straight back to sleep mid-run -- on 2026-08-18 it slept 44s in and stayed
  # down 22 minutes, so the run got ~2 minutes of actual runtime spread across a
  # 25 minute wall clock. That also means gtimeout cannot be relied on alone to
  # bound the run: its timer only advances while the machine is awake, so a
  # suspended run blows through the wall-clock limit without ever tripping it.
  # -i prevents idle sleep and -s prevents system sleep (the latter only has an
  # effect on AC power, which is the case that was actually failing).
  caffeinate -i -s gtimeout --kill-after=30s 10m claude -p "$PROMPT" \
    ${SETTINGS_ARGS[@]+"${SETTINGS_ARGS[@]}"} \
    --allowedTools "$ALLOWED_TOOLS" \
    --max-budget-usd 3.00 \
    --no-session-persistence
  STATUS=$?
  if [ "$STATUS" -eq 124 ] || [ "$STATUS" -eq 137 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') run timed out after 10m, killed"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') run finished, exit code $STATUS"
  fi
  # The pipeline below makes this a subshell, so exit here rather than assigning:
  # it is the only way the status reaches the caller, which reads PIPESTATUS[0].
  exit "$STATUS"
# tee rather than a plain >> append so this block's output -- including
# claude's multi-line transcript -- also reaches stdout, which is what makes a
# manual foreground run watchable. This block uses plain echo rather than
# log_line(): log_line would append to $LOGFILE directly while the tee below
# is also writing it, so the two writers would interleave.
} 2>&1 | tee -a "$LOGFILE"
CLAUDE_STATUS=${PIPESTATUS[0]}

# `claude -p` exits 0 whenever the model produced a reply -- including a reply
# that only explains why nothing was built. Two consecutive days of empty runs
# each reported exit code 0 this way, so launchd, `brew services` and the log
# line above all looked healthy while the vault went untouched. The note on
# disk is the only trustworthy success signal, so check for it and let a real
# failure reach the scheduler as a non-zero exit.
FAILED=false
if [ "$CLAUDE_STATUS" -ne 0 ]; then
  FAILED=true
fi

if [ -n "${DAILY_CLAUDE_VAULT:-}" ]; then
  NOTE="$DAILY_CLAUDE_VAULT/Daily/$TODAY/Daily.md"
  if [ -s "$NOTE" ]; then
    log_line "verified note exists: $NOTE"
  else
    log_line "no note at $NOTE -- the run reported success but wrote nothing"
    FAILED=true
  fi
else
  log_line "DAILY_CLAUDE_VAULT unset, skipping the note check -- set it in $WORKDIR/env to have empty runs reported as failures"
fi

if [ "$FAILED" = true ]; then
  # Dropping the marker lets a later fire or a plain re-run try again, rather
  # than the day being written off as done by a run that produced nothing.
  rm -f "$MARKER"
  log_line "run failed, cleared $MARKER so the next attempt is not skipped"
  exit 1
fi

log_line "run succeeded"
exit 0
