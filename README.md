# githubcommitall

One PowerShell command to commit and synchronize the Git repositories represented
by folders in a selected VS Code `.code-workspace` file. No deployment, rebase,
force-push, recursive repository discovery, or automatic submodule processing.

## Requirements

- PowerShell 7.2 or newer (`pwsh`) and Git on PATH.
- Tested on Ubuntu 26.04.1 LTS with PowerShell 7.6.9.
- Git author identity configured in every repository.
- An existing branch with a remote upstream in every repository, including this
  tool's repository. For example, set one initially with
  `git push --set-upstream origin main` (use your actual branch/remote).
- Working Git credentials. Git terminal password prompts are disabled; configure
  your credential manager or SSH beforehand. External credential/SSH helpers may
  still prompt. Repository hooks and Git configuration are honored.

The tool intentionally runs Git hooks and commits **all non-ignored local changes**.
Review changes first; `.gitignore` is not a secret scanner. Commit the utility's
initial source changes yourself before using log publication, or include the tool
repository as a folder in the selected workspace.

## Usage

Run from any directory; paths below assume this repository is checked out here:

```powershell
# First run asks for workspace file and name and saves config.local.json.
pwsh -NoProfile -File /home/johan/github/repos/githubcommitall/ps_scripts/commit-and-push.ps1

# Noninteractive first setup (validate the spelling of your actual file).
pwsh -NoProfile -File /home/johan/github/repos/githubcommitall/ps_scripts/commit-and-push.ps1 `
  -WorkspacePath /home/johan/github/repos/multirepo.code-workspace -WorkspaceName multirepo

# Reuse a saved workspace, or register another one.
./ps_scripts/commit-and-push.ps1 -WorkspaceName multirepo
./ps_scripts/commit-and-push.ps1 -Configure

# Inspect scope/preflight only: no config writes, fetch, edits, commits, or logs.
./ps_scripts/commit-and-push.ps1 -WorkspaceName multirepo -DryRun

# Fetch, commit and merge locally, including the log; do not push any repository.
./ps_scripts/commit-and-push.ps1 -SkipPush
```

`-ConfigPath` selects a different local configuration file. Keep it ignored if
stored inside a repository. The default local configuration and log directory
are ignored. Do not run simultaneous instances against the same repositories.

### Workspace selection

The script uses the saved selection, not an assumption about the active VS Code
window. A standalone PowerShell process does not reliably receive the active
workspace file path. Pass `-WorkspacePath` from a VS Code integration when
needed, or use `-Configure` / `-WorkspaceName` to change the selection.

Workspace JSON comments and trailing commas are supported. Folder paths may be
absolute, relative to the workspace file, or contain `${userHome}` / `${env:NAME}`.
Local `file:` URIs are also supported; remote workspace URIs are rejected.
Repositories are resolved from explicit workspace folders and deduplicated,
including Git worktrees. A folder inside a repository selects that repository.
Non-Git folders and submodule folders are reported as skipped. Independent nested
repositories are included only if explicitly represented by a workspace folder.
Missing folders and unsupported variables are failures, not silent exclusions.
An untracked nested repository that `git add -A` would turn into an embedded
Git link blocks its parent; ignore it in the parent first.

### Synchronization and safety

For each repository: preflight, fetch, timestamp changed eligible files, stage
all eligible changes, commit if necessary, merge upstream, push, fetch again,
and verify a clean working tree and zero ahead/behind commits.

Local work is **committed before merging**, including untracked non-ignored files,
so no temporary stash is needed. Merge conflicts cause an attempted merge abort;
local commits remain available. The repository is marked failed and other
repositories continue. An abort failure is explicitly reported. There is no
automatic conflict resolution. Missing upstreams, detached HEAD, unfinished Git
operations, changed submodules, and Git command failures require manual attention.
Clean repositories with outstanding commits are still pushed; clean behind
repositories are still merged. The configured upstream remote and branch are
used, not a hardcoded `origin/main`. A remote advancing during the run produces
failure rather than a false success. `-SkipPush` reports `local-only`, not synced.

The tool exits **0** for success (including an intentional local-only or dry run)
and **1** for any repository, setup, verification, or log-publication failure.

### Timestamps

Changed files only, with local-time format **`yyyy-MM-dd-HH-mm-ss`**, such as
`2026-11-01-14-12-48`. All repositories in a run share that timestamp.

- `#`: `.ps1`, `.psm1`, `.psd1`, `.sh`, `.bash`, `.zsh`, `.py`, `.pyw`
- `//`: `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`
- `/* ... */`: `.css`, `.scss`, `.less`
- `<!-- ... -->`: `.html`, `.htm`
- `.json`: only explicitly configured, existing top-level string metadata fields.

Only a leading timestamp comment is replaced, including the old
`yyyy_MM_dd_@_HH-mm-ss` format. Other occurrences in file contents are not rewritten.
Shebangs and Python encoding declarations retain their required position.
UTF-8 (with/without BOM), BOM-marked UTF-16, existing LF/CRLF style, and final
newline presence are preserved. Unsupported encodings/binary data in eligible
files cause an explicit failure; symlinks are never timestamped. Dependency and
generated directories (`node_modules`, `vendor`, `dist`, `build`, `coverage`,
`.venv`, `venv`) are not timestamped, even if tracked. Other formats, lockfiles,
and binaries are still committed when Git-eligible but not timestamped.

JSON files are **opt-in**, never receive comments, and may be reformatted by
PowerShell's JSON serializer. Approve only metadata files whose consumers accept
the field and serialization. Do not opt in manifests, lockfiles, or precision-
sensitive data. Nested fields and creation of new fields are not supported.

Example local configuration after first setup:

```json
{
  "version": 1,
  "activeWorkspace": "multirepo",
  "workspaces": [
    {"name": "multirepo", "path": "/home/johan/github/repos/multirepo.code-workspace"}
  ],
  "jsonTimestampRules": [
    {
      "repository": "/absolute/path/to/a/repository",
      "path": "version.json",
      "field": "updatedAt"
    }
  ]
}
```

Rules use the repository's canonical absolute root and exact Git-relative path.
The field must already be a string; all other JSON files are untouched.

### Logs and the tool's own repository

Each real run creates `log/<timestamp>-<unique-id>.json` containing workspace name,
times, paths, states, phases, counts, commit IDs, ahead/behind state, and errors.
Logs deliberately omit file contents, remote URLs, and raw Git output. Paths and
repository names remain visible on GitHub; check whether that is acceptable for
your repository's visibility.

The tool repository is processed **last** with the completed batch log, which is
explicitly force-added despite `/log/` being ignored. If the tool is part of the
workspace, its other eligible changes are committed too. Otherwise, only the log
is staged, and unrelated local changes block publication to preserve scope.

The published log describes the completed workspace batch **before** its own
publication. A separate ignored `*.publication.json` local receipt records the
publication commit, push, verification, and overall result. It is not committed:
publishing its own outcome would cause an endless logging/commit cycle. Console
summary and exit code include publication failures. Failed publication retains
the batch log locally; rerunning can push an already-created log commit.

Once a log is force-added and committed it is tracked; `.gitignore` only excludes
future untracked logs and local receipts. No retention/deletion is automatic.

## Validation

Run the dependency-free integration tests using temporary local repositories and
bare remotes (never your real projects):

```powershell
pwsh -NoProfile -File ./tests/integration.ps1
```

See [handoff.md](./handoff.md) for continuation context if a workspace change
makes the original chat unavailable.
