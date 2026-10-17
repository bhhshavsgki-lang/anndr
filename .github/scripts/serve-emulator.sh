#!/usr/bin/env bash
set -Eeuo pipefail

: "${DISPLAY:=:99}"
: "${VNC_PASSWORD:?Set the repository secret VNC_PASSWORD before running this workflow}"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
export ANDROID_HOME
export PATH="$ANDROID_HOME/platform-tools:$PATH"

adb -s emulator-5554 wait-for-device

echo "Emulator is ready:"
adb devices

passfile=/tmp/x11vnc.pass
x11vnc -storepasswd "$VNC_PASSWORD" "$passfile" >/dev/null
nohup x11vnc \
  -display "$DISPLAY" \
  -rfbport 5900 \
  -rfbauth "$passfile" \
  -forever -shared -noxdamage -repeat -localhost \
  >/tmp/x11vnc.log 2>&1 </dev/null &
VNC_PID=$!
echo "$VNC_PID" >/tmp/x11vnc.pid

nohup websockify --web /usr/share/novnc 6080 localhost:5900 \
  >/tmp/novnc.log 2>&1 </dev/null &
NOVNC_PID=$!
echo "$NOVNC_PID" >/tmp/novnc.pid

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
nohup "$CLOUDFLARED" tunnel --no-autoupdate --url http://127.0.0.1:6080 \
  >/tmp/cloudflared.log 2>&1 </dev/null &
TUNNEL_PID=$!
echo "$TUNNEL_PID" >/tmp/cloudflared.pid

for i in {1..30}; do
  url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)"
  [[ -n "$url" ]] && break
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo 'Cloudflare tunnel exited before providing a URL.'
    cat /tmp/cloudflared.log
    exit 1
  fi
  sleep 1
done
[[ -n "${url:-}" ]] || { cat /tmp/cloudflared.log; exit 1; }

browser_url="${url}/vnc.html?autoconnect=true&resize=scale"
if ! curl -fsS --max-time 10 --retry 20 --retry-delay 2 --retry-all-errors "$browser_url" >/dev/null; then
  echo 'The temporary browser URL did not respond successfully.'
  cat /tmp/cloudflared.log
  exit 1
fi
echo "BROWSER_URL=${browser_url}"
echo "::warning title=Live Android emulator::$browser_url"
echo 'Open the URL above, choose Connect, and enter the VNC_PASSWORD repository secret.'
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## Android emulator browser session'
    echo
    echo "[Open the emulator in your browser](${browser_url})"
    echo
    echo 'When prompted, enter the repository secret `VNC_PASSWORD`.'
  } >>"$GITHUB_STEP_SUMMARY"
fi
