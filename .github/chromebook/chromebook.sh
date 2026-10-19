#!/usr/bin/env bash
# =============================================================================
#  Cloud "Chromebook" on a GitHub-hosted runner
#
#  Everything runs inside the Actions runner (its CPU / RAM / disk / network)
#  and is streamed to your own browser:
#
#      Xvfb (:99) ── openbox + tint2 shelf + Google Chrome
#            │
#            ├── x11vnc    (RFB, 127.0.0.1:5900, password = $VNC_PASSWORD, optional)
#            └── websockify+noVNC (HTTP+WebSocket, 127.0.0.1:6080)
#                     │
#                     └── cloudflared quick tunnel  ->  https://<random>.trycloudflare.com
#
#  Usage:  chromebook.sh install | boot | hold | url | status
#     install  apt packages, Google Chrome, cloudflared, fonts, noVNC web root
#     boot     start the whole stack, render the web pages, announce the URL
#     hold     watchdog: keeps the job alive and restarts anything that dies
#     url      print the current public URL (empty when not ready)
#     status   one-line health report (used by the workflow and for debugging)
#
#  VNC_PASSWORD=<pw>  protects the desktop: the password is never printed, only
#  its state is reported. Without it the desktop is open to anyone holding the URL.
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------------ constants
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/assets"

WORK="${WORK:-/tmp/chromebook}"
LOGS="$WORK/logs"
RUNTIME="$WORK/runtime"
WEBROOT="$RUNTIME/web"
URL_FILE="$WORK/tunnel.url"
PIDDIR="$WORK/pids"
mkdir -p "$WORK" "$LOGS" "$RUNTIME" "$PIDDIR"

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
RESOLUTION="${RESOLUTION:-1600x900}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-6080}"
# Remote-desktop password (RFB/VNC auth). Empty -> x11vnc runs with -nopw.
# The value is only ever handed to `x11vnc -storepasswd`, never echoed or logged.
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_PASSFILE="$WORK/vncpasswd"
VNC_PASS_MAX=8                                # the RFB handshake only carries 8 characters
LOCAL_URL="http://127.0.0.1:${WEB_PORT}"
NOVNC_QUALITY="${NOVNC_QUALITY:-6}"          # 0 (worst) .. 9 (best picture, more bandwidth)
NOVNC_COMPRESSION="${NOVNC_COMPRESSION:-2}"  # 0 (fastest) .. 9 (smallest)
START_URL="${START_URL:-}"                   # empty -> the built-in home page
SESSION_SECONDS="${SESSION_SECONDS:-0}"      # 0 -> unknown
SESSION_START="${SESSION_START:-$(date -u '+%Y-%m-%d %H:%M UTC')}"
CHROME_BIN=""
CHROME_FLAGS=()
CHROME_CHANNEL="${CHROME_CHANNEL:-stable}"  # stable | beta | dev (unstable) | canary
CHROME_LANG="${CHROME_LANG:-fa}"            # Chrome UI language (empty = keep the default)
CHROME_PROFILE="$HOME/.config/google-chrome-cloud"
APPDIR="$HOME/.local/share/applications"
TINT2_RC="$RUNTIME/tint2rc"

# Which desktop to run:
#   ubuntu  = the real Ubuntu session (GNOME Shell + Yaru + Ubuntu dock) -> looks
#             exactly like a fresh Ubuntu desktop, but heavier on CPU
#   classic = the light Chromebook-style openbox + floating shelf (fastest)
#   auto    = use GNOME when it is installed, otherwise the classic desktop
DESKTOP_MODE="${DESKTOP_MODE:-auto}"
DESKTOP_ACTIVE=""                            # what boot() actually started

# modern look instead of the 1990s defaults (no cursor theme, DejaVu everywhere)
if [ -d /usr/share/icons/Yaru ]; then export XCURSOR_THEME="${CURSOR_THEME:-Yaru}"; fi
export XCURSOR_SIZE="${CURSOR_SIZE:-24}"
if [ -d /usr/share/themes/Yaru-dark ]; then export GTK_THEME="${DESKTOP_THEME:-Yaru-dark}"; fi

# ------------------------------------------------------------------ utilities
log()  { printf '\033[36m[chromebook]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[chromebook] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[chromebook] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
esc()  { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }   # escape a sed replacement

pidfile() { echo "$PIDDIR/$1.pid"; }
is_up() {   # is_up <service>
  local f; f="$(pidfile "$1")"
  [ -s "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null
}
spawn() {   # spawn <name> <command...>   (own log file + pid file)
  local name="$1"; shift
  nohup "$@" >"$LOGS/$name.log" 2>&1 </dev/null &
  echo $! > "$(pidfile "$name")"
}
stop_svc() {
  local f; f="$(pidfile "$1")"
  if [ -s "$f" ]; then kill "$(cat "$f")" >/dev/null 2>&1 || true; rm -f "$f"; fi
}
wait_http() {  # wait_http <url> [tries]
  local url="$1" tries="${2:-30}" code=000
  for _ in $(seq "$tries"); do
    code=$(curl -fs -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null || true)
    [ "$code" = "200" ] && return 0
    sleep 1
  done
  return 1
}
notify() {   # optional Telegram message (nice for long sessions / chained runs)
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  curl -fsS -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}
session_end() {   # the same absolute deadline that hold() enforces (counted from the job start)
  local s="${SESSION_SECONDS:-0}"
  if [ "$s" -gt 0 ] 2>/dev/null; then
    date -u -d "@$(( ${JOB_START:-$(date +%s)} + s ))" '+%H:%M UTC'
  else
    echo "—"
  fi
}
session_end_epoch() {   # unix timestamp of that deadline (empty when the session has no limit)
  local s="${SESSION_SECONDS:-0}"
  if [ "$s" -gt 0 ] 2>/dev/null; then echo "$(( ${JOB_START:-$(date +%s)} + s ))"; fi
}
public_url() { cat "$URL_FILE" 2>/dev/null || true; }
save_state() {   # boot/hold/status are separate processes: remember what boot started
  {
    printf 'DESKTOP_ACTIVE=%q\n' "${DESKTOP_ACTIVE:-}"
    printf 'DBUS_SESSION_BUS_ADDRESS=%q\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
    printf 'XDG_RUNTIME_DIR=%q\n' "${XDG_RUNTIME_DIR:-}"
  } > "$WORK/state.env"
}
bus_alive() {
  if have dbus-send; then
    dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
      org.freedesktop.DBus.ListNames >/dev/null 2>&1
  elif have gdbus; then
    gdbus call --session --dest org.freedesktop.DBus --object-path / \
      --method org.freedesktop.DBus.ListNames >/dev/null 2>&1
  else return 0; fi
}
ensure_session_bus() {   # GTK/GNOME apps expect a session bus (gnome-terminal, mutter, ...)
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && bus_alive; then return 0; fi
  unset DBUS_SESSION_BUS_ADDRESS
  eval "$(dbus-launch --sh-syntax)"
  export DBUS_SESSION_BUS_ADDRESS
  if [ -n "${DBUS_SESSION_BUS_PID:-}" ]; then echo "$DBUS_SESSION_BUS_PID" > "$(pidfile dbus)"; fi
  return 0
}
load_state() {
  [ -f "$WORK/state.env" ] || return 0
  # shellcheck disable=SC1090
  . "$WORK/state.env"
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && export DBUS_SESSION_BUS_ADDRESS
  [ -n "${XDG_RUNTIME_DIR:-}" ] && export XDG_RUNTIME_DIR
  return 0
}
os_name() {   # "Ubuntu 26.04 LTS · image 2026xxxx" (the runner exposes ImageVersion)
  local pretty
  pretty="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}" )"
  if [ -n "${ImageVersion:-}" ]; then printf '%s · image %s' "$pretty" "$ImageVersion"; else printf '%s' "$pretty"; fi
}
os_pretty() {   # just "Ubuntu 24.04.5 LTS"
  . /etc/os-release 2>/dev/null || true
  printf '%s' "${PRETTY_NAME:-Linux}"
}
image_version() { printf '%s' "${ImageVersion:-—}"; }
ubuntu_version_num() {   # 24.04 -> 2404, 26.04 -> 2604 (0 when it is not Ubuntu)
  local v
  v="$( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-0}" )"
  printf '%s' "${v//./}"
}
chrome_version() {
  [ -n "$CHROME_BIN" ] || return 0
  "$CHROME_BIN" --version 2>/dev/null \
    | sed -e 's/^Google Chrome //' -e 's/^Chromium //' -e 's/ \(beta\|dev\|unstable\|canary\)$//' || true
}
chrome_package() {   # the apt/binary name of the selected release channel
  case "${CHROME_CHANNEL:-stable}" in
    stable)       echo google-chrome-stable ;;
    beta)         echo google-chrome-beta ;;
    dev|unstable) echo google-chrome-unstable ;;
    canary)       echo google-chrome-canary ;;
    *)            echo google-chrome-stable ;;
  esac
}
resolve_chrome() {   # pick the channel binary, otherwise whatever Chrome/Chromium is installed
  local pkg c; pkg="$(chrome_package)"
  for c in "$pkg" google-chrome google-chrome-stable google-chrome-beta \
           google-chrome-unstable google-chrome-canary chromium chromium-browser; do
    if have "$c"; then CHROME_BIN="$(command -v "$c")"; return 0; fi
  done
  CHROME_BIN=""; return 1
}

# ------------------------------------------------------------------ install
install() {
  local pkgs=(
    xvfb x11vnc novnc websockify openbox tint2 xterm pcmanfm xdotool wmctrl
    x11-utils dbus-x11 feh fontconfig fonts-dejavu-core fonts-noto-core
    fonts-noto-color-emoji adwaita-icon-theme hicolor-icon-theme unzip curl ca-certificates
    fonts-ubuntu yaru-theme-gtk yaru-theme-icon picom imagemagick mesa-utils
    gnome-terminal dconf-cli
  )
  log "installing desktop packages with apt (first boot takes ~2-4 minutes)"
  $SUDO apt-get update -qq
  # never let apt start daemons (gdm3, cups...) inside the session
  if [ ! -x /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' | $SUDO tee /usr/sbin/policy-rc.d >/dev/null
    $SUDO chmod +x /usr/sbin/policy-rc.d
  fi
  # a preseed keeps debconf from ever asking anything in a non-interactive run
  printf 'keyboard-configuration keyboard-configuration/layoutcode string us\n' \
    | $SUDO debconf-set-selections 2>/dev/null || true
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}"

  # The real Ubuntu session (GNOME Shell + Yaru + the Ubuntu dock). It is big, so
  # a failure here is not fatal: the desktop then falls back to the light
  # openbox + floating-shelf setup.
  if [ "${DESKTOP_MODE:-auto}" = "auto" ] && [ "$(ubuntu_version_num)" -ge 2510 ]; then
    log "GNOME on this image is Wayland only (no X11 session): installing the classic desktop only"
    log "(choose desktop=ubuntu to force GNOME, or runner_image=ubuntu-24.04 for GNOME on X11)"
  elif [ "${DESKTOP_MODE:-auto}" != "classic" ]; then
    log "installing the Ubuntu (GNOME) session packages (adds ~1-2 minutes)"
    local gnome_pkgs=(
      gnome-session ubuntu-session gnome-shell gnome-shell-extension-ubuntu-dock
      ubuntu-settings gnome-terminal nautilus
    )
    if ! $SUDO env DEBIAN_FRONTEND=noninteractive \
         apt-get install -y -qq --no-install-recommends "${gnome_pkgs[@]}"; then
      warn "the Ubuntu session could not be installed; the classic desktop will be used"
    fi
  fi

  # Ubuntu ships "chromium" as a snap stub, which cannot work on a runner: use Google's own deb.
  # The channel decides how new the browser is: stable < beta < dev(unstable) < canary.
  local pkg; pkg="$(chrome_package)"
  if ! have "$pkg"; then
    log "downloading Google Chrome (${CHROME_CHANNEL} channel -> ${pkg})"
    curl -fsSL -o "$WORK/chrome.deb" "https://dl.google.com/linux/direct/${pkg}_current_amd64.deb" \
      || die "could not download ${pkg} (is the channel name right?)"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$WORK/chrome.deb"
  fi
  resolve_chrome || die "Google Chrome was not installed"
  log "browser: $("$CHROME_BIN" --version 2>/dev/null)  ($(os_name))"

  if ! have cloudflared; then
    log "downloading cloudflared"
    curl -fsSL -o "$WORK/cloudflared.deb" \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    $SUDO dpkg -i "$WORK/cloudflared.deb" >/dev/null 2>&1 \
      || DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq -f
  fi
  have cloudflared && log "cloudflared: $(cloudflared --version 2>/dev/null | head -1)" \
                   || die "cloudflared was not installed"

  have websockify || { log "installing websockify with pip"; python3 -m pip install --quiet --user websockify; }
  have websockify || die "websockify is not available"

  write_chrome_policy
  install_fonts
  install_look
  build_webroot
  log "install complete"
}

gnome_x11_supported() {   # GNOME 50 (Ubuntu 26.04+) is Wayland only: no X11 session at all
  have gnome-shell || return 1
  gnome-shell --help 2>/dev/null | grep -q -- '--x11'
}

pick_desktop_mode() {   # ubuntu | classic  (auto = whatever this image can really do)
  case "${DESKTOP_MODE:-auto}" in
    classic)
      echo classic
      ;;
    ubuntu)
      if have gnome-session && have gnome-shell; then echo ubuntu
      else warn "GNOME is not installed here; using the classic desktop" >&2; echo classic; fi
      ;;
    *)
      if ! have gnome-session || ! have gnome-shell; then
        if [ "$(ubuntu_version_num)" -ge 2510 ]; then
          warn "GNOME on this image ($( . /etc/os-release; printf '%s' "${PRETTY_NAME:-?}" )) is Wayland only (no X11 session); using the classic desktop" >&2
          warn "for the real GNOME desktop pick runner_image=ubuntu-24.04 (or 22.04)" >&2
        fi
        echo classic
      elif ! gnome_x11_supported; then
        warn "$(gnome-shell --version 2>/dev/null | head -1) on this image has no X11 session (GNOME 50+ is Wayland only)." >&2
        warn "using the classic desktop on Xvfb; pick runner_image=ubuntu-24.04 with desktop=ubuntu for the real GNOME desktop" >&2
        echo classic
      else
        echo ubuntu
      fi
      ;;
  esac
}

install_look() {   # the Yaru look: dark GTK theme, Ubuntu font, Yaru cursors/icons
  log "writing the desktop look (Yaru theme, Ubuntu font, GNOME defaults)"
  local g3="$HOME/.config/gtk-3.0" g4="$HOME/.config/gtk-4.0"
  mkdir -p "$g3" "$g4" "$HOME/.icons/default" "$HOME/.config/autostart"
  local theme="Adwaita" icons="Adwaita" cursor="Adwaita"
  if [ -d /usr/share/themes/Yaru-dark ]; then theme="Yaru-dark"; fi
  if [ -d /usr/share/icons/Yaru ]; then icons="Yaru"; fi
  if [ -d /usr/share/icons/Yaru/cursors ]; then cursor="Yaru"; fi
  cat > "$g3/settings.ini" <<EOF
[Settings]
gtk-theme-name=$theme
gtk-icon-theme-name=$icons
gtk-font-name=Ubuntu 11
gtk-cursor-theme-name=$cursor
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF
  cp "$g3/settings.ini" "$g4/settings.ini"
  cat > "$HOME/.icons/default/index.theme" <<EOF
[Icon Theme]
Name=Default
Comment=Default cursor theme
Inherits=$cursor
EOF
  # first-run wizards and background indexers only waste CPU on a runner
  local a
  for a in gnome-initial-setup-first-login gnome-initial-setup-copy-worker \
           gnome-welcome-tour ubuntu-report tracker-miner-fs-3 tracker-miner-rss-3 \
           evolution-alarm-notify geoclue-demo-agent snap-notification; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$a" \
      > "$HOME/.config/autostart/$a.desktop"
  done
  touch "$HOME/.config/gnome-initial-setup-done"
  write_dconf_defaults
}

write_dconf_defaults() {   # system-wide defaults for the GNOME session
  local db="/etc/dconf/db/cloud-chromebook.d"
  $SUDO mkdir -p "$db" /etc/dconf/profile
  $SUDO tee /etc/dconf/profile/user >/dev/null <<'EOF'
user-db:user
system-db:cloud-chromebook
EOF
  $SUDO tee "$db/00-desktop" >/dev/null <<EOF
[org/gnome/desktop/background]
picture-uri='file://$RUNTIME/wallpaper.png'
picture-uri-dark='file://$RUNTIME/wallpaper.png'
primary-color='#2a0f25'
color-shading-type='solid'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
enable-animations=false
enable-hot-corners=false
font-name='Ubuntu 11'
document-font-name='Ubuntu 11'
monospace-font-name='Ubuntu Mono 12'
cursor-theme='Yaru'
cursor-size=24

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
lock-enabled=false

[org/gnome/settings-daemon/plugins/power]
idle-dim=false
sleep-inactive-ac-type='nothing'

[org/gnome/shell]
favorite-apps=['google-chrome.desktop', 'cloud-terminal.desktop', 'cloud-files.desktop']
enabled-extensions=['ubuntu-dock@ubuntu.com']
welcome-dialog-last-shown-version='99'

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
extend-height=true
autohide=false
icon-size=44
EOF
  $SUDO dconf update 2>/dev/null || warn "dconf update failed (GNOME will use its defaults)"
}

write_chrome_policy() {   # keeps the browser UI clean (managed policy, read from /etc/opt/chrome)
  log "writing the Chrome managed policy"
  $SUDO mkdir -p /etc/opt/chrome/policies/managed
  $SUDO tee /etc/opt/chrome/policies/managed/cloud-chromebook.json >/dev/null <<'EOF'
{
  "TranslateEnabled": false,
  "PromotionalTabsEnabled": false,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false
}
EOF
}

install_fonts() {   # Persian text looks broken without a proper Arabic-script font
  local dir="$HOME/.local/share/fonts" conf="$HOME/.config/fontconfig/conf.d"
  mkdir -p "$dir" "$conf"
  if ! fc-list 2>/dev/null | grep -qi vazirmatn; then
    if curl -fsSL -o "$WORK/vazirmatn.zip" \
        "https://github.com/rastikerdar/vazirmatn/releases/download/v33.003/vazirmatn-v33.003.zip" \
       && unzip -qo "$WORK/vazirmatn.zip" -d "$WORK/vazirmatn" >/dev/null 2>&1; then
      find "$WORK/vazirmatn" -name '*.ttf' -exec cp -n {} "$dir"/ \; 2>/dev/null || true
      log "Vazirmatn font installed"
    else
      warn "could not download Vazirmatn, falling back to the system fonts"
    fi
  fi
  cat > "$conf/99-cloud-chromebook.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- Latin text in the Ubuntu font (that is what makes a desktop look like Ubuntu) -->
  <match target="pattern">
    <test name="family" compare="eq" ignore-blanks="true"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Ubuntu</string></edit>
  </match>
  <!-- prefer Persian-friendly families for Arabic script text -->
  <match target="pattern">
    <test name="lang" compare="contains"><string>fa</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Vazirmatn</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <test name="lang" compare="contains"><string>ar</string></test>
    <edit name="family" mode="append" binding="weak"><string>Vazirmatn</string></edit>
  </match>
</fontconfig>
EOF
  fc-cache -f >/dev/null 2>&1 || true
}

build_webroot() {
  local src="" d
  for d in /usr/share/novnc /usr/share/webapps/novnc /usr/local/share/novnc; do
    [ -d "$d" ] && { src="$d"; break; }
  done
  have websockify || die "websockify missing"
  if [ -z "$src" ]; then
    log "noVNC package files not found, downloading noVNC v1.7.0"
    curl -fsSL -o "$WORK/novnc.tar.gz" https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.tar.gz
    mkdir -p "$RUNTIME/novnc-src"
    tar -xzf "$WORK/novnc.tar.gz" -C "$RUNTIME/novnc-src" --strip-components=1
    src="$RUNTIME/novnc-src"
  fi
  rm -rf "$WEBROOT"; mkdir -p "$WEBROOT"
  cp -a "$src"/. "$WEBROOT"/
  cp -a "$ASSETS/web/." "$WEBROOT"/
  render_pages        # substitute the placeholders right away (URL is filled in again after the tunnel is up)
  log "web root ready: $WEBROOT"
}

# ------------------------------------------------------------------ desktop
start_x() {
  is_up xvfb && return 0
  log "starting Xvfb ${RESOLUTION}x${SCREEN_DEPTH} on $DISPLAY"
  spawn xvfb Xvfb "$DISPLAY" -screen 0 "${RESOLUTION}x${SCREEN_DEPTH}" -dpi 96 \
    -nolisten tcp -ac +extension RANDR +extension GLX -noreset
  local i
  for i in $(seq 30); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && { log "X server is up"; return 0; }
    sleep 1
  done
  tail -n 20 "$LOGS/xvfb.log" >&2 || true
  die "Xvfb did not start"
}

set_wallpaper() {
  python3 "$ASSETS/wallpaper.py" "${RESOLUTION%x*}" "${RESOLUTION#*x}" "$RUNTIME/wallpaper.png" \
    >"$LOGS/wallpaper.log" 2>&1 || warn "wallpaper generation failed (not fatal)"
  [ -f "$RUNTIME/wallpaper.png" ] && feh --no-fehbg --bg-fill "$RUNTIME/wallpaper.png" >/dev/null 2>&1 || true
}

start_wm() {
  is_up openbox && return 0
  local rc="$ASSETS/openbox/rc.xml"
  if [ -f "$rc" ]; then
    spawn openbox openbox --config-file "$rc"
    sleep 2
    if is_up openbox; then log "openbox running (custom config)"; return 0; fi
    warn "openbox rejected the custom config, using its defaults"
    tail -n 3 "$LOGS/openbox.log" >&2 || true
  fi
  spawn openbox openbox
  sleep 1
  is_up openbox || warn "openbox is not running (windows will not be managed)"
}

start_shelf() {   # tint2 = the ChromeOS-like bottom shelf with app launchers
  is_up tint2 && return 0
  sed -e "s|__HOME__|$HOME|g" "$ASSETS/tint2rc" > "$TINT2_RC"
  spawn tint2 tint2 -c "$TINT2_RC"
  sleep 1
  if is_up tint2; then log "tint2 shelf is up"; else
    warn "tint2 failed to start (the desktop still works without the shelf)"
    tail -n 3 "$LOGS/tint2.log" >&2 || true
  fi
}

start_compositor() {   # picom: real transparency for the shelf + soft window shadows
  is_up picom && return 0
  have picom || return 0
  spawn picom picom --config "$ASSETS/picom.conf"
  sleep 1
  if is_up picom; then log "compositor (picom) is up"; else
    warn "picom did not start (transparency will look flat)"
    tail -n 3 "$LOGS/picom.log" >&2 || true
  fi
}

start_gnome() {   # the real Ubuntu session: GNOME Shell + Yaru + the Ubuntu dock
  gnome_alive && return 0
  if ! have gnome-session || ! have gnome-shell; then
    warn "the GNOME session is not installed"
    return 1
  fi
  if ! gnome_x11_supported; then
    warn "$(gnome-shell --version 2>/dev/null | head -1) has no X11 session (Wayland only), so it cannot run on Xvfb"
    return 1
  fi
  ensure_session_bus
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$WORK/xdg-runtime}"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  export XDG_SESSION_TYPE=x11
  export XDG_CURRENT_DESKTOP=ubuntu:GNOME
  export GNOME_SHELL_SESSION_MODE=ubuntu
  export XDG_DATA_DIRS="/usr/share/ubuntu:/usr/local/share:/usr/share:/var/lib/snapd/desktop"
  export LIBGL_ALWAYS_SOFTWARE=1        # no GPU on a runner: GNOME renders through llvmpipe
  log "GNOME: $(gnome-shell --version 2>/dev/null | head -1) | sessions: $(ls /usr/share/gnome-session/sessions 2>/dev/null | tr '\n' ' ')"
  if have glxinfo; then
    log "graphics: $(LIBGL_ALWAYS_SOFTWARE=1 glxinfo -B 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  fi

  # First choice: the complete Ubuntu session (settings daemon, dock, everything).
  log "starting the Ubuntu (GNOME) session"
  spawn gnome-session gnome-session --session=ubuntu
  if wait_for_shell 60 && shell_stays 20; then
    finish_gnome_start
    return 0
  fi
  warn "gnome-session did not keep the shell running; trying the shell on its own"
  tail -n 15 "$LOGS/gnome-session.log" >&2 || true
  stop_svc gnome-session
  sleep 2

  # Second choice: GNOME Shell itself (still the Ubuntu top bar + dock + Yaru).
  log "starting GNOME Shell directly (gnome-shell --x11)"
  spawn gnome-shell gnome-shell --x11
  if wait_for_shell 60 && shell_stays 20; then
    finish_gnome_start
    return 0
  fi
  warn "GNOME Shell could not start (see $LOGS/gnome-shell.log)"
  tail -n 15 "$LOGS/gnome-shell.log" >&2 || true
  stop_svc gnome-shell
  return 1
}

gnome_alive() { pgrep -x gnome-shell >/dev/null 2>&1; }

wait_for_shell() {   # wait_for_shell <seconds>
  local i n="${1:-60}"
  for i in $(seq "$n"); do
    gnome_alive && return 0
    sleep 1
  done
  return 1
}

shell_stays() {   # shell_stays <seconds>: still alive after a while? (crash detection)
  sleep "${1:-20}"
  gnome_alive
}

finish_gnome_start() {
  sleep 2
  gsettings set org.gnome.desktop.interface enable-animations false >/dev/null 2>&1 || true
  log "GNOME Shell is up"
}

page_shot() {   # headless render of the landing page (no display needed)
  local f="$RUNTIME/page-shot.png" ud
  if [ -z "$CHROME_BIN" ]; then resolve_chrome || { warn "Chrome not found for the page screenshot"; return 1; }; fi
  ud="$(mktemp -d)"
  "$CHROME_BIN" --headless=new --disable-gpu --no-sandbox --hide-scrollbars --disable-dev-shm-usage \
    --user-data-dir="$ud" --window-size=1280,920 --force-device-scale-factor=1 \
    --virtual-time-budget=5000 --screenshot="$f" "file://$WEBROOT/index.html" >/dev/null 2>&1 || true
  rm -rf "$ud"
  [ -s "$f" ] || { warn "could not render the landing page"; return 1; }
  log "page screenshot: $f ($(du -h "$f" 2>/dev/null | cut -f1))"
  if [ "${SHOT_B64:-0}" = "1" ]; then
    echo "-----BEGIN PAGE-SHOT-----"
    base64 "$f" | fold -w 100
    echo "-----END PAGE-SHOT-----"
  fi
}

shot() {   # screenshot of the desktop; SHOT_B64=1 also prints it as base64 for the log
  have import || { warn "ImageMagick (import) is not installed"; return 1; }
  local f="$RUNTIME/last-shot.png"
  import -display "$DISPLAY" -window root "$f" || { warn "could not capture the screen"; return 1; }
  log "screenshot: $f ($(du -h "$f" 2>/dev/null | cut -f1))"
  if [ "${SHOT_B64:-0}" = "1" ]; then
    echo "-----BEGIN SCREENSHOT-----"
    base64 "$f" | fold -w 100
    echo "-----END SCREENSHOT-----"
  fi
  if [ "${SHOT_PAGE:-0}" = "1" ]; then page_shot; fi
}

write_desktop_entries() {
  mkdir -p "$APPDIR"
  if [ ! -f /usr/share/applications/google-chrome.desktop ]; then
    cat > "$APPDIR/google-chrome.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Google Chrome
Exec=$CHROME_BIN
Icon=google-chrome
Categories=Network;WebBrowser;
EOF
  fi
  local term_exec='xterm -u8 -fa "DejaVu Sans Mono" -fs 11 -bg #101418 -fg #e8eaed -title Terminal'
  if have gnome-terminal; then term_exec="gnome-terminal"; fi
  cat > "$APPDIR/cloud-terminal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Terminal
Comment=Run apt/pip/npm inside this session
Exec=$term_exec
Icon=utilities-terminal
Categories=System;TerminalEmulator;
EOF
  local files_exec="pcmanfm"
  if have nautilus; then files_exec="nautilus --new-window"; fi
  cat > "$APPDIR/cloud-files.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Files
Comment=Browse the runner filesystem
Exec=$files_exec
Icon=folder
Categories=System;FileManager;
EOF
}

# ------------------------------------------------------------------ remote access
vnc_auth_on() { [ -n "${VNC_PASSWORD:-}" ] && [ -s "${VNC_PASSFILE:-/nonexistent}" ]; }

prepare_vnc_password() {   # turn $VNC_PASSWORD into the obfuscated file x11vnc expects
  vnc_auth_on && return 0
  if [ -z "${VNC_PASSWORD:-}" ]; then
    rm -f "$VNC_PASSFILE"
    warn "no VNC password: anyone with the public URL can use this desktop"
    return 1
  fi
  if [ "${#VNC_PASSWORD}" -gt "$VNC_PASS_MAX" ]; then
    warn "VNC passwords are limited to ${VNC_PASS_MAX} characters; only the first ${VNC_PASS_MAX} are used"
  fi
  if ! x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASSFILE" >/dev/null 2>&1; then
    rm -f "$VNC_PASSFILE"
    warn "could not write $VNC_PASSFILE: the desktop stays open (check the x11vnc package)"
    return 1
  fi
  chmod 600 "$VNC_PASSFILE" 2>/dev/null || true
  log "VNC password is set (RFB auth on, ${#VNC_PASSWORD} chars, value never logged)"
}

rfb_auth_types() {   # ask the running server which RFB security types it offers (2 = password)
  python3 - "$VNC_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(3)
    sock.recv(12)                       # the server greets with "RFB 003.008\n"
    sock.sendall(b"RFB 003.008\n")
    count = sock.recv(1)
    if not count:
        raise OSError("server closed the connection")
    types = sock.recv(count[0])
    print(",".join(str(t) for t in types))
except Exception as exc:                # noqa: BLE001 - report and let the caller decide
    print(f"error: {exc}")
PY
}

auth_state() {   # shown on the landing page
  vnc_auth_on && printf 'فعال (RFB)' || printf 'غیرفعال'
}

desktop_label() {   # which desktop boot() actually started, in Persian
  if [ "${DESKTOP_ACTIVE:-classic}" = "ubuntu" ]; then
    printf 'اوبونتو (GNOME)'
  else
    printf 'کلاسیک (openbox)'
  fi
}

auth_note() {   # the "how safe is this" sentence on the landing page
  if vnc_auth_on; then
    printf 'دسکتاپ با رمز محافظت می‌شود: noVNC پیش از نشان‌دادن تصویر، رمز را می‌پرسد. با این حال لینک را جای عمومی پست نکن و سشن را کوتاه نگه دار.'
  else
    printf 'این نشانی رمز ندارد؛ هر کس آن را داشته باشد به دسکتاپ راه پیدا می‌کند. لینک را جایی منتشر نکن و سشن را کوتاه نگه دار.'
  fi
}

auth_line() {   # one-liner for logs/status: states the truth, never the password
  if ! vnc_auth_on; then printf 'off (no password)'; return 0; fi
  local types; types="$(rfb_auth_types)"
  case ",$types," in
    *,1,*) printf 'on, but the server also offers no-auth (%s)!' "$types" ;;
    *,2,*) printf 'on (RFB password required)' ;;
    *)     printf 'on (not verified: %s)' "$types" ;;
  esac
}

start_vnc() {
  is_up x11vnc && return 0
  # NOTE: do not add -maxauth here: x11vnc 0.9.16 (Ubuntu 24.04) rejects it and
  # exits immediately, which used to leave the whole session without a VNC server.
  local args=(-display "$DISPLAY" -rfbport "$VNC_PORT" -localhost -forever -shared -noxdamage -xkb
              -repeat -capslock -o "$LOGS/x11vnc-daemon.log" -quiet)
  if vnc_auth_on; then
    args+=(-rfbauth "$VNC_PASSFILE")
    log "starting x11vnc on 127.0.0.1:$VNC_PORT (password required)"
  else
    args+=(-nopw)
    log "starting x11vnc on 127.0.0.1:$VNC_PORT (no password)"
  fi
  spawn x11vnc x11vnc "${args[@]}" || true
  local i
  for i in $(seq 10); do
    is_up x11vnc && break
    sleep 1
  done
  if ! is_up x11vnc; then
    tail -n 8 "$LOGS/x11vnc-daemon.log" >&2 2>/dev/null || true
    tail -n 5 "$LOGS/x11vnc.log" >&2 2>/dev/null || true
    warn "x11vnc failed to start"
    return 1
  fi
  log "x11vnc is up"
}

check_vnc_auth() {   # fail closed: never expose a desktop that should be password protected
  vnc_auth_on || return 0
  local types="" i
  for i in $(seq 5); do
    types="$(rfb_auth_types)"
    case "$types" in *error*) sleep 2 ;; *) break ;; esac
  done
  case ",$types," in
    *,1,*) die "x11vnc is offering password-less access (RFB security types: $types) - refusing to go on" ;;
    *,2,*) log "verified: x11vnc asks for the password (RFB security types: $types)" ;;
    *)     warn "could not verify the VNC password state: $types" ;;
  esac
}

start_web() {
  is_up websockify && return 0
  local extra=()
  websockify --help 2>&1 | grep -q -- '--heartbeat' && extra+=(--heartbeat 30)
  log "starting noVNC (websockify) on $LOCAL_URL"
  spawn websockify websockify --web "$WEBROOT" "${extra[@]}" \
    "127.0.0.1:$WEB_PORT" "127.0.0.1:$VNC_PORT"
  if wait_http "$LOCAL_URL/" 30; then log "noVNC is answering on $LOCAL_URL"; else
    tail -n 10 "$LOGS/websockify.log" >&2 || true
    warn "noVNC/websockify is not answering on $LOCAL_URL"
  fi
}

start_tunnel() {
  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then          # optional: your own named tunnel
    if ! is_up cloudflared; then
      log "starting cloudflared named tunnel"
      spawn cloudflared cloudflared tunnel --no-autoupdate --protocol http2 run --token "$CF_TUNNEL_TOKEN"
      sleep 5
    fi
    [ -n "${CF_HOSTNAME:-}" ] && echo "https://${CF_HOSTNAME}" > "$URL_FILE"
    is_up cloudflared && log "named tunnel is up (${CF_HOSTNAME:-use your own hostname})" \
                      || warn "cloudflared is not running, see $LOGS/cloudflared.log"
    return 0
  fi

  is_up cloudflared && return 0
  log "starting cloudflared quick tunnel (trycloudflare.com)"
  spawn cloudflared cloudflared tunnel --no-autoupdate --protocol http2 --url "$LOCAL_URL"
  local old url="" i
  old="$(public_url)"
  for i in $(seq 60); do
    url=$(grep -oE 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$LOGS/cloudflared.log" 2>/dev/null | head -1 || true)
    [ -n "$url" ] && break
    is_up cloudflared || break
    sleep 2
  done
  if [ -z "$url" ]; then
    tail -n 15 "$LOGS/cloudflared.log" >&2 || true
    warn "could not read the trycloudflare URL (see the log above)"
    return 1
  fi
  echo "$url" > "$URL_FILE"
  [ "$url" != "$old" ] && log "public URL: $url"
  return 0
}

# ------------------------------------------------------------------ browser
chrome_alive() { pgrep -f "user-data-dir=$CHROME_PROFILE" >/dev/null 2>&1; }
chrome_kill()  {
  pkill -f "user-data-dir=$CHROME_PROFILE" >/dev/null 2>&1 || true
  sleep 1
  rm -f "$CHROME_PROFILE/SingletonLock" "$CHROME_PROFILE/SingletonSocket" "$CHROME_PROFILE/SingletonCookie"
}
chrome_flags() {   # common flags; the caller may append --no-sandbox
  CHROME_FLAGS=(
    --no-first-run --no-default-browser-check --password-store=basic
    --disable-gpu --disable-dev-shm-usage
    --start-maximized --window-position=0,0 --force-device-scale-factor=1
    --hide-crash-restore-bubble
    --test-type                       # hides the "unsupported flag" infobar (we may need --no-sandbox)
    --disable-features=Translate,TranslateUI,MediaRouter
  )
  if [ -n "${CHROME_LANG:-}" ]; then
    CHROME_FLAGS+=(--lang="$CHROME_LANG" --accept-lang="$CHROME_LANG,en-US,en")
  fi
}

chrome_launch() {   # chrome_launch <url> [extra flags...]
  local url="$1"; shift
  local cenv=()
  # Chrome's UI language follows LANGUAGE (the --lang flag alone is not always enough on Linux).
  if [ -n "${CHROME_LANG:-}" ]; then cenv=(env "LANGUAGE=${CHROME_LANG}:en"); fi
  nohup "${cenv[@]}" "$CHROME_BIN" --user-data-dir="$CHROME_PROFILE" "$@" "${CHROME_FLAGS[@]}" "$url" \
    >"$LOGS/chrome.log" 2>&1 </dev/null &
}

start_chrome() {
  chrome_alive && return 0
  [ -n "$CHROME_BIN" ] || resolve_chrome || { warn "the Chrome binary was not found"; return 1; }
  local url="${START_URL:-$LOCAL_URL/home.html}"
  chrome_flags
  mkdir -p "$CHROME_PROFILE"

  # The .deb ships a setuid-root sandbox helper, which normally works on a runner.
  # Inside stricter containers it does not, and the only way to run is --no-sandbox;
  # remember that decision for the rest of the session (file also survives a restart of Chrome).
  local sandbox=()
  if [ -f "$WORK/chrome-no-sandbox" ]; then sandbox=(--no-sandbox); fi

  log "starting Google Chrome on $url"
  chrome_launch "$url" "${sandbox[@]}"
  sleep 6
  if ! chrome_alive; then
    warn "the sandbox killed Chrome (normal in containers), switching to --no-sandbox"
    touch "$WORK/chrome-no-sandbox"
    chrome_kill
    chrome_launch "$url" --no-sandbox
    sleep 6
  fi

  local wid=""
  wid=$(xdotool search --onlyvisible --class google-chrome 2>/dev/null | tail -1 || true)
  if [ -n "$wid" ]; then
    wmctrl -i -r "$wid" -b add,maximized_vert,maximized_horz >/dev/null 2>&1 || true
  fi
  chrome_alive && log "Chrome is running" || warn "Chrome does not look alive, see $LOGS/chrome.log"
}

# ------------------------------------------------------------------ web pages
novnc_query() {
  printf 'autoconnect=1&path=websockify&resize=scale&quality=%s&compression=%s&reconnect=1&reconnect_delay=2000&show_dot=1' \
    "$NOVNC_QUALITY" "$NOVNC_COMPRESSION"
}

render_page() {   # render_page <template> <destination>
  sed -e "s|__NOVNC_QUERY__|$(esc "$(novnc_query)")|g" \
      -e "s|__URL__|$(esc "$(public_url)")|g" \
      -e "s|__RES__|$(esc "$RESOLUTION")|g" \
      -e "s|__START__|$(esc "$SESSION_START")|g" \
      -e "s|__END__|$(esc "$(session_end)")|g" \
      -e "s|__END_EPOCH__|$(session_end_epoch)|g" \
      -e "s|__HOST__|$(esc "$(hostname)")|g" \
      -e "s|__OS__|$(esc "$(os_name)")|g" \
      -e "s|__OS_PRETTY__|$(esc "$(os_pretty)")|g" \
      -e "s|__IMAGE__|$(esc "$(image_version)")|g" \
      -e "s|__CHROME__|$(esc "$(chrome_version) (${CHROME_CHANNEL})")|g" \
      -e "s|__CHROME_VERSION__|$(esc "$(chrome_version)")|g" \
      -e "s|__CHANNEL__|$(esc "$CHROME_CHANNEL")|g" \
      -e "s|__AUTH_STATE__|$(esc "$(auth_state)")|g" \
      -e "s|__AUTH_NOTE__|$(esc "$(auth_note)")|g" \
      -e "s|__DESKTOP_LABEL__|$(esc "$(desktop_label)")|g" \
      -e "s|__CORES__|$(nproc)|g" \
      -e "s|__RAM__|$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )) MB|g" \
      -e "s|__DISK__|$(df -h --output=size / | tail -1 | tr -d ' ')|g" \
      -e "s|__ARCH__|$(uname -m)|g" \
      "$1" > "$2"
}

render_pages() {
  mkdir -p "$WEBROOT"
  render_page "$ASSETS/web/index.html" "$WEBROOT/index.html"
  render_page "$ASSETS/web/home.html"  "$WEBROOT/home.html"
}

# ------------------------------------------------------------------ announce
announce() {
  local url="$1" end; end="$(session_end)"
  log "──────────────────────────────────────────────────────────────"
  log "Cloud Chromebook is ready"
  log "open this in your browser: ${url:-<not ready, check the trycloudflare step>}"
  log "screen ${RESOLUTION} | Chrome $(chrome_version) (${CHROME_CHANNEL}) | $(os_name)"
  log "desktop: $([ "${DESKTOP_ACTIVE:-classic}" = "ubuntu" ] && echo 'Ubuntu GNOME (Yaru theme, Ubuntu dock)' || echo 'classic Chromebook shelf (openbox + tint2)')"
  log "password: $(auth_line)"
  log "session ends ~${end}"
  log "──────────────────────────────────────────────────────────────"
  if [ -n "$url" ]; then
    echo "::notice title=Cloud Chromebook (open in your browser)::$url"
    {
      echo "## 🖥️ Cloud Chromebook"
      echo
      echo "**Open this link in your own browser:** <${url}>"
      echo
      echo "| | |"
      echo "|---|---|"
      echo "| Screen | ${RESOLUTION} |"
      echo "| System | $(os_name) |"
      echo "| Desktop | $([ "${DESKTOP_ACTIVE:-classic}" = "ubuntu" ] && echo 'Ubuntu · GNOME Shell + Yaru' || echo 'classic · openbox + floating shelf') |"
      echo "| Browser | Google Chrome $(chrome_version) · ${CHROME_CHANNEL} channel |"
      echo "| Runner | \`$(hostname)\` · $(nproc) vCPU · $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )) MB RAM |"
      if vnc_auth_on; then
        echo "| Password | ✅ required (VNC/RFB) |"
      else
        echo "| Password | ⚠️ **none** — the link alone opens the desktop |"
      fi
      echo "| Session ends | ${end} |"
      echo
      if [ "${DESKTOP_ACTIVE:-classic}" = "classic" ] && [ "$(ubuntu_version_num)" -ge 2510 ]; then
        echo "> ℹ️ GNOME on this image ($( . /etc/os-release; printf '%s' "${PRETTY_NAME:-?}" )) is Wayland only,"
        echo "> so it cannot run on Xvfb. Pass \`runner_image: ubuntu-24.04\` to get the real GNOME desktop."
        echo
      fi
      echo "> Quick tunnels are public and get a new random URL on every run, so keep the link to yourself."
      if vnc_auth_on; then
        echo "> The desktop itself asks for the password before showing anything (set it with the \`password\` input or the \`VNC_PASSWORD\` secret)."
      else
        echo "> ⚠️ This run has no password: whoever gets the link sees the desktop."
      fi
      echo "> Video streaming (YouTube etc.) is not smooth on a 2-core runner."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
  notify "Cloud Chromebook is ready: ${url:-pending} ($(vnc_auth_on && echo 'password required' || echo 'no password'))"
}

# ------------------------------------------------------------------ boot / hold
boot() {
  resolve_chrome || die "Chrome not found: run 'chromebook.sh install' first"
  have Xvfb && have x11vnc && have websockify || die "missing packages: run 'chromebook.sh install' first"

  local mode; mode="$(pick_desktop_mode)"
  log "session start ${SESSION_START} (${RESOLUTION}, budget ${SESSION_SECONDS}s, desktop ${mode})"
  rm -f "$WORK/gnome-fails"
  start_x
  set_wallpaper
  write_desktop_entries
  ensure_session_bus
  if [ "$mode" = "ubuntu" ]; then
    if ! start_gnome; then
      warn "falling back to the light classic desktop"
      mode=classic
    fi
  fi
  if [ "$mode" = "classic" ]; then
    start_wm
    start_compositor
    start_shelf
  fi
  DESKTOP_ACTIVE="$mode"
  prepare_vnc_password || true
  start_vnc || die "x11vnc did not start (VNC_PASSWORD set: $(vnc_auth_on && echo yes || echo no))"
  check_vnc_auth
  start_web
  start_tunnel || true
  render_pages
  start_chrome
  save_state
  announce "$(public_url)"
}

healthcheck() {
  if ! is_up xvfb; then
    warn "Xvfb died: rebuilding the desktop"
    stop_svc xvfb; stop_svc gnome-session; stop_svc gnome-shell; stop_svc openbox; stop_svc tint2
    stop_svc picom; stop_svc x11vnc
    start_x; set_wallpaper; write_desktop_entries
    if [ "${DESKTOP_ACTIVE:-classic}" = "ubuntu" ] && ! start_gnome; then
      warn "GNOME did not come back: using the classic desktop"
      DESKTOP_ACTIVE=classic
    fi
    if [ "${DESKTOP_ACTIVE:-classic}" = "classic" ]; then
      start_wm; start_compositor; start_shelf
    fi
    start_vnc || true
    start_web || true
    start_tunnel || true
    render_pages
    start_chrome
    return 0
  fi
  if [ "${DESKTOP_ACTIVE:-classic}" = "ubuntu" ]; then
    if ! gnome_alive; then
      local fails
      fails=$(cat "$WORK/gnome-fails" 2>/dev/null || echo 0)
      fails=$(( fails + 1 ))
      echo "$fails" > "$WORK/gnome-fails"
      if [ "$fails" -gt 2 ]; then
        warn "GNOME Shell kept dying here: staying on the classic desktop for the rest of this session"
        DESKTOP_ACTIVE=classic
        start_wm; start_compositor; start_shelf
      else
        warn "the GNOME session died (attempt ${fails} of 2): restarting it"
        stop_svc gnome-session; stop_svc gnome-shell
        if ! start_gnome; then
          warn "GNOME did not come back: switching to the classic desktop"
          DESKTOP_ACTIVE=classic
          start_wm; start_compositor; start_shelf
        fi
      fi
    fi
  else
    is_up openbox   || { warn "restarting openbox"; start_wm; }
    is_up picom     || { warn "restarting the compositor"; start_compositor; }
    is_up tint2     || { warn "restarting the tint2 shelf"; start_shelf; }
  fi
  is_up x11vnc    || { warn "restarting x11vnc"; start_vnc || warn "x11vnc could not be restarted"; }
  is_up websockify || { warn "restarting noVNC"; start_web || true; }
  if ! is_up cloudflared; then
    warn "cloudflared died: restarting (the public URL will change)"
    if start_tunnel; then
      render_pages
      announce "$(public_url)"
    fi
  fi
  chrome_alive || { warn "Chrome died: restarting"; start_chrome; }
  save_state
}

print_status() {
  local now url up left
  now="$(date +%s)"
  url="$(public_url)"
  up=$(( (now - ${JOB_START:-$now}) / 60 ))
  if [ "${SESSION_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    left=$(( (${JOB_START:-$now} + SESSION_SECONDS - now) / 60 ))
  else
    left=-1
  fi
  log "status: ${url:-<no url>} | ${RESOLUTION} | up ${up}m | $([ "$left" -ge 0 ] && echo "left ${left}m" || echo "no limit")"
  if [ -n "$url" ]; then
    { echo "**Live URL (updated $(date -u '+%H:%M UTC')):** <${url}>"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
}

hold() {
  load_state
  local deadline=$(( ${JOB_START:-$(date +%s)} + SESSION_SECONDS ))
  local now next_status=0 chain=false
  trap 'log "stop signal received: finishing"; exit 0' INT TERM
  if [ "${SESSION_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    log "watchdog on; this session runs until $(date -u -d "@$deadline" '+%H:%M') UTC"
  else
    log "watchdog on; no session limit configured"
  fi
  while :; do
    now="$(date +%s)"
    if [ "${SESSION_SECONDS:-0}" -gt 0 ] 2>/dev/null && [ "$now" -ge "$deadline" ]; then break; fi
    healthcheck
    if [ "$now" -ge "$next_status" ]; then print_status; next_status=$(( now + 300 )); fi
    sleep 20 & wait $! || true
  done
  log "session time is over"
  if [ "${CHAIN:-false}" = "true" ]; then
    chain=true
    log "a fresh run will be dispatched by the workflow (new URL, new desktop)"
  fi
  echo "chain=$chain"    >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "status=finished" >> "${GITHUB_OUTPUT:-/dev/null}"
}

status() {
  load_state
  local url res mode s list
  url="$(public_url)"
  res="$(xdpyinfo -display "$DISPLAY" 2>/dev/null | awk '/dimensions:/{print $2; exit}')"
  mode="${DESKTOP_ACTIVE:-$(pick_desktop_mode)}"
  printf 'url=%s\n' "$url"
  printf 'display=%s res=%s\n' "$DISPLAY" "${res:-$RESOLUTION}"
  printf 'system=%s\n' "$(os_name)"
  printf 'browser=%s\n' "$([ -n "$CHROME_BIN" ] || resolve_chrome; chrome_version) (${CHROME_CHANNEL} channel)"
  printf 'auth=%s\n' "$(auth_line)"
  printf 'desktop=%s\n' "$mode"
  if [ "$mode" = "ubuntu" ]; then
    list="xvfb gnome-session x11vnc websockify cloudflared"
  else
    list="xvfb openbox picom tint2 x11vnc websockify cloudflared"
  fi
  for s in $list; do
    printf '%-12s %s\n' "$s" "$(is_up "$s" && echo up || echo DOWN)"
  done
  if [ "$mode" = "ubuntu" ]; then
    printf '%-12s %s\n' gnome-shell "$(pgrep -x gnome-shell >/dev/null && echo up || echo DOWN)"
  fi
  printf '%-12s %s\n' chrome "$(chrome_alive && echo up || echo DOWN)"
}

case "${1:-}" in
  install) install ;;
  boot)    boot ;;
  hold)    hold ;;
  url)     public_url ;;
  status)  status ;;
  shot)    shot ;;
  *) echo "usage: chromebook.sh install|boot|hold|url|status|shot" >&2; exit 2 ;;
esac
