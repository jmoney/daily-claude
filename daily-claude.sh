#!/bin/bash
# Weekday-morning automation: builds Obsidian daily notes and per-meeting
# notes from a Microsoft 365 calendar via a headless Claude Code session.
# Runs standalone, via a launchd plist, or via `brew services` (see
# Formula/daily-claude.rb).
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
# The calendar tools are listed under two prefixes on purpose. Under the
# claude.ai/enterprise config the M365 connector is account-scoped and its
# tools arrive as mcp__claude_ai_Microsoft_365__*; under Bedrock that connector
# is absent, so M365 is registered as a local MCP server named microsoft365
# and the same tools arrive as mcp__microsoft365__*. Allowing both means this
# runs unattended in either environment without an edit. Listing a tool that
# isn't present is harmless -- it simply never gets called.
ALLOWED_TOOLS="mcp__obsidian__vault_list,mcp__obsidian__vault_read,mcp__obsidian__vault_write,mcp__obsidian__vault_append,mcp__obsidian__vault_patch,mcp__obsidian__vault_get_document_map,mcp__obsidian__periodic_note_get_path,mcp__obsidian__search_simple,mcp__obsidian__search_query,mcp__claude_ai_Microsoft_365__outlook_calendar_search,mcp__claude_ai_Microsoft_365__read_resource,mcp__microsoft365__outlook_calendar_search,mcp__microsoft365__read_resource"

# Keep apostrophes out of the prompt text below: /bin/bash on macOS is 3.2,
# whose parser tracks quotes through a heredoc nested inside $( ), so a lone
# single quote here is a syntax error at the closing paren, not literal text.
PROMPT_TEMPLATE=$(cat <<'PROMPT_EOF'
You are running unattended as a scheduled automation against my Obsidian vault
(via the obsidian MCP server) and my Microsoft 365 calendar (via the Microsoft
365 MCP connector). The date today is __TODAY__. Do the following, in order,
and do not ask me anything since no one is watching this session:

The vault has a "Daily/" folder containing one subfolder per date, named
YYYY-MM-DD. Inside each date subfolder there is a "Daily.md" note (the
meetings list and task list for that day) and one separate note per meeting
held that day, named after the subject of the meeting (sanitize filesystem-invalid
characters, colon slash backslash asterisk question-mark quote angle-bracket
pipe, to a hyphen when naming these files).

1. Check my Microsoft 365 calendar for an all-day event on __TODAY__ whose
   title suggests I am off work (for example it contains OOO, PTO, Vacation,
   Out of Office, or Holiday). If such an event exists, do nothing else and
   stop; do not create or modify any notes today.

   Watch the all-day boundary. An all-day event spans midnight to midnight,
   so the one covering YESTERDAY ends at 00:00 on __TODAY__, and a query for
   today happily returns it. An all-day event counts as mine for __TODAY__
   only when it STARTS on __TODAY__. One that merely ends at 00:00 on
   __TODAY__ belongs to the day before, so ignore it here and in step 2 --
   treating it as belonging to __TODAY__ would wrongly cancel a work day.

2. Otherwise, fetch my calendar events for __TODAY__ (skip any I declined).
   Only real meetings get notes, so drop each of the following. A dropped
   event gets no bullet under "## Meetings" and no meeting note.
   - Anything already called off: an event whose isCancelled field is true,
     or whose subject carries a Canceled or Cancelled prefix.
   - Time off, judged from the title the same way as step 1 (OOO, PTO,
     Vacation, Out of Office, Holiday), even when the event covers only part
     of the day -- a half-day PTO block is not a meeting.
   - Personal time I blocked out for myself, for example Running, Gym,
     Lunch, Focus time, or Pick up kids. Treat an event as personal only
     when ALL THREE of these hold: I am the organizer, no attendee other
     than me is listed, and it has no online join link. The join link lives
     in the location field, which is where a Zoom or Teams URL shows up;
     there is no separate join-link field, so a personal block has an empty
     or absent location. Requiring all three protects solo-looking business
     events: a channel-wide all hands can arrive with an empty attendee
     list, but it has a join link, so it stays.
   - Any event carrying an Outlook category named Personal, if the event
     data exposes categories at all.
   Judge these from the title, organizer, attendees, location, isCancelled,
   and categories only. Do not drop a real meeting merely because its body or
   attendee list mentions PTO for someone else, and when a genuinely
   ambiguous event could go either way, keep it -- a spurious note I delete
   costs me less than a real meeting with no note.

3. List the subfolders of "Daily/" and find the latest one dated before
   __TODAY__ (this is my last work day, whether or not it was yesterday;
   there may be gaps for weekends or days off). Read the "## Tasks" section
   of its "Daily.md" note and collect every unchecked item (lines starting
   "- [ ]"). Ignore already-checked items ("- [x]"). If no earlier subfolder
   exists, there is nothing to carry over.

4. Create "Daily/__TODAY__/Daily.md" if it does not already exist yet, with
   two sections in this order:
   - "## Meetings" -- one bullet per meeting from step 2, formatted as
     "- HH:MM to HH:MM [[Daily/__TODAY__/Meeting Title|Meeting Title]]" (a
     full-path link to the note file for that meeting created in step 5, so
     it resolves correctly even if another day has a same-titled meeting).
   - "## Tasks" -- first the unchecked items carried over from step 3
     (unchanged text, still unchecked), then one blank "- [ ] " line at the
     end for me to fill in by hand. If the note already exists, only add
     items from step 3 that are not already present under "## Tasks"; do not
     duplicate, and do not touch anything else already in the file.

5. For each meeting from step 2, create "Daily/__TODAY__/Meeting Title.md"
   (skip it if that file already exists, to avoid overwriting my notes) with
   YAML frontmatter followed by a body. Frontmatter fields, each quoted if
   the value contains a colon or other YAML-special character: date
   (__TODAY__), time (HH:MM-HH:MM), organizer, location (any physical room
   or address, empty string if none), link (the Teams/Zoom/meeting URL,
   empty string if none), and tags (a list containing "meeting"). Body
   sections, in this order:
   - a level-1 heading with the meeting subject as the title
   - "## Attendees" -- one bullet per attendee, or "(none)" if there are none
   - "## Agenda" -- the invite body/description, verbatim, or "(no agenda
     provided)" if the invite has no body
   - "## Notes" -- leave blank for me to fill in during or after the meeting
   - "## Action Items" -- one blank "- [ ] " line for follow-up tasks

Report back in a few sentences: whether today was marked off, how many
meeting notes were created, and how many tasks were carried over.
PROMPT_EOF
)
PROMPT="${PROMPT_TEMPLATE//__TODAY__/$TODAY}"

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
