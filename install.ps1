# OpenUsage one-line installer for Windows (Windows PowerShell 5.1 or PowerShell 7+):
#
#   irm https://raw.githubusercontent.com/CariSoftwareBR/OpenUsage/main/install.ps1 | iex
#
# Installs everything the widget needs without asking (Node.js LTS when node is
# missing or older than 22.6, and Git so Settings -> Update now works, both with
# winget), downloads OpenUsage into %LOCALAPPDATA%\OpenUsage, puts the OpenUsage
# icon on the desktop and opens the widget. Idempotent: running it again updates
# an existing install. Mirrors the Windows steps of Installation.md. Never calls
# `exit`: under `irm | iex` that would close the user's PowerShell window.

function Test-OpenUsageNode {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $false }
    try {
        $v = (& node -v 2>$null)
        return ([version]("$v".Trim().TrimStart('v')) -ge [version]'22.6.0')
    } catch { return $false }
}

function Update-OpenUsageSessionPath {
    # Pick up PATH entries that installers just wrote to the registry.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $seen = @{}
    $merged = foreach ($p in (@($machine -split ';') + @($user -split ';') + @($env:Path -split ';'))) {
        if ($p -and -not $seen.ContainsKey($p.ToLower())) { $seen[$p.ToLower()] = $true; $p }
    }
    $env:Path = ($merged -join ';')
}

function Test-OpenUsageFolder([string]$dir) {
    # Only a folder that is empty or holds OpenUsage may be replaced.
    if (Test-Path (Join-Path $dir 'scripts\usage-json.ts')) { return $true }
    return -not (Get-ChildItem -Force -LiteralPath $dir -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Install-OpenUsage {
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on 5.1
    # Windows PowerShell 5.1 may default to TLS 1.0, which GitHub rejects.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    $repoUrl = 'https://github.com/CariSoftwareBR/OpenUsage.git'
    $zipUrl  = 'https://github.com/CariSoftwareBR/OpenUsage/archive/refs/heads/main.zip'
    $dir     = Join-Path $env:LOCALAPPDATA 'OpenUsage'
    $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

    Write-Host ''
    Write-Host '  OpenUsage installer'
    Write-Host ''

    # 1. Node.js >= 22.6 (the widget runs its scripts with it).
    if (-not (Test-OpenUsageNode)) {
        if (-not $hasWinget) {
            Write-Host '  [X] Node.js >= 22.6 not found and winget is not available to install it.' -ForegroundColor Red
            Write-Host '      Install Node.js LTS from https://nodejs.org and run this installer again.'
            Write-Host ''
            return
        }
        Write-Host '  Node.js >= 22.6 not found: installing Node.js LTS with winget...'
        winget install -e --id OpenJS.NodeJS.LTS --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
        Update-OpenUsageSessionPath
        if (-not (Test-OpenUsageNode)) {
            Write-Host '  [X] Could not install Node.js automatically.' -ForegroundColor Red
            Write-Host '      Install Node.js LTS from https://nodejs.org and run this installer again.'
            Write-Host ''
            return
        }
        Write-Host "  [OK] Node.js $(node -v) installed." -ForegroundColor Green
    }

    # 2. Git, so the widget can update itself. Not fatal: without it the ZIP is used.
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -and $hasWinget) {
        Write-Host '  Installing Git with winget (for Settings -> Update now)...'
        winget install -e --id Git.Git --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
        Update-OpenUsageSessionPath
    }
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

    # 3. Close a running widget: it would keep the old version, and its folder could not be replaced.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*usage-widget.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # 4. Get the code: git when available (updates via git pull), ZIP otherwise.
    if ((Test-Path (Join-Path $dir '.git')) -and $hasGit) {
        Write-Host "  Updating $dir (git pull)..."
        # fetch + merge of the upstream ref, not `git pull`: a widget checking for
        # updates at the same moment can rewrite FETCH_HEAD under a pull.
        git -C $dir fetch --quiet
        if ($LASTEXITCODE -eq 0) { git -C $dir merge --ff-only --quiet '@{u}' }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [X] git pull failed in $dir. Check 'git -C `"$dir`" status' and try again." -ForegroundColor Red
            return
        }
    } elseif ($hasGit) {
        # A copy from an earlier ZIP download is replaced by a clone, so Update now works from now on.
        if (Test-Path $dir) {
            if (-not (Test-OpenUsageFolder $dir)) {
                Write-Host "  [X] $dir exists and is not OpenUsage. Move it away and try again." -ForegroundColor Red
                return
            }
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  Cloning OpenUsage into $dir..."
        git clone --quiet $repoUrl $dir
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] git clone failed.' -ForegroundColor Red
            return
        }
    } else {
        if ((Test-Path $dir) -and -not (Test-OpenUsageFolder $dir)) {
            Write-Host "  [X] $dir exists and is not OpenUsage. Move it away and try again." -ForegroundColor Red
            return
        }
        Write-Host "  Downloading OpenUsage into $dir..."
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('openusage-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
        try {
            $zip = Join-Path $tmp 'OpenUsage-main.zip'
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $tmp -Force -ErrorAction Stop
            $extracted = Join-Path $tmp 'OpenUsage-main'
            if (-not (Test-Path (Join-Path $extracted 'widget\usage-widget.vbs'))) {
                throw 'Downloaded archive is incomplete.'
            }
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction Stop }
            Move-Item $extracted $dir -ErrorAction Stop
        } catch {
            Write-Host "  [X] Download failed: $($_.Exception.Message)" -ForegroundColor Red
            return
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    $vbs = Join-Path $dir 'widget\usage-widget.vbs'
    if (-not (Test-Path $vbs)) {
        Write-Host "  [X] $vbs is missing: the install is incomplete." -ForegroundColor Red
        return
    }

    # 5. Desktop shortcut (running again just overwrites it).
    try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenUsage.lnk'))
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = "`"$vbs`""
        $lnk.IconLocation = Join-Path $dir 'widget\openusage.ico'
        $lnk.Description = 'OpenUsage'
        $lnk.Save()
    } catch {
        Write-Host "  Could not create the desktop shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 6. Open the widget (no console window).
    Start-Process wscript.exe -ArgumentList "`"$vbs`""

    $version = 'unknown'
    try { $version = (Get-Content (Join-Path $dir 'package.json') -Raw | ConvertFrom-Json).version } catch {}

    Write-Host ''
    Write-Host "  [OK] OpenUsage $version installed in $dir" -ForegroundColor Green
    Write-Host '  The widget is open; the OpenUsage icon on the desktop opens it next time.'
    if (Test-Path (Join-Path $dir '.git')) {
        Write-Host '  Settings -> Update now keeps it current (or run this command again).'
    } else {
        Write-Host '  Installed without Git: run this command again to update.'
    }
    Write-Host ''
}

Install-OpenUsage
