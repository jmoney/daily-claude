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

if [ "$DOW" -gt 5 ] && [ "$DRY_RUN" = false ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') skipping: weekend" >> "$LOGFILE"
  exit 0
fi

# Guards against double-execution if more than one scheduler is active at
# once (for example the manual launchd plist and a brew-managed service
# both loaded). Whichever fires first for the day wins; anything after it
# becomes a no-op unless --force is passed.
if [ -e "$MARKER" ] && [ "$DRY_RUN" = false ] && [ "$FORCE" = false ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') skipping: already ran today ($MARKER exists) -- pass --force to override" >> "$LOGFILE"
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') no network yet, retrying every 60s until 11:00" >> "$LOGFILE"
    while ! have_network; do
      if [ "$(date +%s)" -ge "$CONNECTIVITY_DEADLINE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') giving up waiting for network by 11:00, skipping today" >> "$LOGFILE"
        exit 0
      fi
      sleep 60
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') network is back after waiting" >> "$LOGFILE"
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

2. Otherwise, fetch my calendar events for __TODAY__ (skip any I declined).

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
  gtimeout --kill-after=30s 10m claude -p "$PROMPT" \
    --allowedTools "$ALLOWED_TOOLS" \
    --max-budget-usd 3.00 \
    --no-session-persistence
  STATUS=$?
  if [ "$STATUS" -eq 124 ] || [ "$STATUS" -eq 137 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') run timed out after 10m, killed"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') run finished, exit code $STATUS"
  fi
} >> "$LOGFILE" 2>&1
