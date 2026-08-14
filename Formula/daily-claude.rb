class DailyClaude < Formula
  desc "Build Obsidian daily and meeting notes from an M365 calendar via Claude"
  homepage "https://github.com/jmoney/daily-claude"
  license "Apache-2.0"

  # No tagged release yet, so this is head-only for now. Once you cut a
  # release, replace this with a stable url+sha256, e.g.:
  #   url "https://github.com/jmoney/daily-claude/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "..."
  head "https://github.com/jmoney/daily-claude.git", branch: "main"

  depends_on :macos # launchd/brew services scheduling is macOS-specific
  depends_on "coreutils" # gtimeout guards the claude -p call against hangs

  def install
    bin.install "daily-claude.sh" => "daily-claude"
  end

  service do
    run [opt_bin/"daily-claude"]
    run_type :cron
    # Fires every day at 07:00; daily-claude itself no-ops on Sat/Sun, so a
    # single daily trigger covers the weekday schedule without needing five
    # separate weekday entries (the underlying cron DSL only accepts one
    # Weekday value or "*", not ranges like "1-5").
    cron "0 7 * * *"
    keep_alive false
    # Service#run_at_load defaults to true, which would fire an unscheduled
    # run every time the service is (re)loaded (brew services start, a
    # reboot, brew upgrade). Only the 07:00 cron trigger should run this.
    run_at_load false
    working_dir var/"daily-claude"
    log_path var/"log/daily-claude/launchd-stdout.log"
    error_log_path var/"log/daily-claude/launchd-stderr.log"
    environment_variables DAILY_CLAUDE_HOME: var/"daily-claude"
  end

  def caveats
    <<~EOS
      daily-claude runs an unattended `claude -p` session against your
      Obsidian and Microsoft 365 MCP connectors on a schedule, and will
      write to your vault. Read daily-claude.sh before enabling it.

      The note-building logic itself lives in the jmoney Claude Code plugin's
      /jmoney:daily-notes command, not in this script -- it must be installed
      at ~/.claude/skills/jmoney (https://github.com/jmoney/personal-claude)
      or every scheduled run will fail to find that command.

      Start the schedule:
        brew services start daily-claude

      Test without spending anything or touching the vault:
        #{bin}/daily-claude --dry-run

      Per-run logs land in one file per day:
        #{var}/daily-claude/logs/

      To choose which account the scheduled run bills against, create
        #{var}/daily-claude/env
      and set a settings file in it, e.g.:
        export DAILY_CLAUDE_SETTINGS="$HOME/.claude/settings.json.enterprise"
      Without it the run inherits ~/.claude/settings.json, which may be
      repointed by your interactive sessions.
    EOS
  end

  test do
    assert_path_exists bin/"daily-claude"
    assert_predicate bin/"daily-claude", :executable?
    assert_match "Usage: daily-claude", shell_output("#{bin}/daily-claude --help")
  end
end
