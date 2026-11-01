# githubcommitall handoff

## Purpose and agreed behavior

Build a portable PowerShell utility that commits and synchronizes the repositories
represented by folders in a selected VS Code workspace.

- First run asks for workspace name and `.code-workspace` path and saves local JSON.
- Later runs reuse the selection; allow selecting another workspace.
- Fetch and merge upstream changes; do not rebase or force-push.
- Commit all Git-eligible changes, respecting ignore rules, and push existing
  unpushed commits even if there are no new changes.
- Timestamp changed, approved text files only, using `yyyy-MM-dd-HH-mm-ss`
  (24-hour time), for example `2026-11-01-14-12-48`.
- Only approved JSON metadata fields may be timestamped; JSON comments are forbidden.
- Process explicit workspace-folder repositories once; do not recursively discover
  repositories or automatically process submodules.
- Isolate repository failures, preserve work, continue the batch, and report failure.
- Ignore logs by default, force-add completed sanitized logs, and commit/push them
  in githubcommitall after the main loop.
- No old project-specific mirroring, Cloudflare deployment, or embedded credentials.

## User interaction

When asking the user a question, fully stop until they reply. Do not interpret
an unavailable-user tool result as permission to choose a default and continue.

## Status

Implementation complete:

- `ps_scripts/commit-and-push.ps1`: first-run/saved JSON workspace selection,
  JSONC workspace discovery, safe Git argument handling, merge-based sync,
  timestamp allowlist, optional JSON metadata rules, ignored/force-added logs,
  final log publication, local publication receipts, dry run and skip-push modes.
- `.gitignore`: local configuration and future untracked logs/receipts.
- `README.md`: requirements, commands, configuration schema, scope, recovery,
  timestamp behavior and log-publication semantics.
- `tests/integration.ps1`: dependency-free tests with temporary local repos/remotes.

Validation: PowerShell 7.5.4 and the installed PowerShell 7.6.9 on Ubuntu 26.04.1
LTS, 43 integration assertions covering divergence,
conflict abort/work preservation, unpushed commits, clean behind repositories,
deduplication, JSON metadata opt-in, encodings/shebangs/newlines, ignored files,
renames/deletions, local-only/dry runs, configuration persistence, nested repositories,
submodules, worktrees/file URIs, log publication and push rejection/redaction.

No source commit of githubcommitall has been made yet.

First real run (2026-11-01-14-47-19, workspace `mutlirepo`): flowfixer,
Niimbot-labels and nondeploy synchronized successfully. githubcommitall failed
preflight because its `main` branch has no commits and `origin` has no branches.
Preflight now reports this explicitly ("has no commits yet" / missing upstream).
A stray path accidentally appended to a script line was removed. 43 integration
assertions pass on PowerShell 7.6.9. Next step for the user: create and push the
initial githubcommitall commit (`git push --set-upstream origin main`), then rerun.
The original script in nondeploy remains untouched. The installed PowerShell is
available as `/usr/bin/pwsh`; it reports version 7.6.9, with Ubuntu package
version `7.6.9-1.deb`. Windows is not runtime-tested, although the implementation
uses PowerShell/.NET cross-platform APIs.

## Operational decisions

- Commit local work before merge instead of stashing it: untracked eligible files
  and local edits remain recoverable as commits if upstream merge conflicts.
- JSON metadata opt-in permits serializer reformatting; no JSON fields are enabled
  by default, and only existing top-level string fields are eligible.
- Completed GitHub logs describe the workspace batch before their own publication.
  Ignored local publication receipts record the final publication outcome without
  creating a recursive logging/commit cycle.
- If the tool is outside the workspace, publication stages only the current log
  and refuses unrelated tool-repository changes. If included, it processes its own
  eligible changes last along with the log.
- Missing upstreams/detached HEAD/unfinished Git operations/changed submodules are
  explicit failures, not guessed or repaired automatically.

## Continuation

For first real use, review/commit the new source changes,
confirm repository upstreams and credentials, select the actual workspace file
(the example path had a spelling discrepancy), and start with `-DryRun`.
Do not infer which workspace is active from the tool's filesystem location.
First-run prompts and configuration handle the selection.

Keep this file updated if behavior changes. The user requested it because VS Code
workspace changes can make the original chat read-only. No VS Code setting or
workspace folder has been changed to attempt to prevent that behavior.
