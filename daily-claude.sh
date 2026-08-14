#!/bin/bash
# Weekday-morning automation: triggers a headless Claude Code session that
# builds Obsidian daily notes and per-meeting notes from a Microsoft 365
# calendar. This script itself is just scheduling/guard-rail plumbing --
# weekday check, dedup marker, network wait, backend selection, budget cap.
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
#                             --settings`, selecting which account this run
#                             bills against (see the backend note below).
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
# list. The calendar tools are listed under two prefixes on purpose. Under the
# claude.ai/enterprise config the M365 connector is account-scoped and its
# tools arrive as mcp__claude_ai_Microsoft_365__*; under Bedrock that connector
# is absent, so M365 is registered as a local MCP server named microsoft365
# and the same tools arrive as mcp__microsoft365__*. Allowing both means this
# runs unattended in either environment without an edit. Listing a tool that
# isn't present is harmless -- it simply never gets called.
ALLOWED_TOOLS="Agent(daily-notes),mcp__obsidian__vault_list,mcp__obsidian__vault_read,mcp__obsidian__vault_write,mcp__obsidian__vault_append,mcp__obsidian__vault_patch,mcp__obsidian__vault_get_document_map,mcp__claude_ai_Microsoft_365__outlook_calendar_search,mcp__claude_ai_Microsoft_365__read_resource,mcp__microsoft365__outlook_calendar_search,mcp__microsoft365__read_resource"

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
  # `--settings` MERGES over the resolved hierarchy rather than replacing it,
  # so ~/.claude/settings.json still contributes any key the chosen file omits.
  # That matters for the backend switch: a settings file that simply leaves
  # CLAUDE_CODE_USE_BEDROCK unset inherits whatever the user file says, so the
  # run can silently bill the wrong account. Each branch therefore pins the
  # variable explicitly instead of relying on absence.
  #
  # Deliberately NOT using --setting-sources to isolate from the user file:
  # MCP servers are registered at user scope, so excluding `user` removes the
  # obsidian server and the run has nothing to write to.
  SETTINGS_ARGS=()
  if [ -n "${DAILY_CLAUDE_SETTINGS:-}" ]; then
    if [ -f "$DAILY_CLAUDE_SETTINGS" ]; then
      SETTINGS_ARGS=(--settings "$DAILY_CLAUDE_SETTINGS")
      case "$DAILY_CLAUDE_SETTINGS" in
        *aws*|*bedrock*)
          SETTINGS_ARGS+=(--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}')
          ;;
        *)
          SETTINGS_ARGS+=(--settings '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}')
          ;;
      esac
    else
      # Failing loudly beats silently billing the default account.
      echo "$(date '+%Y-%m-%d %H:%M:%S') DAILY_CLAUDE_SETTINGS=$DAILY_CLAUDE_SETTINGS does not exist, aborting"
      exit 1
    fi
  fi

  # ${A[@]+"${A[@]}"} rather than a bare "${A[@]}": /bin/bash on macOS is 3.2,
  # where expanding an empty array under `set -u` is a fatal unbound-variable
  # error. This form expands to nothing at all when SETTINGS_ARGS is empty.
  gtimeout --kill-after=30s 10m claude -p "$PROMPT" \
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
# tee rather than a plain >> append so this block's output -- including
# claude's multi-line transcript -- also reaches stdout, which is what makes a
# manual foreground run watchable. This block uses plain echo rather than
# log_line(): log_line would append to $LOGFILE directly while the tee below
# is also writing it, so the two writers would interleave.
} 2>&1 | tee -a "$LOGFILE"
