# Installing `toast` on another PC

`toast` is a PowerShell function defined in [local/toast.ps1](local/toast.ps1).
To use it on another Windows PC, copy the script, give that PC SSH access to
the VPS, and load the script from the PowerShell profile. Nothing needs to
change on the VPS except adding the new PC's SSH key.

## 1. Get the expo-alt folder onto the new PC

Clone the repo, or copy the folder over. The script looks for `.env` one
folder above `local/`, so keep this layout:

```
expo-alt\
  .env
  local\toast.ps1
```

## 2. Create `.env`

```powershell
cd "C:\path\to\expo-alt"
copy .env.example .env
notepad .env
```

Fill in `VPS_IP_OR_DOMAIN` and `VPS_SSH_USER`. Leave `EXPO_TOKEN` empty,
because it only belongs on the VPS. You can also just copy `.env` from your
current PC.

## 3. Set up SSH key login to the VPS

Windows 10/11 already include the `ssh` client. On the new PC, run:

```powershell
ssh-keygen -t ed25519          # press Enter at each prompt
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <VPS_SSH_USER>@<VPS_IP_OR_DOMAIN> "cat >> ~/.ssh/authorized_keys"
```

The second command asks for the password once. It will fail if password
login is turned off on the VPS. In that case, add the `.pub` line to
`~/.ssh/authorized_keys` on the VPS from a PC that already has access.

Then check that it works without a password:

```powershell
ssh <VPS_SSH_USER>@<VPS_IP_OR_DOMAIN> "echo ok"
```

## 4. Add `toast` to your PowerShell profile

```powershell
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force $PROFILE }
notepad $PROFILE
```

Add this line, using the path where you put the folder on that PC:

```powershell
. "C:\path\to\expo-alt\local\toast.ps1"
```

If PowerShell refuses to load the profile with a "running scripts is
disabled" error, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## 5. Reload and test

```powershell
. $PROFILE
toast myapp
```

## Notes

- Git must be installed if you want to run plain `toast` or `toast-push`
  inside an app folder (the repo and branch are detected from git). Without
  git, you can still name the repo yourself: `toast myapp`.
- `toast: not recognized` means the profile isn't loaded. Run `. $PROFILE`
  and check the path in it.
- `toast: no VPS configured` means `.env` is missing, empty, or not in the
  folder above `local\`.
