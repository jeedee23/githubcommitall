#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [string]$WorkspaceName,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config.local.json'),
    [switch]$Configure,
    [switch]$DryRun,
    [switch]$SkipPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'
$runId = "$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$results = [Collections.Generic.List[object]]::new()

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments, [int[]]$Allowed = @(0))
    $info = [Diagnostics.ProcessStartInfo]::new('git')
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.ArgumentList.Add('--no-pager')
    $info.ArgumentList.Add('-c')
    $info.ArgumentList.Add('submodule.recurse=false')
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not [IO.Directory]::Exists($Root)) { throw "Repository folder does not exist: $Root" }
        try { [void]$process.Start() }
        catch { throw 'Cannot start Git. Check installation and repository permissions locally.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -notin $Allowed) {
            # Raw Git output can contain credential-bearing URLs; keep it out of logs.
            throw "Git $($Arguments[0]) failed (exit $($process.ExitCode)). Inspect this repository locally for details."
        }
        return [pscustomobject]@{ Output = $output; Error = $errorText; ExitCode = $process.ExitCode }
    }
    finally { $process.Dispose() }
}

function Read-Json {
    param([string]$Path)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $true
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Skip
    try {
        $document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Path), $options)
        try { return ConvertFrom-Json -InputObject $document.RootElement.GetRawText() -AsHashtable }
        finally { $document.Dispose() }
    }
    catch { throw "Cannot read JSON/JSONC file '$Path'. Check its syntax and permissions locally." }
}

function Get-Configuration {
    $config = @{ version = 1; workspaces = @(); activeWorkspace = ''; jsonTimestampRules = @() }
    if (Test-Path -LiteralPath $ConfigPath) {
        $config = Read-Json $ConfigPath
        if ($config.version -ne 1 -or -not $config.ContainsKey('workspaces') -or
            -not $config.ContainsKey('jsonTimestampRules')) {
            throw 'Unsupported local configuration. See README.md for the version 1 schema.'
        }
    }
    if ($Configure -or $WorkspacePath -or $config.workspaces.Count -eq 0) {
        if (-not $WorkspacePath) { $script:WorkspacePath = Read-Host 'Path to the VS Code .code-workspace file' }
        $path = (Resolve-Path -LiteralPath $WorkspacePath).Path
        if ([IO.Path]::GetExtension($path) -ne '.code-workspace') { throw 'Select a .code-workspace file.' }
        if (-not $WorkspaceName) {
            $script:WorkspaceName = Read-Host 'Workspace name (blank uses the file name)'
            if (-not $WorkspaceName) { $script:WorkspaceName = [IO.Path]::GetFileNameWithoutExtension($path) }
        }
        [void](Read-Json $path)
        $config.workspaces = @($config.workspaces | Where-Object { $_.name -ne $WorkspaceName })
        $config.workspaces += @{ name = $WorkspaceName; path = $path }
        $config.activeWorkspace = $WorkspaceName
        if (-not $DryRun) {
            $configFullPath = [IO.Path]::GetFullPath($ConfigPath)
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($configFullPath))
            [IO.File]::WriteAllText($configFullPath, ($config | ConvertTo-Json -Depth 10) + "`n")
        }
    }
    $name = if ($WorkspaceName) { $WorkspaceName } else { $config.activeWorkspace }
    $selection = @($config.workspaces | Where-Object { $_.name -eq $name })
    if ($selection.Count -ne 1) { throw "Workspace selection '$name' is missing or ambiguous. Run with -Configure." }
    return @{ Name = $name; Path = $selection[0].path; Rules = @($config.jsonTimestampRules) }
}

function Resolve-WorkspaceFolder {
    param([hashtable]$Folder, [string]$Base)
    if ($Folder.ContainsKey('path')) {
        $path = [regex]::Replace([string]$Folder.path, '\$\{env:([^}]+)\}', {
            param($match)
            $value = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
            if ($null -eq $value) { throw "Workspace environment variable '$($match.Groups[1].Value)' is unset." }
            return $value
        })
        $path = $path.Replace('${userHome}', [Environment]::GetFolderPath('UserProfile'))
        if ($path.Contains('${')) { throw 'Unsupported variable in workspace folder path.' }
        return [IO.Path]::GetFullPath($path, $Base)
    }
    if ($Folder.ContainsKey('uri')) {
        $uri = $null
        if (-not [uri]::TryCreate([string]$Folder.uri, [UriKind]::Absolute, [ref]$uri) -or
            -not $uri.IsFile -or ($uri.Host -and $uri.Host -ne 'localhost')) {
            throw 'Only local file workspace URIs are supported. Run the tool in the filesystem hosting the repositories.'
        }
        return $uri.LocalPath
    }
    throw 'Workspace folder has neither a path nor a local file URI.'
}

function Get-Changes {
    param([string]$Root)
    $entries = (Invoke-Git $Root @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none')).Output.Split([char]0)
    $changes = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $entries.Length; $i++) {
        if (-not $entries[$i]) { continue }
        $status = $entries[$i].Substring(0, 2)
        $changes.Add([pscustomobject]@{ Status = $status; Path = $entries[$i].Substring(3) })
        if ($status -match '[RC]') { $i++ }
    }
    return $changes.ToArray()
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $offset = 3
        $encoding = [Text.UTF8Encoding]::new($true, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
    }
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch { throw 'A timestamp-eligible file uses an unsupported or invalid encoding.' }
    if ($text.Contains([char]0)) { throw 'A timestamp-eligible file contains binary data.' }
    return @{ Text = $text; Encoding = $encoding }
}

function Write-TextFile {
    param([string]$Path, [hashtable]$File, [string]$Text)
    $preamble = $File.Encoding.GetPreamble()
    $body = $File.Encoding.GetBytes($Text)
    [IO.File]::WriteAllBytes($Path, [byte[]]($preamble + $body))
}

function Update-Timestamps {
    param([string]$Root, [object[]]$Changes, [object[]]$Rules)
    $count = 0
    foreach ($change in $Changes) {
        if ($change.Status -match 'D') { continue }
        $relative = $change.Path
        $path = Join-Path $Root $relative
        if (-not [IO.File]::Exists($path)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($item.LinkType) { continue }
        if ($relative -match '(^|/)(node_modules|vendor|dist|build|coverage|\.venv|venv)/') { continue }
        $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
        $prefix = switch ($extension) {
            { $_ -in '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.py', '.pyw' } { '#'; break }
            { $_ -in '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx' } { '//'; break }
            { $_ -in '.css', '.scss', '.less' } { '/*'; break }
            { $_ -in '.html', '.htm' } { '<!--'; break }
            default { $null }
        }
        if ($extension -eq '.json') {
            $matches = @($Rules | Where-Object {
                $_.repository -eq $Root -and $_.path -eq $relative
            })
            if ($matches.Count -eq 0) { continue }
            if ($matches.Count -ne 1) { throw "Duplicate JSON timestamp rules for '$relative'." }
            $rule = $matches[0]
            $file = Read-TextFile $path
            try { $json = ConvertFrom-Json -InputObject $file.Text -AsHashtable }
            catch { throw "Invalid JSON in approved timestamp file '$relative'." }
            if ($json -isnot [Collections.IDictionary] -or -not $json.Contains($rule.field) -or
                $json[$rule.field] -isnot [string]) {
                throw "JSON timestamp field must be an existing top-level string in '$relative'."
            }
            # Reject duplicate approved keys before serialization can collapse them.
            $options = [Text.Json.JsonDocumentOptions]::new()
            $doc = [Text.Json.JsonDocument]::Parse($file.Text, $options)
            try {
                $properties = @($doc.RootElement.EnumerateObject() | Where-Object { $_.Name -eq $rule.field })
                if ($properties.Count -ne 1) { throw "Ambiguous JSON timestamp field in '$relative'." }
            }
            finally { $doc.Dispose() }
            $json[$rule.field] = $stamp
            $newline = if ($file.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $updated = ($json | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").Replace("`n", $newline)
            if ($file.Text.EndsWith("`n")) { $updated += $newline }
            Write-TextFile $path $file $updated
            $count++
            continue
        }
        if (-not $prefix) { continue }
        $file = Read-TextFile $path
        $newline = if ($file.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($line in [regex]::Split($file.Text, '\r?\n')) { $lines.Add($line) }
        $index = 0
        if ($lines.Count -gt 0 -and $lines[0].StartsWith('#!')) { $index = 1 }
        if ($extension -in '.py', '.pyw') {
            # Python encoding declarations must remain on the first or second line.
            for ($i = 0; $i -lt [Math]::Min(2, $lines.Count); $i++) {
                if ($lines[$i] -match '^[ \t]*#.*coding[:=][ \t]*([-\w.]+)') {
                    if ($Matches[1] -notin 'utf-8', 'utf8', 'utf_8', 'ascii', 'us-ascii') {
                        throw "Unsupported Python source encoding in '$relative'; convert it to UTF-8 first."
                    }
                    $index = [Math]::Max($index, $i + 1)
                }
            }
        }
        $suffix = switch ($prefix) { '/*' { ' */' }; '<!--' { ' -->' }; default { '' } }
        $oldStamp = '(?:\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}|\d{4}_\d{2}_\d{2}_@_\d{2}-\d{2}-\d{2})'
        $pattern = '^\s*' + [regex]::Escape($prefix) + '\s*' + $oldStamp + '\s*' + [regex]::Escape($suffix.Trim()) + '\s*$'
        while ($index -lt $lines.Count -and $lines[$index] -match $pattern) { $lines.RemoveAt($index) }
        $lines.Insert($index, "$prefix $stamp$suffix")
        Write-TextFile $path $file ([string]::Join($newline, $lines))
        $count++
    }
    return $count
}

function Sync-Repository {
    param([string]$Root, [object[]]$Rules, [string]$LogRelativePath, [switch]$LogOnly)
    $result = [ordered]@{
        repository = $Root; branch = $null; state = 'failed'; phase = 'preflight'
        changedFiles = 0; timestampedFiles = 0; commit = $null; pushed = $false
        ahead = $null; behind = $null; error = $null
    }
    try {
        $branch = (Invoke-Git $Root @('symbolic-ref', '--quiet', '--short', 'HEAD')).Output.Trim()
        $result.branch = $branch
        foreach ($marker in 'MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG') {
            $markerPath = (Invoke-Git $Root @('rev-parse', '--git-path', $marker)).Output.Trim()
            if (-not [IO.Path]::IsPathRooted($markerPath)) { $markerPath = Join-Path $Root $markerPath }
            if (Test-Path -LiteralPath $markerPath) { throw 'An unfinished Git operation exists; resolve it before running.' }
        }
        if ((Invoke-Git $Root @('rev-parse', '--verify', '--quiet', 'HEAD') @(0, 1)).ExitCode -ne 0) {
            throw "Branch '$branch' has no commits yet. Create and push the initial commit manually (git push --set-upstream <remote> $branch)."
        }
        $remoteConfig = Invoke-Git $Root @('config', '--get', "branch.$branch.remote") @(0, 1)
        $mergeConfig = Invoke-Git $Root @('config', '--get', "branch.$branch.merge") @(0, 1)
        if ($remoteConfig.ExitCode -ne 0 -or $mergeConfig.ExitCode -ne 0) {
            throw "Branch '$branch' has no upstream. Set one with: git push --set-upstream <remote> $branch."
        }
        $upstreamProbe = Invoke-Git $Root @('rev-parse', '--symbolic-full-name', '@{upstream}') @(0, 128)
        if ($upstreamProbe.ExitCode -ne 0) {
            throw "The upstream branch of '$branch' does not exist locally or remotely. Push the branch first (git push --set-upstream <remote> $branch)."
        }
        $upstream = $upstreamProbe.Output.Trim()
        $remote = $remoteConfig.Output.Trim()
        if ($remote -eq '.') { throw 'Local-only upstreams are not supported; configure a remote upstream.' }
        $changes = @(Get-Changes $Root)
        foreach ($change in $changes) {
            if ($change.Status -eq '??' -and
                (Test-Path -LiteralPath (Join-Path (Join-Path $Root $change.Path) '.git'))) {
                throw 'An untracked nested repository would become an embedded Git link. Ignore it in the parent repository or manage it explicitly first.'
            }
        }
        if ($LogOnly -and @($changes | Where-Object { $_.Path -ne $LogRelativePath }).Count) {
            throw 'The tool repository is outside the workspace and has local changes. Commit them or add it to the workspace before publishing logs.'
        }
        if (@($changes | Where-Object { $_.Status -match 'U|AA|DD' }).Count) { throw 'Unresolved index conflicts exist.' }
        $gitlinks = (Invoke-Git $Root @('ls-files', '--stage', '-z')).Output.Split([char]0) |
            Where-Object { $_ -match '^160000 ' } | ForEach-Object { $_.Substring($_.IndexOf("`t") + 1) }
        if (@($changes | Where-Object { $_.Path -in $gitlinks }).Count) {
            throw 'A submodule has changes. Synchronize it manually before running; submodules are not processed automatically.'
        }
        $result.changedFiles = $changes.Count
        if ($DryRun) { $result.state = 'dry-run'; return [pscustomobject]$result }
        $result.phase = 'fetch'
        [void](Invoke-Git $Root @('fetch', '--recurse-submodules=no', '--', $remote))
        $result.phase = 'timestamp'
        if (-not $LogOnly) { $result.timestampedFiles = Update-Timestamps $Root $changes $Rules }
        $result.phase = 'commit'
        if (-not $LogOnly) { [void](Invoke-Git $Root @('add', '-A', '--', '.')) }
        if ($LogRelativePath) { [void](Invoke-Git $Root @('add', '-f', '--', $LogRelativePath)) }
        $diff = Invoke-Git $Root @('diff', '--cached', '--quiet') @(0, 1)
        if ($diff.ExitCode -eq 1) {
            [void](Invoke-Git $Root @('commit', '-m', "Workspace sync $stamp", '-m',
                'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'))
            $result.commit = (Invoke-Git $Root @('rev-parse', 'HEAD')).Output.Trim()
        }
        $result.phase = 'merge'
        # Local work is committed first, so a failed merge never depends on stash recovery.
        $merge = Invoke-Git $Root @('-c', 'core.editor=true', 'merge', '--no-edit', '--no-autostash', $upstream) @(0, 1)
        if ($merge.ExitCode -ne 0) {
            $mergeHead = (Invoke-Git $Root @('rev-parse', '--git-path', 'MERGE_HEAD')).Output.Trim()
            if (-not [IO.Path]::IsPathRooted($mergeHead)) { $mergeHead = Join-Path $Root $mergeHead }
            if (Test-Path -LiteralPath $mergeHead) { [void](Invoke-Git $Root @('merge', '--abort')) }
            throw 'Upstream merge failed; local commits are preserved. Resolve the divergence manually.'
        }
        $result.phase = 'push'
        if (-not $SkipPush) {
            $remoteBranch = (Invoke-Git $Root @('config', '--get', "branch.$branch.merge")).Output.Trim()
            if (-not $remoteBranch.StartsWith('refs/heads/')) { throw 'The upstream is not a remote branch.' }
            [void](Invoke-Git $Root @('push', '--recurse-submodules=no', '--', $remote, "HEAD:$remoteBranch"))
            $result.pushed = $true
            [void](Invoke-Git $Root @('fetch', '--recurse-submodules=no', '--', $remote))
        }
        $result.phase = 'verify'
        $counts = (Invoke-Git $Root @('rev-list', '--left-right', '--count', "HEAD...$upstream")).Output.Trim() -split '\s+'
        $result.ahead = [int]$counts[0]
        $result.behind = [int]$counts[1]
        if (@(Get-Changes $Root).Count -ne 0) { throw 'Working tree is not clean after synchronization.' }
        if ($result.behind -ne 0 -or (-not $SkipPush -and $result.ahead -ne 0)) {
            throw 'Repository is not synchronized after the operation; the remote may have advanced.'
        }
        $result.state = if ($SkipPush) { 'local-only' } else { 'synchronized' }
        $result.phase = 'complete'
    }
    catch {
        $result.error = $_.Exception.Message
        Write-Warning "$Root [$($result.phase)]: $($result.error)"
    }
    return [pscustomobject]$result
}

$started = [DateTimeOffset]::Now
$exitCode = 0
$selection = $null
$logPath = $null
$roots = [Collections.Generic.HashSet[string]]::new(
    $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
try {
    [void](Get-Command git -ErrorAction Stop)
    $selection = Get-Configuration
    $workspace = Read-Json $selection.Path
    if (-not $workspace.ContainsKey('folders') -or $workspace.folders.Count -eq 0) { throw 'Workspace has no folders.' }
    foreach ($folder in $workspace.folders) {
        try {
            $path = Resolve-WorkspaceFolder $folder ([IO.Path]::GetDirectoryName($selection.Path))
            $probe = Invoke-Git $path @('rev-parse', '--show-toplevel') @(0, 128)
            if ($probe.ExitCode -eq 128) {
                Write-Host "Skipping non-repository workspace folder: $path"
                $results.Add([pscustomobject]@{ repository = $path; state = 'skipped'; error = $null })
                continue
            }
            $root = [IO.Path]::GetFullPath($probe.Output.Trim())
            $superproject = (Invoke-Git $root @('rev-parse', '--show-superproject-working-tree')).Output.Trim()
            if ($superproject) {
                Write-Host "Skipping submodule workspace folder: $root"
                $results.Add([pscustomobject]@{ repository = $root; state = 'skipped'; error = $null })
                continue
            }
            [void]$roots.Add($root)
        }
        catch {
            $exitCode = 1
            $results.Add([pscustomobject]@{ repository = $null; state = 'failed'; error = $_.Exception.Message })
            Write-Warning $_.Exception.Message
        }
    }
    foreach ($root in ($roots | Sort-Object)) {
        # The tool repo is processed last, including the completed batch log.
        if ($root -eq $toolRoot -and -not $DryRun) { continue }
        $result = Sync-Repository $root $selection.Rules
        $results.Add($result)
        if ($result.state -eq 'failed') { $exitCode = 1 }
    }
    if ($roots.Count -eq 0) { throw 'No Git repositories found in the selected workspace.' }
}
catch {
    $exitCode = 1
    $results.Add([pscustomobject]@{ repository = $null; state = 'failed'; error = $_.Exception.Message })
    Write-Warning $_.Exception.Message
}

if (-not $DryRun) {
    try {
        $logRelative = "log/$runId.json"
        $logPath = Join-Path $toolRoot $logRelative
        [void][IO.Directory]::CreateDirectory((Join-Path $toolRoot 'log'))
        $finished = [DateTimeOffset]::Now
        $log = [ordered]@{
            runId = $runId; started = $started.ToString('o'); finished = $finished.ToString('o')
            durationSeconds = ($finished - $started).TotalSeconds
            workspace = if ($selection) { $selection.Name } else { $null }
            success = ($exitCode -eq 0); skipPush = [bool]$SkipPush
            repositories = $results.ToArray()
            publication = 'Outcome recorded in the local publication receipt; this immutable log is published last.'
        }
        [IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 10) + "`n")
        $rules = if ($selection) { $selection.Rules } else { @() }
        $publication = Sync-Repository $toolRoot $rules $logRelative -LogOnly:(-not $roots.Contains($toolRoot))
        $results.Add($publication)
        if ($publication.state -eq 'failed') { $exitCode = 1 }
        $receipt = @{ runId = $runId; success = ($exitCode -eq 0); publication = $publication }
        [IO.File]::WriteAllText((Join-Path $toolRoot "log/$runId.publication.json"),
            ($receipt | ConvertTo-Json -Depth 10) + "`n")
        Write-Host "Log: $logPath"
    }
    catch {
        $exitCode = 1
        Write-Warning "Log publication failed: $($_.Exception.Message)"
    }
}
$results | Format-Table repository, state, phase, ahead, behind -AutoSize
exit $exitCode
