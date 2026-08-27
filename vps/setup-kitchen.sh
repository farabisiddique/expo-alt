#!/usr/bin/env bash
#
# expo-alt :: setup-kitchen.sh
#
# One-time provisioning of an Ubuntu 22.04/24.04 VPS as a self-hosted Expo
# Android build machine ("the kitchen"). Idempotent: safe to re-run at any time.
#
# Run as a regular user that has sudo rights (running as root also works,
# but a regular user is recommended):
#
#     bash setup-kitchen.sh
#
# What it does:
#   1. Installs git, curl, unzip, jq, Node.js 20, OpenJDK 17, nginx
#   2. Installs the Android SDK (cmdline-tools, platform-tools, android-35,
#      build-tools 35.0.0, NDK 27.1.12297006) into ~/android-sdk
#   3. Persists ANDROID_HOME / JAVA_HOME / PATH in ~/.bashrc and
#      /etc/profile.d/expo-alt.sh
#   4. Installs eas-cli globally
#   5. Creates a 4G swap file if RAM < 8GB and no swap exists
#   6. Creates ~/kitchen/{repos,logs,locks} and /var/www/builds
#   7. Configures nginx to serve /var/www/builds at /builds/ (no autoindex)
#   8. Creates ~/.config/expo-alt/env (chmod 600) and prompts for EXPO_TOKEN,
#      GITHUB_USER, BUILD_URL_BASE when run interactively
#   9. Generates an ed25519 GitHub deploy key and prints setup instructions
#  10. Prints a self-check summary
#
set -euo pipefail

# ------------------------------------------------------------------ constants

NODE_MAJOR=20
# The "latest" command-line-tools zip is versioned. If this URL ever 404s,
# grab the current one from https://developer.android.com/studio (scroll to
# "Command line tools only") and update it here.
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
SDK_PACKAGES=("platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.1.12297006")

ANDROID_HOME="$HOME/android-sdk"
CONF_DIR="$HOME/.config/expo-alt"
ENV_FILE="$CONF_DIR/env"
DEPLOY_KEY="$HOME/.ssh/expo_alt_deploy"
BUILDS_DIR="/var/www/builds"
SWAP_FILE="/swapfile"
PROFILE_D="/etc/profile.d/expo-alt.sh"
NGINX_SNIPPET="/etc/nginx/snippets/expo-alt-builds.conf"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/expo-alt-builds"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/expo-alt-builds"
NGINX_STOCK_DEFAULT="/etc/nginx/sites-enabled/default"

# ------------------------------------------------------------------ helpers

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  as_root() { "$@"; }
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required (or run as root)"
  as_root() { sudo "$@"; }
fi

# ------------------------------------------------------------------ OS check

log "Checking OS"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  warn "This script targets Ubuntu; detected '${ID:-unknown}'. Continuing anyway."
fi
case "${VERSION_ID:-}" in
  22.04|24.04) ok "Ubuntu ${VERSION_ID} detected" ;;
  *)           warn "Untested Ubuntu version '${VERSION_ID:-unknown}' (expected 22.04 or 24.04). Continuing." ;;
esac

# ------------------------------------------------------------------ base packages

log "Installing base packages (git, curl, unzip, jq, OpenJDK 17, nginx)"
as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl unzip zip ca-certificates jq openjdk-17-jdk-headless nginx >/dev/null
ok "base packages present"

# ------------------------------------------------------------------ Node.js 20

log "Installing Node.js ${NODE_MAJOR}"
need_node=1
if command -v node >/dev/null 2>&1; then
  node_ver="$(node -v)"; node_ver="${node_ver#v}"
  if [ "${node_ver%%.*}" -ge "$NODE_MAJOR" ]; then
    need_node=0
    ok "node ${node_ver} already installed"
  else
    warn "node ${node_ver} is too old; upgrading via NodeSource"
  fi
fi
if [ "$need_node" -eq 1 ]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | as_root bash - >/dev/null
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
  ok "node $(node -v) installed"
fi

# ------------------------------------------------------------------ JAVA_HOME

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_HOME
ok "JAVA_HOME = $JAVA_HOME"

# ------------------------------------------------------------------ Android SDK

log "Installing Android SDK into $ANDROID_HOME"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

if [ ! -x "$SDKMANAGER" ]; then
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/cmdline-tools.zip" "$CMDLINE_TOOLS_URL"
  unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp"
  ok "cmdline-tools installed"
else
  ok "cmdline-tools already installed"
fi

export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# Accept all licenses non-interactively. `yes` dies with SIGPIPE when
# sdkmanager closes stdin, which pipefail would treat as failure - hence the
# `|| true` inside the subshell.
log "Accepting Android SDK licenses"
(yes || true) | "$SDKMANAGER" --licenses >/dev/null 2>&1 || die "sdkmanager --licenses failed"
ok "licenses accepted"

for pkg in "${SDK_PACKAGES[@]}"; do
  # package id "build-tools;35.0.0" installs into directory "build-tools/35.0.0"
  pkg_dir="${pkg//;//}"
  if [ -d "$ANDROID_HOME/$pkg_dir" ]; then
    ok "$pkg already installed"
  else
    log "Installing SDK package: $pkg (this can take a while)"
    (yes || true) | "$SDKMANAGER" "$pkg" >/dev/null || die "failed to install $pkg"
    ok "$pkg installed"
  fi
done

# ------------------------------------------------------------------ persistent env

log "Writing persistent environment ($PROFILE_D and ~/.bashrc)"

env_block() {
  cat <<EOF
# expo-alt build environment (managed by setup-kitchen.sh)
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="$JAVA_HOME"
export PATH="\$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
EOF
}

env_block | as_root tee "$PROFILE_D" >/dev/null
as_root chmod 644 "$PROFILE_D"
ok "$PROFILE_D written"

MARK_BEGIN="# >>> expo-alt >>>"
MARK_END="# <<< expo-alt <<<"
touch "$HOME/.bashrc"
if grep -qF "$MARK_BEGIN" "$HOME/.bashrc"; then
  sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$HOME/.bashrc"
fi
{
  echo "$MARK_BEGIN"
  env_block
  echo "$MARK_END"
} >> "$HOME/.bashrc"
ok "~/.bashrc updated (guarded block)"

# ------------------------------------------------------------------ eas-cli

log "Installing eas-cli"
if command -v eas >/dev/null 2>&1; then
  ok "eas-cli already installed ($(eas --version 2>/dev/null || echo '?'))"
else
  as_root npm install -g eas-cli >/dev/null 2>&1
  ok "eas-cli installed"
fi

# ------------------------------------------------------------------ swap

log "Checking RAM / swap"
ram_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
swap_active="$(swapon --show --noheadings 2>/dev/null || true)"
if [ "$ram_kb" -lt $((8 * 1024 * 1024)) ] && [ -z "$swap_active" ]; then
  log "RAM < 8GB and no swap - creating 4G swap file (Gradle OOMs without it)"
  if ! as_root fallocate -l 4G "$SWAP_FILE" 2>/dev/null; then
    as_root dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096 status=none
  fi
  as_root chmod 600 "$SWAP_FILE"
  as_root mkswap "$SWAP_FILE" >/dev/null
  as_root swapon "$SWAP_FILE"
  if ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" | as_root tee -a /etc/fstab >/dev/null
  fi
  ok "4G swap enabled and persisted in /etc/fstab"
else
  ok "RAM $((ram_kb / 1024 / 1024))GB, swap: ${swap_active:-none needed}"
fi

# ------------------------------------------------------------------ directories

log "Creating directories"
mkdir -p "$HOME/kitchen/repos" "$HOME/kitchen/logs" "$HOME/kitchen/locks"
as_root mkdir -p "$BUILDS_DIR"
as_root chown "$(id -un):www-data" "$BUILDS_DIR"
as_root chmod 755 "$BUILDS_DIR"
ok "~/kitchen/{repos,logs,locks} and $BUILDS_DIR ready"

# ------------------------------------------------------------------ nginx

log "Configuring nginx"

# The reusable location block. It is written as a snippet so it can either be
# used by our own server block (below) or `include`d into an existing one.
as_root tee "$NGINX_SNIPPET" >/dev/null <<'EOF'
# expo-alt: serve built APKs from /var/www/builds at /builds/
# autoindex stays OFF: download URLs contain a random id and must stay unguessable.
location /builds/ {
    alias /var/www/builds/;
    autoindex off;
    default_type application/octet-stream;
    types { application/vnd.android.package-archive apk; }
}
EOF
ok "snippet written: $NGINX_SNIPPET"

# Decide how to hook the snippet in:
#  - If some OTHER enabled site already claims default_server on :80, we must
#    not fight it - print instructions to `include` the snippet there instead.
#  - If only the stock, unmodified Ubuntu "default" site is in the way, replace
#    it (the file stays in sites-available; we keep serving /var/www/html).
#  - Otherwise install our own default_server block.
has_other_default=0
while IFS= read -r f; do
  case "$f" in
    "$NGINX_SITE_ENABLED"|"$NGINX_SITE_AVAIL"|"$NGINX_STOCK_DEFAULT") ;;
    *) has_other_default=1 ;;
  esac
done < <(grep -rlsF 'default_server' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null || true)

install_site=0
if [ -e "$NGINX_SITE_ENABLED" ]; then
  ok "expo-alt-builds site already enabled"
  install_site=1  # rewrite sites-available to pick up any changes, symlink exists
elif [ "$has_other_default" -eq 1 ]; then
  warn "An existing nginx site already declares default_server on port 80."
  warn "Not touching it. To finish setup, add this single line INSIDE that"
  warn "site's 'server { ... }' block:"
  printf '\n      include %s;\n\n' "$NGINX_SNIPPET"
  warn "then run: sudo nginx -t && sudo systemctl reload nginx"
elif [ -e "$NGINX_STOCK_DEFAULT" ]; then
  if grep -q 'root /var/www/html' "$NGINX_STOCK_DEFAULT" \
     && ! grep -q 'location /builds/' "$NGINX_STOCK_DEFAULT"; then
    # Stock packaging default: safe to replace (our block also serves
    # /var/www/html at / so behavior is preserved).
    as_root rm -f "$NGINX_STOCK_DEFAULT"
    install_site=1
    ok "stock nginx default site replaced (original kept in sites-available/default)"
  else
    warn "sites-enabled/default looks customized. Not touching it. Add this"
    warn "line INSIDE its 'server { ... }' block:"
    printf '\n      include %s;\n\n' "$NGINX_SNIPPET"
    warn "then run: sudo nginx -t && sudo systemctl reload nginx"
  fi
else
  install_site=1
fi

if [ "$install_site" -eq 1 ]; then
  as_root tee "$NGINX_SITE_AVAIL" >/dev/null <<'EOF'
# expo-alt: default server serving APK downloads at /builds/
# Managed by setup-kitchen.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/html;
    location / {
        try_files $uri $uri/ =404;
    }

    include snippets/expo-alt-builds.conf;
}
EOF
  [ -e "$NGINX_SITE_ENABLED" ] || as_root ln -s "$NGINX_SITE_AVAIL" "$NGINX_SITE_ENABLED"
  ok "site enabled: $NGINX_SITE_ENABLED"
fi

as_root nginx -t
as_root systemctl enable --now nginx >/dev/null 2>&1 || true
as_root systemctl reload nginx
ok "nginx reloaded"

# ------------------------------------------------------------------ config file / secrets

log "Configuring $ENV_FILE"
mkdir -p "$CONF_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
# expo-alt configuration - sourced by `cook`. Keep this file chmod 600.
# ---------------------------------------------------------------- required
# Expo access token: expo.dev -> Account settings -> Access tokens
EXPO_TOKEN=""
# GitHub account/org that owns your app repos (repo URL convention:
# git@github.com:$GITHUB_USER/<repo-name>.git)
GITHUB_USER=""
# Public base URL of this VPS, no trailing slash - e.g. http://203.0.113.7
# or https://builds.example.com
BUILD_URL_BASE=""
# ---------------------------------------------------------------- optional
# Delete build dirs older than this many days (default 14)
#RETENTION_DAYS=14
# Keep at most this many build dirs (default 20)
#MAX_BUILDS=20
# Delete logs older than this many days (default 60)
#LOG_RETENTION_DAYS=60
EOF
  ok "template written"
else
  ok "already exists - keeping current values"
fi
chmod 600 "$ENV_FILE"

get_kv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'; }
set_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# Optional prefill: if a .env sits at this repo's root (it is gitignored, so
# it only exists if you scp'd yours here), copy its non-secret values into
# the server config for anything not already set.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PC_ENV="$REPO_ROOT/.env"
if [ -f "$PC_ENV" ]; then
  for k in GITHUB_USER BUILD_URL_BASE; do
    if [ -z "$(get_kv "$k")" ]; then
      v="$(grep -E "^${k}=" "$PC_ENV" | head -1 | cut -d= -f2- | tr -d '"' || true)"
      if [ -n "$v" ]; then
        set_kv "$k" "${v%/}"
        ok "$k prefilled from $PC_ENV"
      fi
    fi
  done
fi

if [ -t 0 ]; then
  if [ -z "$(get_kv EXPO_TOKEN)" ]; then
    printf '\n  EXPO_TOKEN: create one at expo.dev -> Account settings -> Access tokens\n'
    # -s: never echo the secret to the terminal (and it never hits any log)
    read -r -s -p "  Paste EXPO_TOKEN (or press Enter to set it later): " tok
    printf '\n'
    if [ -n "$tok" ]; then set_kv EXPO_TOKEN "$tok"; fi
    unset tok
  fi
  if [ -z "$(get_kv GITHUB_USER)" ]; then
    read -r -p "  GitHub username/org owning your app repos (Enter to skip): " gh
    if [ -n "$gh" ]; then set_kv GITHUB_USER "$gh"; fi
  fi
  if [ -z "$(get_kv BUILD_URL_BASE)" ]; then
    read -r -p "  Public base URL of this VPS, e.g. http://<vps-ip> (Enter to skip): " base
    if [ -n "$base" ]; then set_kv BUILD_URL_BASE "${base%/}"; fi
  fi
else
  warn "Non-interactive run: edit $ENV_FILE and fill in EXPO_TOKEN,"
  warn "GITHUB_USER and BUILD_URL_BASE before the first build."
fi
chmod 600 "$ENV_FILE"

# ------------------------------------------------------------------ deploy key

log "GitHub deploy key"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$DEPLOY_KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "expo-alt-deploy@$(hostname)" -f "$DEPLOY_KEY" >/dev/null
  ok "new ed25519 keypair generated: $DEPLOY_KEY"
else
  ok "keypair already exists: $DEPLOY_KEY"
fi

SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
if ! grep -qF "expo_alt_deploy" "$SSH_CONFIG"; then
  cat >> "$SSH_CONFIG" <<EOF

# expo-alt: use the deploy key for GitHub (added by setup-kitchen.sh)
Host github.com
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
EOF
  ok "~/.ssh/config entry for github.com added"
else
  ok "~/.ssh/config already references the deploy key"
fi

# ------------------------------------------------------------------ self-check

log "Self-check summary"
printf '  %-12s %s\n' "node"       "$(node -v 2>/dev/null || echo MISSING)"
printf '  %-12s %s\n' "npm"        "$(npm -v 2>/dev/null || echo MISSING)"
printf '  %-12s %s\n' "java"       "$(java -version 2>&1 | head -1 || echo MISSING)"
printf '  %-12s %s\n' "sdkmanager" "$("$SDKMANAGER" --version 2>/dev/null | head -1 || echo MISSING)"
printf '  %-12s %s\n' "eas-cli"    "$(eas --version 2>/dev/null || echo MISSING)"
printf '  %-12s %s\n' "jq"         "$(jq --version 2>/dev/null || echo MISSING)"
printf '  %-12s %s\n' "nginx"      "$(systemctl is-active nginx 2>/dev/null || echo unknown)"
printf '  %-12s %s\n' "disk free"  "$(df -h / | awk 'NR==2{print $4 " free of " $2}')"
printf '  %-12s %s\n' "memory"     "$(free -h | awk '/^Mem:/{print $2 " RAM"} /^Swap:/{printf ", %s swap", $2}')"
printf '\n'
for k in EXPO_TOKEN GITHUB_USER BUILD_URL_BASE; do
  if [ -z "$(get_kv "$k")" ]; then
    warn "$k is not set yet - edit $ENV_FILE"
  else
    ok "$k is set"
  fi
done

# ------------------------------------------------------------------ final instructions

printf '\n\033[1;35m================= NEXT STEPS =================\033[0m\n'
cat <<EOF

1) Add this deploy key to your GitHub repo:
     GitHub -> your repo -> Settings -> Deploy keys -> "Add deploy key"
     Title: expo-alt kitchen        Allow write access: OFF (read-only)

--------8<-------- public key --------8<--------
$(cat "${DEPLOY_KEY}.pub")
-------->8------------------------------->8------

   NOTE: GitHub allows a deploy key on only ONE repo. For more repos, either
   generate more keys (see README "multiple repos") or add this key to a
   dedicated GitHub machine account instead.

2) Make sure EXPO_TOKEN, GITHUB_USER and BUILD_URL_BASE are set in:
     $ENV_FILE

3) Install the build script:
     sudo install -m 755 cook /usr/local/bin/cook

4) Test SSH to GitHub from this VPS:
     ssh -T git@github.com     (expect: "Hi <repo>! You've successfully authenticated")

5) First build:
     cook <repo-name>

Re-running this script at any time is safe.
EOF
