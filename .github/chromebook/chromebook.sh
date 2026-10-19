#!/usr/bin/env bash
# =============================================================================
#  Cloud "Chromebook" on a GitHub-hosted runner
#
#  Everything runs inside the Actions runner (its CPU / RAM / disk / network)
#  and is streamed to your own browser:
#
#      Xvfb (:99) ── openbox + tint2 shelf + Google Chrome
#            │
#            ├── x11vnc    (RFB, 127.0.0.1:5900, no password)
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
session_end() {
  local s="${SESSION_SECONDS:-0}"
  if [ "$s" -gt 0 ] 2>/dev/null; then date -u -d "@$(( $(date +%s) + s ))" '+%H:%M UTC'; else echo "—"; fi
}
public_url() { cat "$URL_FILE" 2>/dev/null || true; }
os_name() {   # "Ubuntu 26.04 LTS · image 2026xxxx" (the runner exposes ImageVersion)
  local pretty
  pretty="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}" )"
  if [ -n "${ImageVersion:-}" ]; then printf '%s · image %s' "$pretty" "$ImageVersion"; else printf '%s' "$pretty"; fi
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
  )
  log "installing desktop packages with apt (first boot takes ~2-4 minutes)"
  $SUDO apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "${pkgs[@]}"

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
  build_webroot
  log "install complete"
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
    -nolisten tcp -ac +extension RANDR -noreset
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

write_desktop_entries() {
  mkdir -p "$APPDIR"
  [ -f /usr/share/applications/google-chrome.desktop ] || cat > "$APPDIR/google-chrome.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Google Chrome
Exec=$CHROME_BIN
Icon=google-chrome
Categories=Network;WebBrowser;
EOF
  cat > "$APPDIR/cloud-terminal.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=Run apt/pip/npm inside this session
Exec=xterm -u8 -fa "DejaVu Sans Mono" -fs 11 -bg #101418 -fg #e8eaed -title "Terminal"
Icon=utilities-terminal
Categories=System;TerminalEmulator;
EOF
  cat > "$APPDIR/cloud-files.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Files
Comment=Browse the runner filesystem
Exec=pcmanfm
Icon=folder
Categories=System;FileManager;
EOF
}

# ------------------------------------------------------------------ remote access
start_vnc() {
  is_up x11vnc && return 0
  log "starting x11vnc on 127.0.0.1:$VNC_PORT"
  spawn x11vnc x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -localhost -nopw \
    -forever -shared -noxdamage -xkb -repeat -capslock -o "$LOGS/x11vnc-daemon.log" -quiet
  sleep 1
  is_up x11vnc && log "x11vnc is up" || { tail -n 5 "$LOGS/x11vnc.log" >&2 || true; warn "x11vnc failed"; }
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
      -e "s|__HOST__|$(esc "$(hostname)")|g" \
      -e "s|__OS__|$(esc "$(os_name)")|g" \
      -e "s|__CHROME__|$(esc "$(chrome_version) (${CHROME_CHANNEL})")|g" \
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
      echo "| Browser | Google Chrome $(chrome_version) · ${CHROME_CHANNEL} channel |"
      echo "| Runner | \`$(hostname)\` · $(nproc) vCPU · $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )) MB RAM |"
      echo "| Session ends | ${end} |"
      echo
      echo "> Quick tunnels are public and get a new random URL on every run."
      echo "> Video streaming (YouTube etc.) is not smooth on a 2-core runner."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
  notify "Cloud Chromebook is ready: ${url:-pending}"
}

# ------------------------------------------------------------------ boot / hold
boot() {
  resolve_chrome || die "Chrome not found: run 'chromebook.sh install' first"
  have Xvfb && have x11vnc && have websockify || die "missing packages: run 'chromebook.sh install' first"

  log "session start ${SESSION_START} (${RESOLUTION}, budget ${SESSION_SECONDS}s)"
  start_x
  set_wallpaper
  start_wm
  write_desktop_entries
  start_shelf
  start_vnc
  start_web
  start_tunnel || true
  render_pages
  start_chrome
  announce "$(public_url)"
}

healthcheck() {
  if ! is_up xvfb; then
    warn "Xvfb died: rebuilding the desktop"
    stop_svc xvfb; stop_svc openbox; stop_svc tint2; stop_svc x11vnc
    start_x; set_wallpaper; start_wm; start_shelf; start_vnc
    start_web || true
    start_tunnel || true
    render_pages
    start_chrome
    return 0
  fi
  is_up openbox   || { warn "restarting openbox"; start_wm; }
  is_up tint2     || { warn "restarting the tint2 shelf"; start_shelf; }
  is_up x11vnc    || { warn "restarting x11vnc"; start_vnc; }
  is_up websockify || { warn "restarting noVNC"; start_web || true; }
  if ! is_up cloudflared; then
    warn "cloudflared died: restarting (the public URL will change)"
    if start_tunnel; then
      render_pages
      announce "$(public_url)"
    fi
  fi
  chrome_alive || { warn "Chrome died: restarting"; start_chrome; }
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
  local url res
  url="$(public_url)"
  res="$(xdpyinfo -display "$DISPLAY" 2>/dev/null | awk '/dimensions:/{print $2; exit}')"
  printf 'url=%s\n' "$url"
  printf 'display=%s res=%s\n' "$DISPLAY" "${res:-$RESOLUTION}"
  printf 'system=%s\n' "$(os_name)"
  printf 'browser=%s\n' "$([ -n "$CHROME_BIN" ] || resolve_chrome; chrome_version) (${CHROME_CHANNEL} channel)"
  local s
  for s in xvfb openbox tint2 x11vnc websockify cloudflared; do
    printf '%-12s %s\n' "$s" "$(is_up "$s" && echo up || echo DOWN)"
  done
  printf '%-12s %s\n' chrome "$(chrome_alive && echo up || echo DOWN)"
}

case "${1:-}" in
  install) install ;;
  boot)    boot ;;
  hold)    hold ;;
  url)     public_url ;;
  status)  status ;;
  *) echo "usage: chromebook.sh install|boot|hold|url|status" >&2; exit 2 ;;
esac
