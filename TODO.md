# TODO

## Done: explicit backend selection for the headless run (2026-08-10)

`daily-claude.sh` used to call `claude -p` with no `--settings` override, so the run billed against whatever `~/.claude/settings.json` happened to resolve to. That symlink is shared with interactive sessions and gets repointed between `settings.json.aws` (Bedrock) and `settings.json.enterprise`, so the scheduled job's billing account silently followed whatever was set for interactive work that day.

The run now sources an optional `$WORKDIR/env` (where `$WORKDIR` is `DAILY_CLAUDE_HOME`, defaulting to `~/.daily-claude` — a runtime dir, never part of this repo). Setting `DAILY_CLAUDE_SETTINGS` there selects the account:

```
export DAILY_CLAUDE_SETTINGS="$HOME/.claude/settings.json.enterprise"
```

Currently set to the enterprise file, and it must stay there: the M365 calendar connector is scoped to the enterprise (claude.ai) login and is not available under Bedrock. Since the calendar is the job's required input, Bedrock is not a viable fallback — a Bedrock-routed run can only ever no-op at step 1. The `settings.json.aws` alternative below is retained only for testing the non-calendar paths. If the variable is unset the script behaves exactly as before; if it points at a nonexistent file the run aborts rather than quietly falling back to the default account.

Note the runtime dir is `/opt/homebrew/var/daily-claude`, not `~/.daily-claude`, because the launchd plist sets `DAILY_CLAUDE_HOME`. The env file must live there.

### Two findings that changed the original plan

**`--settings` merges, it does not replace.** A settings file that simply omits `CLAUDE_CODE_USE_BEDROCK` inherits the value from `~/.claude/settings.json`. Verified: passing `settings.json.enterprise` alone still routed to Bedrock, because that file never sets the variable and the user file had `=1`. Each branch in the script therefore pins `CLAUDE_CODE_USE_BEDROCK` explicitly (`0` for enterprise, `1` for aws) via a second `--settings` JSON argument. Relying on absence is what would have made this silently wrong.

**`--setting-sources` is unusable here** — this was the original plan's open question. Excluding `user` does isolate from the enterprise/aws symlink, but MCP servers are registered at user scope, so `--setting-sources project,local` removes the `obsidian` server entirely and the job has nothing to write to. Verified from the job's real working directory: obsidian tools present without the flag, gone with it. The flag is deliberately not used.

### Also checked

`~/.claude/policy-limits.json` and `~/.claude/remote-settings.json` are enterprise-pushed policy. Nothing in either blocks backend selection. `remote-settings.json` does set `enforceAvailableModels: true` with `opus[1m]` in the allowed list, so the enterprise file's model value is valid.

## Open

- **Enterprise account is at its spend limit — this is now a hard blocker.** A live check returned "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit". Because the M365 connector only exists on the enterprise login, there is no working fallback: Bedrock runs cannot read the calendar. The limit has to be raised for this job to function at all.
- **M365 connector was absent from the headless run** even when routed to enterprise. The 2026-08-10 runs found only the `obsidian` MCP server. Enterprise routing is necessary but may not be sufficient — account-scoped connectors authenticated interactively often don't carry into unattended sessions. Needs a check that the connector is actually reachable from a launchd-spawned run, not just from an interactive one.
- No tagged release yet; the formula is head-only. Cut `v0.1.0` and replace `head` with a `url`+`sha256`.
