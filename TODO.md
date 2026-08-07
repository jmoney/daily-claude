# TODO: run daily-claude's headless call through Bedrock instead of the enterprise API

## Why

`daily-claude.sh` currently calls `claude -p` with no `--settings` override, so it
picks up whatever the normal settings hierarchy resolves to -- on this machine
that's `~/.claude/settings.json`, which is a symlink to
`~/.claude/settings.json.enterprise`. That means every scheduled run bills
against the enterprise Claude account.

There's already a `~/.claude/settings.json.aws` file (Bedrock config) used
interactively. Routing the headless run through that instead avoids consuming
enterprise usage for a low-value scheduled job, since Bedrock is billed
separately (their own AWS account/cost center).

## Constraint

The Bedrock settings file has the AWS bearer token inline. It must NOT be
copied into this repo (which is going to GitHub) or otherwise checked in.

## Planned design

1. At startup, `daily-claude.sh` sources an optional `$WORKDIR/env` file if it
   exists (`$WORKDIR` defaults to `~/.daily-claude`, which is a per-user
   runtime dir, NOT part of this git repo -- so nothing placed there is ever
   at risk of being committed).
2. That file would contain a line like:
   ```
   export DAILY_CLAUDE_SETTINGS="$HOME/.claude/settings.json.aws"
   ```
3. If `DAILY_CLAUDE_SETTINGS` is set, the `claude -p` invocation adds:
   ```
   --settings "$DAILY_CLAUDE_SETTINGS" --setting-sources <sources>
   ```
   with `<sources>` excluding `user`, so the enterprise-symlinked
   `~/.claude/settings.json` never loads for this run -- only the AWS file.
4. The repo itself never references the real settings file's content, only
   the env-var/optional-local-file mechanism, so it stays safe to push as-is.

## Open question -- needs a live check before implementing

Not verified yet: the exact value for `--setting-sources` that fully excludes
`user` without erroring (does it need `local` explicitly, or does an empty
value mean "load nothing from the hierarchy"?). Getting this wrong either:
- silently falls back to the enterprise settings (defeats the whole point), or
- errors out.

Confirming this requires one live `claude -p` call against the real
`settings.json.aws` file -- a trivial single-turn prompt, not the full
automation, but it uses real AWS-billed Bedrock credentials. Get an explicit
go-ahead before running it (it's real money on the user's AWS account, even
if small).

## Also noted, not yet investigated

`~/.claude/policy-limits.json` and `~/.claude/remote-settings.json` exist and
look like they could be enterprise-pushed policy. Neither has been read.
Worth a quick check that nothing in there blocks routing this specific
headless call through Bedrock, before assuming the plan above just works.

## Next steps when picking this back up

1. Get go-ahead, run the one live verification call, confirm which
   `--setting-sources` value actually isolates from `user` settings.
2. Wire the `$WORKDIR/env` sourcing + conditional `--settings`/
   `--setting-sources` flags into `daily-claude.sh`.
3. Document the `~/.daily-claude/env` convention somewhere a future reader
   (including future-me) will actually see it -- e.g. the formula's
   `caveats` block already explains `brew services start`; add a line there
   too.
4. Re-run the existing `--dry-run` check plus one real end-to-end run to
   confirm nothing regressed, same as after the folder-structure and
   rich-formatting changes earlier.
