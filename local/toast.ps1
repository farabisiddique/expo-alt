# expo-alt :: toast.ps1  -  Windows-side wrapper for the VPS `cook` script.
# PowerShell 5.1 compatible (no &&, no ternary).
#
# ============================== INSTALL ======================================
#
# 1) Fill in the .env file at the root of this project (copy .env.example to
#    .env if it doesn't exist). toast reads VPS_SSH_USER + VPS_IP_OR_DOMAIN
#    from it, so with a default-path SSH key (~/.ssh/id_ed25519) no ssh config
#    is needed at all.
#
#    Optional: if you prefer an ~/.ssh/config Host alias (custom key/port),
#    create one and put its name in VPS_SSH_ALIAS in .env:
#
#        Host kitchen
#            HostName <VPS_IP_OR_DOMAIN>
#            User <VPS_SSH_USER>
#            IdentityFile ~/.ssh/id_ed25519
#
#    Either way, key-based login must work first. If you don't have a key:
#        ssh-keygen -t ed25519
#    then append the contents of ~/.ssh/id_ed25519.pub to
#    ~/.ssh/authorized_keys on the VPS. Test:  ssh <user>@<vps> "echo ok"
#
# 2) Add these functions to your PowerShell profile. Open the profile:
#        notepad $PROFILE
#    (If it doesn't exist: New-Item -ItemType File -Force $PROFILE)
#    Add this line, adjusting the path to wherever you cloned this repo:
#        . "D:\PROJECTS\EXPO Projects\expo-alt\local\toast.ps1"
#
# 3) Reload:  . $PROFILE     (or open a new terminal)
#
# ============================== USAGE ========================================
#
#   toast [repo-name] [profile] [ref] [-NoCheck]
#       toast                          # inside your app's folder: repo is
#                                      # auto-detected from `git remote origin`,
#                                      # and the CURRENT BRANCH is built (warns
#                                      # if you have unpushed commits)
#       toast myapp                    # explicit repo, profile "preview"
#       toast myapp production         # profile "production"
#       toast myapp preview develop    # build the "develop" branch
#       toast friend/theirapp          # a repo you collaborate on (owner/name)
#       toast -BuildProfile production # auto-detected repo, chosen profile
#       toast myapp -NoCheck           # skip the tsc gate
#
#   toast-push [repo-name] [profile] [ref] [-NoCheck]
#       `git push` from the current directory first, then toast
#       (repo auto-detected the same way when omitted).
#
# Output streams live (ssh -t). The remote exit code is passed through in
# $LASTEXITCODE, so `toast myapp; if ($LASTEXITCODE -eq 0) { ... }` works.
# =============================================================================

# Repo root = parent of the local/ directory this script lives in.
$script:ToastRepoRoot = Split-Path -Parent $PSScriptRoot

function Get-ToastEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)
    $envFile = Join-Path $script:ToastRepoRoot ".env"
    if (-not (Test-Path $envFile)) {
        return ""
    }
    # Matches:  KEY=value  or  KEY="value"  (leading whitespace tolerated)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*"?([^"]*)"?\s*$'
    foreach ($line in (Get-Content $envFile)) {
        if ($line -match $pattern) {
            return $Matches[1].Trim()
        }
    }
    return ""
}

function Get-ToastRepoFromGit {
    # Returns "owner/name" parsed from the current directory's `origin`
    # remote, or "" if this isn't a git repo / origin isn't on github.com.
    $url = ""
    try { $url = (git remote get-url origin 2>$null | Select-Object -First 1) } catch {}
    if (-not $url) { return "" }
    $url = "$url".Trim()
    # Handles: git@github.com:owner/name.git, https://github.com/owner/name(.git),
    #          ssh://git@github.com/owner/name.git
    if ($url -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$') {
        return ($Matches[1] + "/" + $Matches[2])
    }
    return ""
}

function Get-ToastSshTarget {
    # Read on every call so .env edits apply without reloading the profile.
    $alias = Get-ToastEnvValue "VPS_SSH_ALIAS"
    if ($alias -ne "") {
        return $alias
    }
    $sshUser = Get-ToastEnvValue "VPS_SSH_USER"
    $vpsHost = Get-ToastEnvValue "VPS_IP_OR_DOMAIN"
    if ($sshUser -ne "" -and $vpsHost -ne "") {
        return "$sshUser@$vpsHost"
    }
    return ""
}

function toast {
    [CmdletBinding()]
    param(
        # Optional: when omitted, detected from the current directory's git
        # remote (run `toast` inside your app's folder).
        [Parameter(Position = 0)]
        [string]$Repo = "",

        # NOTE: named BuildProfile because $Profile is a PowerShell automatic
        # variable (path to your profile script) and must not be shadowed.
        [Parameter(Position = 1)]
        [string]$BuildProfile = "preview",

        [Parameter(Position = 2)]
        [string]$Ref = "",

        [switch]$NoCheck
    )

    if ($Repo -eq "") {
        $Repo = Get-ToastRepoFromGit
        if ($Repo -eq "") {
            Write-Host "toast: no repo given and none detected here." -ForegroundColor Red
            Write-Host "toast: run this inside your app's git folder (with a github.com 'origin' remote)," -ForegroundColor Red
            Write-Host "toast: or name the repo explicitly:  toast <repo-name>" -ForegroundColor Red
            return
        }
        Write-Host ("toast: repo detected from this folder's git remote: {0}" -f $Repo) -ForegroundColor Cyan

        # Same folder => also build the branch you're standing on (unless -Ref
        # was given). Skipped for a detached HEAD, where cook's default applies.
        if ($Ref -eq "") {
            $branch = ""
            try { $branch = (git rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1) } catch {}
            $branch = "$branch".Trim()
            if ($branch -ne "" -and $branch -ne "HEAD") {
                $Ref = $branch
                Write-Host ("toast: branch detected: {0}" -f $Ref) -ForegroundColor Cyan
            }
        }

        # The VPS builds what is on GitHub, not what is on this disk.
        $ahead = ""
        try { $ahead = (git rev-list --count "@{u}..HEAD" 2>$null | Select-Object -First 1) } catch {}
        $ahead = "$ahead".Trim()
        if ($ahead -match '^\d+$' -and [int]$ahead -gt 0) {
            Write-Host ("toast: WARNING: {0} unpushed commit(s) on this branch - the VPS builds what is on GitHub. Use toast-push, or git push first." -f $ahead) -ForegroundColor Yellow
        }
    }

    $target = Get-ToastSshTarget
    if ($target -eq "") {
        Write-Host "toast: no VPS configured. Fill in VPS_SSH_USER and VPS_IP_OR_DOMAIN" -ForegroundColor Red
        Write-Host ("toast: (or VPS_SSH_ALIAS) in: {0}" -f (Join-Path $script:ToastRepoRoot ".env")) -ForegroundColor Red
        return
    }

    $remoteCmd = "cook $Repo $BuildProfile"
    if ($Ref -ne "") {
        $remoteCmd = "$remoteCmd $Ref"
    }
    if ($NoCheck) {
        $remoteCmd = "$remoteCmd --no-check"
    }

    Write-Host ("toast: ssh {0} `"{1}`"" -f $target, $remoteCmd) -ForegroundColor Cyan

    # -t allocates a pseudo-tty so the build output streams live line by line.
    # ssh exits with the remote command's exit code; it lands in $LASTEXITCODE
    # and is left untouched so callers/scripts can check it.
    ssh -t $target $remoteCmd

    if ($LASTEXITCODE -eq 0) {
        Write-Host "toast: build finished OK" -ForegroundColor Green
    }
    else {
        Write-Host ("toast: remote build failed (exit {0})" -f $LASTEXITCODE) -ForegroundColor Red
    }
}

function toast-push {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Repo = "",

        [Parameter(Position = 1)]
        [string]$BuildProfile = "preview",

        [Parameter(Position = 2)]
        [string]$Ref = "",

        [switch]$NoCheck
    )

    Write-Host "toast-push: git push" -ForegroundColor Cyan
    git push
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("toast-push: git push failed (exit {0}); not building" -f $LASTEXITCODE) -ForegroundColor Red
        return
    }

    toast @PSBoundParameters
}
