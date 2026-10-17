#!/usr/bin/env bash
set -Eeuo pipefail

: "${DISPLAY:=:99}"
: "${VNC_PASSWORD:?Set the repository secret VNC_PASSWORD before running this workflow}"
: "${SESSION_MINUTES:=20}"

if ! [[ "$SESSION_MINUTES" =~ ^[0-9]+$ ]] || (( SESSION_MINUTES < 5 || SESSION_MINUTES > 30 )); then
  echo 'SESSION_MINUTES must be a whole number from 5 to 30.'
  exit 1
fi

cleanup() {
  set +e
  [[ -n "${TUNNEL_PID:-}" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -n "${NOVNC_PID:-}" ]] && kill "$NOVNC_PID" 2>/dev/null || true
  [[ -n "${VNC_PID:-}" ]] && kill "$VNC_PID" 2>/dev/null || true
}
trap cleanup EXIT

adb wait-for-device
for i in {1..60}; do
  booted="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [[ "$booted" == "1" ]] && break
  sleep 2
done
[[ "${booted:-}" == "1" ]] || { echo 'Emulator did not finish booting'; exit 1; }
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell input keyevent 82 || true

echo "Emulator is ready:"
adb devices
adb shell getprop ro.build.version.release

passfile=/tmp/x11vnc.pass
x11vnc -storepasswd "$VNC_PASSWORD" "$passfile" >/dev/null
X11VNC_DISPLAY="$DISPLAY" x11vnc \
  -display "$DISPLAY" \
  -rfbport 5900 \
  -rfbauth "$passfile" \
  -forever -shared -noxdamage -repeat -localhost \
  >/tmp/x11vnc.log 2>&1 &
VNC_PID=$!

websockify --web /usr/share/novnc 6080 localhost:5900 \
  >/tmp/novnc.log 2>&1 &
NOVNC_PID=$!

for i in {1..30}; do
  vnc_ready=false
  web_ready=false
  timeout 1 bash -c ': >/dev/tcp/127.0.0.1/5900' 2>/dev/null && vnc_ready=true
  curl -fsS http://127.0.0.1:6080/vnc.html >/dev/null 2>&1 && web_ready=true
  if [[ "$vnc_ready" == true && "$web_ready" == true ]]; then
    break
  fi
  if ! kill -0 "$VNC_PID" 2>/dev/null || ! kill -0 "$NOVNC_PID" 2>/dev/null; then
    echo 'VNC or noVNC web proxy exited during startup.'
    cat /tmp/x11vnc.log /tmp/novnc.log
    exit 1
  fi
  sleep 1
done

if [[ "$vnc_ready" != true || "$web_ready" != true ]]; then
  echo 'VNC or noVNC web proxy did not become ready within 30 seconds.'
  cat /tmp/x11vnc.log /tmp/novnc.log
  exit 1
fi

echo 'Starting temporary HTTPS tunnel. The URL below is the browser entry point:'
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o /tmp/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x /tmp/cloudflared
  CLOUDFLARED=/tmp/cloudflared
fi
: "${CLOUDFLARED:=cloudflared}"
"$CLOUDFLARED" tunnel --no-autoupdate --url http://127.0.0.1:6080 \
  2>&1 | tee /tmp/cloudflared.log &
TUNNEL_PID=$!

for i in {1..30}; do
  url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)"
  [[ -n "$url" ]] && break
  sleep 1
done
[[ -n "${url:-}" ]] || { cat /tmp/cloudflared.log; exit 1; }

echo "BROWSER_URL=${url}/vnc.html?autoconnect=true&resize=scale"
echo 'Open the URL above, choose Connect, and enter the VNC_PASSWORD repository secret.'
echo "Holding session for ${SESSION_MINUTES} minute(s)."
sleep "$((SESSION_MINUTES * 60))"
