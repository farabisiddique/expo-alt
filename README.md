# expo-alt — self-hosted Expo Android builds on your own VPS

A personal replacement for Expo's EAS cloud build service. You push code, type
`toast myapp` on your Windows PC, and your VPS builds the APK with
`eas build --local`, streaming every line to your terminal and finishing with a
download URL.

> **Fill in before use** — these placeholders appear throughout this README:
>
> | Placeholder          | Meaning                                    | Example              |
> |----------------------|--------------------------------------------|----------------------|
> | `<GITHUB_USER>`      | GitHub account/org that owns your app repos | `acme-apps`         |
> | `<VPS_IP_OR_DOMAIN>` | Public IP or domain of the VPS              | `203.0.113.7`       |
> | `<VPS_SSH_USER>`     | Linux user you SSH into on the VPS          | `deploy`            |

## Architecture

```
 ┌────────────────────┐         ┌──────────────────────────────────────────┐
 │  Windows PC        │         │  VPS (Ubuntu 22.04/24.04)  "the kitchen" │
 │                    │  ssh -t │                                          │
 │  > toast myapp ────┼────────▶│  /usr/local/bin/cook                     │
 │                    │         │    ├─ flock (one build per repo)         │
 │  (live build log   │◀────────┼────┤─ git fetch + hard reset             │
 │   streams back)    │  stdout │    ├─ npm ci / yarn / pnpm               │
 │                    │         │    ├─ npx tsc --noEmit   (quality gate)  │
 └────────────────────┘         │    ├─ eas build --local ──────────────┐  │
          ▲                     │    │      │ fetches keystore +        │  │
          │                     │    │      ▼ versionCode (EXPO_TOKEN)  │  │
          │                     │    │   expo.dev (free account)        │  │
          │  http(s) download   │    └─ mv APK ─▶ /var/www/builds/<id>/ ◀┘ │
          │                     │                        │                 │
   DOWNLOAD: http://<VPS>/      │                     nginx :80            │
     builds/ab12cd34/           │            serves /builds/ (no index)    │
     myapp-1.2.3-....apk        └──────────────────────────────────────────┘

 GitHub (private repo) ◀── read-only deploy key ── VPS git fetch
```

The APK is **identical to an EAS cloud build**: `eas build --local` still
authenticates to Expo's servers with your `EXPO_TOKEN` to fetch the Android
signing keystore and the remote `versionCode`, then builds on your hardware.

## Requirements (honest numbers)

- **VPS**: 2+ vCPU, **8 GB RAM** — or 4 GB + swap (the setup script creates a
  4 GB swap file automatically; builds work but are slower). **~35 GB free
  disk**: Android SDK + NDK ≈ 12 GB, Gradle caches grow to ~10 GB, plus
  node_modules per repo and the built APKs.
- **App repo**: Expo SDK app (this setup targets SDK 57 / RN 0.86) with an
  `eas.json` containing the profile you build, configured to produce an APK:

  ```json
  {
    "build": {
      "preview": {
        "android": { "buildType": "apk" }
      }
    }
  }
  ```

  Local Expo native modules (`modules/`) and config plugins are fine —
  `--local` runs prebuild the same way the cloud does. Nothing on the VPS ever
  mutates your repo's files.
- **Expo account**: free tier is enough. You need an access token.
- **Windows PC**: OpenSSH client (built into Windows 10/11), PowerShell 5.1+.

**Build time expectations**: first build (cold caches) ~15 min. Subsequent
builds ~4–7 min — the VPS keeps warm Gradle (`~/.gradle`) and npm (`~/.npm`)
caches between builds, which is a key advantage over cold cloud builders.

## Setup, in order

### 0. Fill in your `.env`

```powershell
copy .env.example .env      # then open .env and fill in the values
```

`.env` is gitignored — your values stay local. `toast` reads the VPS address
and user from it; if you also scp it to the repo root on the VPS,
`setup-kitchen.sh` prefills `GITHUB_USER` and `BUILD_URL_BASE` from it.
(`EXPO_TOKEN` deliberately does **not** go in `.env` — you enter it on the
VPS when the setup script prompts.)

### 1. Copy the files to the VPS and provision it

From this project directory on your PC:

```powershell
scp vps/setup-kitchen.sh vps/cook <VPS_SSH_USER>@<VPS_IP_OR_DOMAIN>:~/
ssh <VPS_SSH_USER>@<VPS_IP_OR_DOMAIN>
```

On the VPS:

```bash
chmod +x ~/setup-kitchen.sh
bash ~/setup-kitchen.sh
```

The script is idempotent — re-run it any time. Run it interactively and it
will prompt for your `EXPO_TOKEN` (input hidden), `GITHUB_USER`, and
`BUILD_URL_BASE`. It ends by printing a **deploy public key** and a self-check
summary.

### 2. Add the deploy key to your app repo

GitHub → your app repo → **Settings → Deploy keys → Add deploy key** → paste
the printed public key. Leave **"Allow write access" unchecked** (read-only).

> **Multiple repos**: GitHub allows a deploy key on only *one* repo. For more
> repos either (a) generate additional keys on the VPS
> (`ssh-keygen -t ed25519 -f ~/.ssh/expo_alt_deploy_repo2`) and add per-repo
> `Host` aliases in `~/.ssh/config`, or (b) attach the one key to a dedicated
> GitHub machine account that has read access to all your app repos — the
> simplest option.

Verify from the VPS: `ssh -T git@github.com` → "successfully authenticated".

### 3. Check the config file

`~/.config/expo-alt/env` (chmod 600) must contain:

```bash
EXPO_TOKEN="..."        # expo.dev → Account settings → Access tokens
GITHUB_USER="<GITHUB_USER>"
BUILD_URL_BASE="http://<VPS_IP_OR_DOMAIN>"   # no trailing slash
# optional: RETENTION_DAYS=14  MAX_BUILDS=20  LOG_RETENTION_DAYS=60
```

### 4. Install `cook`

```bash
sudo install -m 755 ~/cook /usr/local/bin/cook
```

Smoke-test directly on the VPS: `cook myapp` (or `cook myapp production develop`).

### 5. Install `toast` on your PC

1. Make sure key-based SSH to the VPS works
   (`ssh <VPS_SSH_USER>@<VPS_IP_OR_DOMAIN> "echo ok"` without a password
   prompt — if not: `ssh-keygen -t ed25519` and append the `.pub` contents to
   `~/.ssh/authorized_keys` on the VPS). `toast` builds the ssh target from
   your `.env` (`VPS_SSH_USER@VPS_IP_OR_DOMAIN`), so no ssh config is needed.
   If you prefer an `~/.ssh/config` `Host` alias (custom key/port), create
   one and put its name in `VPS_SSH_ALIAS` in `.env`.

2. Add [local/toast.ps1](local/toast.ps1) to your PowerShell profile:

   ```powershell
   notepad $PROFILE     # create with: New-Item -ItemType File -Force $PROFILE
   # add this line (adjust the path):
   . "D:\PROJECTS\EXPO Projects\expo-alt\local\toast.ps1"
   ```

3. Reload with `. $PROFILE` or open a new terminal.

### 6. First build

```powershell
toast myapp                  # profile "preview", ref "main"
toast myapp production       # different profile
toast myapp preview develop  # different branch
toast friend/theirapp        # a repo you collaborate on (owner/name form)
toast-push myapp             # git push (from the app repo dir), then build
```

On success the last line printed — and the last line of the saved log on the
VPS — is:

```
DOWNLOAD: http://<VPS_IP_OR_DOMAIN>/builds/ab12cd34/myapp-1.2.3-20260825-1412.apk
```

Open that URL on the phone to install the APK.

## Security notes

- **Deploy key is read-only and per-repo.** The VPS can fetch your code but
  never push. Compromise of the VPS exposes read access to that repo only.
- **`EXPO_TOKEN`** lives in `~/.config/expo-alt/env` with `chmod 600`, is never
  echoed by the scripts, and never appears in build logs.
- **Download URLs are unguessable** (8-hex-char random path, nginx `autoindex
  off` so the directory can't be listed) — but they are *not* authenticated:
  anyone you give a link to can download until retention deletes it
  (14 days / 20 builds by default). Use HTTPS (put the VPS behind a domain +
  certbot) if the APK contents are sensitive in transit.
- **Harden SSH**: key-auth only (`PasswordAuthentication no` in
  `/etc/ssh/sshd_config`), and consider fail2ban/ufw (allow 22, 80, 443).
- Never commit `~/.config/expo-alt/env`, the deploy key, or logs to any repo.

## What runs where (retention)

- `~/kitchen/repos/<repo>` — disposable working copies (hard-reset each build).
- `~/kitchen/logs/<repo>-<UTC>.log` — full build logs, pruned after 60 days.
- `/var/www/builds/<random-id>/<name>-<version>-<stamp>.apk` — served by
  nginx; dirs older than 14 days deleted, at most 20 newest kept. All three
  limits are configurable in the env file.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Gradle dies with `Killed`, exit 137, or "GC overhead limit" | **Out of memory.** Confirm swap: `swapon --show`. Re-run `setup-kitchen.sh` (creates 4 G swap when RAM < 8 GB). `cook` already sets `NODE_OPTIONS=--max_old_space_size=4096`. |
| `Failed to install the following Android SDK packages ... licenses` | Run `yes \| ~/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses`, or re-run `setup-kitchen.sh`. |
| `eas: profile "X" not found` | Your app repo's `eas.json` has no `build.X` profile on the ref you built. Check the branch you actually pushed. |
| `EXPO_TOKEN is not set` / `Not logged in` / 401 from Expo | Token missing or expired. Create a new one at expo.dev → Account settings → Access tokens, put it in `~/.config/expo-alt/env`. |
| nginx **403** on the download URL | Permissions: `sudo chmod 755 /var/www/builds/<id>` and `644` on the APK; parent dirs need `o+x`. `cook` sets these — a 403 usually means the dir was created manually. |
| nginx **404** on the download URL | The build dir was already pruned by retention, `BUILD_URL_BASE` points at the wrong host, or the nginx site/snippet isn't enabled (`sudo nginx -t`, check `/etc/nginx/sites-enabled/`, see setup script output for the `include` instruction if you had a pre-existing site). |
| `another build of "X" is already running` but nothing is | The lock is a kernel `flock` — it is released the instant the holding process dies, so a *stale* lock is impossible. If you see this, the process is real: check the printed pid (`ps -p <pid>`). A hung build can be killed with `kill <pid>`; the lock frees itself. |
| Disk full | Space goes to `~/.gradle` (Gradle caches, can exceed 10 GB — safe to delete, next build is just slower), `~/kitchen/repos/*/node_modules`, `~/android-sdk`, `/var/www/builds`, and `/tmp` leftovers from failed eas runs (`rm -rf /tmp/eas-build-local-*`). `df -h` and `du -xsh ~/.gradle ~/kitchen /var/www/builds` to see where. |
| `ssh -T git@github.com` fails from the VPS | Deploy key not added to the repo, or `~/.ssh/config` entry missing. Re-run `setup-kitchen.sh` to reprint the public key. |
| Windows: `toast` not recognized | Profile not loaded — `. $PROFILE`, and check the dot-source path in it. |

## Files in this project

| File | Purpose | Install location |
|---|---|---|
| [vps/setup-kitchen.sh](vps/setup-kitchen.sh) | One-time idempotent VPS provisioning | run from `~` on the VPS |
| [vps/cook](vps/cook) | The build script | `/usr/local/bin/cook` on the VPS |
| [local/toast.ps1](local/toast.ps1) | `toast` / `toast-push` PowerShell wrappers | dot-sourced from `$PROFILE` on the PC |
