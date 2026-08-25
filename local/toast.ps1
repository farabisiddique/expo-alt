# expo-alt :: toast.ps1  -  Windows-side wrapper for the VPS `cook` script.
# PowerShell 5.1 compatible (no &&, no ternary).
#
# ============================== INSTALL ======================================
#
# 1) Create an SSH host alias on your PC so `ssh kitchen` works. Edit (or
#    create) the file  C:\Users\<you>\.ssh\config  and add:
#
#        Host kitchen
#            HostName <VPS_IP_OR_DOMAIN>
#            User <VPS_SSH_USER>
#            IdentityFile ~/.ssh/id_ed25519
#
#    (Generate a key with `ssh-keygen -t ed25519` if you don't have one, and
#    put the .pub contents into ~/.ssh/authorized_keys on the VPS.)
#    Test it:  ssh kitchen "echo ok"
#
# 2) Add these functions to your PowerShell profile. Either:
#
#    a) Dot-source this file from your profile. Open the profile:
#           notepad $PROFILE
#       (If it doesn't exist: New-Item -ItemType File -Force $PROFILE)
#       Add this line, adjusting the path to wherever you keep this file:
#           . "D:\PROJECTS\EXPO Projects\expo-alt\local\toast.ps1"
#
#    b) Or paste the functions below directly into $PROFILE.
#
# 3) Reload:  . $PROFILE     (or open a new terminal)
#
# ============================== USAGE ========================================
#
#   toast <repo-name> [profile] [ref] [-NoCheck]
#       toast myapp                    # profile "preview", ref "main"
#       toast myapp production         # profile "production"
#       toast myapp preview develop    # build the "develop" branch
#       toast myapp -NoCheck           # skip the tsc gate
#
#   toast-push <repo-name> [profile] [ref] [-NoCheck]
#       `git push` from the current directory first, then toast.
#
# Output streams live (ssh -t). The remote exit code is passed through in
# $LASTEXITCODE, so `toast myapp; if ($LASTEXITCODE -eq 0) { ... }` works.
# =============================================================================

# Name of the Host entry in your ~/.ssh/config (step 1 above).
$script:ToastVpsAlias = "kitchen"

function toast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Repo,

        # NOTE: named BuildProfile because $Profile is a PowerShell automatic
        # variable (path to your profile script) and must not be shadowed.
        [Parameter(Position = 1)]
        [string]$BuildProfile = "preview",

        [Parameter(Position = 2)]
        [string]$Ref = "",

        [switch]$NoCheck
    )

    $remoteCmd = "cook $Repo $BuildProfile"
    if ($Ref -ne "") {
        $remoteCmd = "$remoteCmd $Ref"
    }
    if ($NoCheck) {
        $remoteCmd = "$remoteCmd --no-check"
    }

    Write-Host ("toast: ssh {0} `"{1}`"" -f $script:ToastVpsAlias, $remoteCmd) -ForegroundColor Cyan

    # -t allocates a pseudo-tty so the build output streams live line by line.
    # ssh exits with the remote command's exit code; it lands in $LASTEXITCODE
    # and is left untouched so callers/scripts can check it.
    ssh -t $script:ToastVpsAlias $remoteCmd

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
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Repo,

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
