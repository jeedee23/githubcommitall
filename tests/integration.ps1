#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temp = Join-Path ([IO.Path]::GetTempPath()) "githubcommitall-test-$([guid]::NewGuid().ToString('N'))"
[void][IO.Directory]::CreateDirectory($temp)
$pwsh = (Get-Process -Id $PID).Path
$gitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$source = Join-Path $PSScriptRoot '../ps_scripts/commit-and-push.ps1'
$checks = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}

function Git {
    param([string]$Root, [string[]]$Arguments)
    $output = & $script:gitExe --no-pager -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $Arguments`n$output" }
    return ($output | Out-String).Trim()
}

function Put {
    param([string]$Root, [string]$Path, [string]$Text)
    $full = Join-Path $Root $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full, $Text)
}

function New-Repo {
    param([string]$Name)
    $remote = Join-Path $temp "$Name.git"
    $root = Join-Path $temp $Name
    [void](Git $temp @('init', '--bare', $remote))
    [void](Git $temp @('init', '-b', 'main', $root))
    [void](Git $root @('config', 'user.name', 'Integration Test'))
    [void](Git $root @('config', 'user.email', 'test@example.invalid'))
    Put $root '.gitignore' "/log/`n/config.local.json`nignored.txt`n"
    Put $root 'base.txt' "base`n"
    [void](Git $root @('add', '-A'))
    [void](Git $root @('commit', '-m', 'initial'))
    [void](Git $root @('remote', 'add', 'origin', $remote))
    [void](Git $root @('push', '-u', 'origin', 'main'))
    return $root
}

function Peer {
    param([string]$Root, [string]$Name)
    $peer = Join-Path $temp $Name
    [void](Git $temp @('clone', '-b', 'main', "$Root.git", $peer))
    [void](Git $peer @('config', 'user.name', 'Integration Test'))
    [void](Git $peer @('config', 'user.email', 'test@example.invalid'))
    return $peer
}

function Run-Sync {
    param([string[]]$Arguments, [int]$Expected = 0)
    $output = & $pwsh -NoProfile -File $script:entry @Arguments 2>&1 | Out-String
    $actual = $LASTEXITCODE
    if ($actual -ne $Expected) { throw "Expected exit $Expected, got $actual`n$output" }
    Write-Host $output
}

try {
    $tool = New-Repo 'tool'
    $script:entry = Join-Path $tool 'ps_scripts/commit-and-push.ps1'
    [void][IO.Directory]::CreateDirectory((Join-Path $tool 'ps_scripts'))
    Copy-Item -LiteralPath $source -Destination $entry
    [void](Git $tool @('add', '-A'))
    [void](Git $tool @('commit', '-m', 'install tool'))
    [void](Git $tool @('push'))
    $a = New-Repo 'repo with spaces'
    $b = New-Repo 'repo-b'
    $peerA = Peer $a 'peer-a'
    $peerB = Peer $b 'peer-b'
    $workspace = Join-Path $temp 'multirepo.code-workspace'
    $workspaceData = @{
        folders = @(@{ path = 'repo with spaces' }, @{ path = 'repo-b' },
            @{ path = 'repo with spaces/subdir' }, @{ path = 'tool' }, @{ path = 'plain-folder' })
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $a 'subdir'))
    [void][IO.Directory]::CreateDirectory((Join-Path $temp 'plain-folder'))
    Put $temp 'multirepo.code-workspace' ("// JSONC workspace`n" + ($workspaceData | ConvertTo-Json -Depth 5))

    Put $a 'script.sh' "#!/bin/sh`r`n# 2026_04_11_@_01-05-28`r`necho hello`r`n"
    Put $a 'main.json' '{"name":"unchanged-format"}'
    Put $a 'version.json' '{"updatedAt":"old","other":42}'
    Put $a 'odd -> name.js' 'console.log("hello");'
    Put $a 'ignored.txt' 'not committed'
    Put $a 'node_modules/kept.js' 'not timestamped'
    Put $a 'binary.png' 'binary placeholder'
    $utf16 = Join-Path $a 'wide.ps1'
    [IO.File]::WriteAllText($utf16, "Write-Host 'wide'`r`n", [Text.UnicodeEncoding]::new($false, $true))
    Put $a 'python.py' "#!/usr/bin/env python3`n# coding: utf-8`nprint('hello')`n"
    Put $a 'rename-before.txt' 'rename me'
    Put $a 'delete.txt' 'delete me'
    [void](Git $a @('add', 'rename-before.txt', 'delete.txt'))
    [void](Git $a @('commit', '-m', 'preexisting local commit'))
    [void](Git $a @('mv', 'rename-before.txt', 'renamed -> after.txt'))
    Remove-Item -LiteralPath (Join-Path $a 'delete.txt')

    Put $peerA 'remote.txt' 'remote change'
    [void](Git $peerA @('add', '-A'))
    [void](Git $peerA @('commit', '-m', 'remote divergence'))
    [void](Git $peerA @('push'))
    Put $peerB 'remote-only.sh' "#!/bin/sh`necho remote`n"
    [void](Git $peerB @('add', '-A'))
    [void](Git $peerB @('commit', '-m', 'remote-only'))
    [void](Git $peerB @('push'))

    # Dry run must not even persist first-run configuration.
    $before = Git $a @('rev-parse', 'HEAD')
    $beforeScript = [IO.File]::ReadAllText((Join-Path $a 'script.sh'))
    Run-Sync @('-WorkspacePath', $workspace, '-WorkspaceName', 'multirepo', '-DryRun')
    Assert (-not (Test-Path (Join-Path $tool 'config.local.json'))) 'Dry run does not save configuration'
    Assert ((Git $a @('rev-parse', 'HEAD')) -eq $before) 'Dry run does not commit'
    Assert ([IO.File]::ReadAllText((Join-Path $a 'script.sh')) -eq $beforeScript) 'Dry run does not timestamp'
    Assert (-not (Test-Path (Join-Path $tool 'log'))) 'Dry run does not create logs'

    # Seed a saved workspace and an explicit JSON metadata rule.
    $config = @{
        version = 1; activeWorkspace = 'multirepo'
        workspaces = @(@{ name = 'multirepo'; path = $workspace })
        jsonTimestampRules = @(@{ repository = $a; path = 'version.json'; field = 'updatedAt' })
    }
    Put $tool 'config.local.json' ($config | ConvertTo-Json -Depth 5)
    Run-Sync @()
    $text = [IO.File]::ReadAllText((Join-Path $a 'script.sh'))
    Assert ($text -match '^#!/bin/sh\r\n# \d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\r\necho hello\r\n$') 'Shebang, timestamp format, legacy replacement and CRLF preserved'
    $js = [IO.File]::ReadAllText((Join-Path $a 'odd -> name.js'))
    Assert ($js -match '^// \d{4}(-\d{2}){5}\nconsole' -and -not $js.EndsWith("`n")) 'Unusual path and no final newline preserved'
    Assert ([IO.File]::ReadAllText((Join-Path $a 'main.json')) -eq '{"name":"unchanged-format"}') 'Unapproved JSON untouched'
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $a 'version.json') | ConvertFrom-Json
    Assert ($metadata.updatedAt -match '^\d{4}(-\d{2}){5}$' -and $metadata.other -eq 42) 'Approved JSON field updated with valid JSON'
    Assert ([IO.File]::ReadAllText((Join-Path $a 'node_modules/kept.js')) -eq 'not timestamped') 'Dependency files committed without timestamps'
    Assert ((Git $a @('ls-files', 'ignored.txt')) -eq '') 'Ignored file not committed'
    Assert ((Git $a @('ls-files', 'delete.txt')) -eq '') 'Deletion committed'
    Assert ((Git $a @('ls-files', 'renamed -> after.txt')) -ne '') 'Rename committed'
    $wideBytes = [IO.File]::ReadAllBytes($utf16)
    Assert ($wideBytes[0] -eq 255 -and $wideBytes[1] -eq 254) 'UTF-16 BOM preserved'
    Assert ([IO.File]::ReadAllText((Join-Path $a 'python.py')) -match '^#!/usr/bin/env python3\n# coding: utf-8\n# \d{4}(-\d{2}){5}\n') 'Python encoding declaration remains second'
    Assert ((Git $a @('rev-list', '--parents', '-n', '1', 'HEAD')).Split(' ').Count -eq 3) 'Divergence resolved with merge commit, not rebase'
    Assert ((Git $a @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')) -match '^0\s+0$') 'Repository synchronized'
    Assert ([IO.File]::ReadAllText((Join-Path $b 'remote-only.sh')) -eq "#!/bin/sh`necho remote`n") 'Remote-only files are not timestamped'
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $tool 'log') -Filter '*.json' | Where-Object { $_.Name -notlike '*.publication.json' })
    $log = Get-Content -Raw -LiteralPath $logs[0].FullName | ConvertFrom-Json
    Assert (@($log.repositories | Where-Object { $_.repository -eq $a }).Count -eq 1) 'Duplicate workspace repository processed once'
    Assert ((Git $tool @('ls-files', 'config.local.json')) -eq '') 'Local config remains ignored'
    Assert ((Git $tool @('ls-files', 'log/*.json')) -notmatch 'publication') 'Local publication receipt not tracked'
    Assert ((Git $tool @('ls-files', 'log/*.json')) -ne '') 'Completed log force-added and committed'
    Assert ((Git $tool @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')) -match '^0\s+0$') 'Log repository pushed and verified'

    # No new working changes, but an outstanding commit must still be pushed.
    Put $b 'pending.txt' 'pending'
    [void](Git $b @('add', '-A'))
    [void](Git $b @('commit', '-m', 'already committed'))
    $pending = Git $b @('rev-parse', 'HEAD')
    Run-Sync @()
    Assert ((Git $b @('rev-parse', 'origin/main')) -eq $pending) 'Existing unpushed commit pushed without a new commit'

    # Local-only run saves commits/logs but does not publish.
    Put $b 'local-only.txt' 'local'
    $remoteBefore = Git $b @('rev-parse', 'origin/main')
    Run-Sync @('-SkipPush')
    Assert ((Git $b @('rev-parse', 'origin/main')) -eq $remoteBefore) 'SkipPush leaves remote unchanged'
    Assert ((Git $b @('rev-list', '--count', '@{upstream}..HEAD')) -eq '1') 'SkipPush retains local commit'
    Run-Sync @()

    # Conflict must preserve the local commit, abort merge and continue other repos.
    [void](Git $peerB @('pull', '--ff-only'))
    Put $peerB 'base.txt' "remote conflict`n"
    [void](Git $peerB @('add', '-A'))
    [void](Git $peerB @('commit', '-m', 'conflicting remote'))
    [void](Git $peerB @('push'))
    Put $b 'base.txt' "local conflict`n"
    Put $a 'still-runs.txt' 'success despite another failure'
    Run-Sync @() 1
    Assert ([IO.File]::ReadAllText((Join-Path $b 'base.txt')) -eq "local conflict`n") 'Conflicting local work preserved'
    Assert (-not (Test-Path (Join-Path $b '.git/MERGE_HEAD'))) 'Failed merge aborted'
    Assert ((Git $a @('ls-files', 'still-runs.txt')) -ne '') 'Other repository continues after conflict'
    Assert ((Git $b @('status', '--porcelain')) -eq '') 'Conflict recovery leaves committed clean work'

    # Missing upstream, detached HEAD, invalid encoding, and missing folder fail visibly.
    $bad = New-Repo 'bad'
    [void](Git $bad @('branch', '--unset-upstream'))
    $badWorkspace = Join-Path $temp 'bad.code-workspace'
    Put $temp 'bad.code-workspace' (@{ folders = @(@{ path = 'bad' }, @{ path = 'missing-folder' }) } | ConvertTo-Json -Depth 4)
    Run-Sync @('-WorkspacePath', $badWorkspace, '-WorkspaceName', 'bad') 1
    Assert ((Git $bad @('status', '--porcelain')) -eq '') 'Missing upstream fails without modifying repository'
    [void](Git $bad @('branch', '--set-upstream-to=origin/main'))
    [void](Git $bad @('checkout', '--detach'))
    Run-Sync @('-WorkspaceName', 'bad', '-DryRun') 1
    [void](Git $bad @('checkout', 'main'))
    Put $temp 'bad.code-workspace' (@{ folders = @(@{ path = 'bad' }) } | ConvertTo-Json -Depth 4)
    [IO.File]::WriteAllBytes((Join-Path $bad 'invalid.js'), [byte[]]@(255, 254, 0, 0, 255))
    Run-Sync @('-WorkspaceName', 'bad') 1
    Assert ((Git $bad @('ls-files', 'invalid.js')) -eq '') 'Invalid timestamp encoding is not silently committed'

    # A brand-new repository (no commits, empty remote) fails with a clear message.
    $unborn = Join-Path $temp 'unborn'
    [void](Git $temp @('init', '--bare', "$unborn.git"))
    [void](Git $temp @('init', '-b', 'main', $unborn))
    [void](Git $unborn @('remote', 'add', 'origin', "$unborn.git"))
    [void](Git $unborn @('config', 'branch.main.remote', 'origin'))
    [void](Git $unborn @('config', 'branch.main.merge', 'refs/heads/main'))
    Put $unborn 'new.txt' 'not yet committed'
    $unbornWorkspace = Join-Path $temp 'unborn.code-workspace'
    Put $temp 'unborn.code-workspace' (@{ folders = @(@{ path = 'unborn' }) } | ConvertTo-Json -Depth 4)
    $unbornOutput = & $pwsh -NoProfile -File $script:entry -WorkspacePath $unbornWorkspace -WorkspaceName 'unborn' -DryRun 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 1 -and $unbornOutput -match 'has no commits yet') 'Unborn branch reports a first-commit diagnostic'
    Assert ((Git $unborn @('status', '--porcelain')) -match 'new.txt') 'Unborn repository left untouched'

    # Explicit first setup saves the selection, and a saved selection needs no prompts.
    $freshConfig = Join-Path $tool 'log/first-run-config.json'
    Run-Sync @('-ConfigPath', $freshConfig, '-WorkspacePath', $workspace, '-WorkspaceName', 'fresh', '-DryRun')
    # repo-b is still divergent: setup persists despite that repository failing.
    Run-Sync @('-ConfigPath', $freshConfig, '-WorkspacePath', $workspace, '-WorkspaceName', 'fresh') 1
    Assert ((Get-Content -Raw -LiteralPath $freshConfig | ConvertFrom-Json).activeWorkspace -eq 'fresh') 'First-run selection saved as JSON'

    # Nested repositories are not silently staged as embedded Git links.
    Remove-Item -LiteralPath (Join-Path $bad 'invalid.js')
    [void](Git $bad @('init', '-b', 'main', 'nested'))
    [void](Git (Join-Path $bad 'nested') @('config', 'user.name', 'Integration Test'))
    [void](Git (Join-Path $bad 'nested') @('config', 'user.email', 'test@example.invalid'))
    Put (Join-Path $bad 'nested') 'inner.txt' 'nested'
    [void](Git (Join-Path $bad 'nested') @('add', '-A'))
    [void](Git (Join-Path $bad 'nested') @('commit', '-m', 'nested fixture'))
    Run-Sync @('-WorkspaceName', 'bad') 1
    Assert ((Git $bad @('ls-files', 'nested')) -eq '') 'Untracked nested repository not turned into Git link'
    Put $bad '.gitignore' "/log/`n/config.local.json`nignored.txt`n/nested/`n"
    [void](Git $bad @('add', '.gitignore'))
    [void](Git $bad @('commit', '-m', 'ignore nested repo'))
    Run-Sync @('-WorkspaceName', 'bad')
    Assert ((Git $bad @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')) -match '^0\s+0$') 'Ignoring nested repository permits parent synchronization'

    # Explicit submodules are skipped; changed submodules block parent staging.
    [void](Git $bad @('-c', 'protocol.file.allow=always', 'submodule', 'add', "$a.git", 'module'))
    [void](Git $bad @('commit', '-m', 'add submodule'))
    [void](Git $bad @('push'))
    Put (Join-Path $bad 'module') 'untracked.txt' 'submodule work'
    [void](Git $bad @('config', 'submodule.module.ignore', 'all'))
    Run-Sync @('-WorkspaceName', 'bad') 1
    Assert ((Git $bad @('diff', '--cached', '--name-only')) -eq '') 'Changed submodule does not get staged even when configured as ignored'
    $moduleWorkspace = Join-Path $temp 'module.code-workspace'
    Put $temp 'module.code-workspace' (@{ folders = @(@{ path = 'bad/module' }, @{ path = 'repo with spaces' }) } | ConvertTo-Json -Depth 4)
    Run-Sync @('-WorkspacePath', $moduleWorkspace, '-WorkspaceName', 'module')
    Assert ([IO.File]::ReadAllText((Join-Path $bad 'module/untracked.txt')) -eq 'submodule work') 'Explicit submodule folder skipped without modifying its work'

    # Git worktrees and local file URIs are supported.
    $worktree = Join-Path $temp 'linked-worktree'
    [void](Git $a @('worktree', 'add', '-b', 'linked', $worktree))
    [void](Git $worktree @('push', '-u', 'origin', 'linked'))
    $uriWorkspace = Join-Path $temp 'uri.code-workspace'
    Put $temp 'uri.code-workspace' (@{ folders = @(@{ uri = [uri]::new($worktree, [UriKind]::Absolute).AbsoluteUri }) } | ConvertTo-Json -Depth 4)
    Put $worktree 'worktree.js' 'console.log("worktree");'
    Run-Sync @('-WorkspacePath', $uriWorkspace, '-WorkspaceName', 'uri')
    Assert ((Git $worktree @('rev-list', '--left-right', '--count', 'HEAD...@{upstream}')) -match '^0\s+0$') 'Git worktree with file URI synchronized'

    # The tool is outside this workspace: publication cannot commit unrelated edits.
    Put $tool 'unrelated.txt' 'leave this alone'
    Run-Sync @('-WorkspaceName', 'uri') 1
    Assert ((Git $tool @('ls-files', 'unrelated.txt')) -eq '') 'Log-only publication preserves unrelated tool changes'
    $receipt = Get-ChildItem -LiteralPath (Join-Path $tool 'log') -Filter '*.publication.json' |
        Sort-Object LastWriteTimeUtc | Select-Object -Last 1
    Assert (-not (Get-Content -Raw -LiteralPath $receipt.FullName | ConvertFrom-Json).success) 'Publication failure recorded in local receipt'
    Remove-Item -LiteralPath (Join-Path $tool 'unrelated.txt')

    # A rejected push is a failure; raw hook output must not appear in saved logs.
    if (-not $IsWindows) {
        Put "$a.git" 'hooks/pre-receive' "#!/bin/sh`necho 'secret-example-token' >&2`nexit 1`n"
        & chmod u+x (Join-Path "$a.git" 'hooks/pre-receive')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot enable rejection hook.' }
        Put $worktree 'rejected.txt' 'local commit stays'
        Run-Sync @('-WorkspaceName', 'uri') 1
        Assert ((Git $worktree @('ls-files', 'rejected.txt')) -ne '') 'Rejected push retains local commit'
        $allLogs = Get-ChildItem -LiteralPath (Join-Path $tool 'log') -Filter '*.json' |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) }
        Assert (($allLogs -join "`n") -notmatch 'secret-example-token') 'Raw Git hook output excluded from logs'
    }
    Write-Host "All $checks assertions passed."
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
