#!/usr/bin/env bash
set -Eeuo pipefail

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

command -v sdkmanager >/dev/null || { echo 'Android sdkmanager is unavailable on this runner.'; exit 1; }
command -v avdmanager >/dev/null || { echo 'Android avdmanager is unavailable on this runner.'; exit 1; }

set +o pipefail
yes | sdkmanager --licenses >/dev/null
set -o pipefail
sdkmanager 'platform-tools' 'emulator' 'system-images;android-35;google_apis;x86_64'
command -v emulator >/dev/null || { echo 'Android emulator is unavailable after SDK installation.'; exit 1; }
echo no | avdmanager create avd \
  --force \
  --name browser-session \
  --package 'system-images;android-35;google_apis;x86_64' \
  --device pixel_6

nohup emulator \
  -avd browser-session \
  -port 5554 \
  -no-snapshot \
  -no-audio \
  -gpu swiftshader_indirect \
  -no-boot-anim \
  -camera-back none \
  >/tmp/emulator.log 2>&1 </dev/null &
echo "$!" >/tmp/emulator.pid

timeout 180 adb -s emulator-5554 wait-for-device || {
  echo 'Android emulator did not become available through adb.'
  cat /tmp/emulator.log
  exit 1
}
for i in {1..90}; do
  booted="$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [[ "$booted" == 1 ]] && break
  if ! kill -0 "$(cat /tmp/emulator.pid)" 2>/dev/null; then
    echo 'Android emulator exited during startup.'
    cat /tmp/emulator.log
    exit 1
  fi
  sleep 2
done
[[ "${booted:-}" == 1 ]] || {
  echo 'Android emulator did not finish booting.'
  cat /tmp/emulator.log
  exit 1
}

adb -s emulator-5554 shell settings put global window_animation_scale 0
adb -s emulator-5554 shell settings put global transition_animation_scale 0
adb -s emulator-5554 shell settings put global animator_duration_scale 0
adb -s emulator-5554 shell input keyevent 82 || true
echo "Android emulator is ready (Android $(adb -s emulator-5554 shell getprop ro.build.version.release | tr -d '\r'))."
