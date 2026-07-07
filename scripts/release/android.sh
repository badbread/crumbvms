#!/usr/bin/env bash
# Build the Android debug APK on the build host and publish it to the LAN download spot
# (http://the build host:8088/crumb.apk).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Sync Android sources to $DEV1"
# Exclude build outputs + the remote's own SDK path (local.properties) + APKs.
tar -C "$REPO_ROOT/apps/android" \
    --exclude='build' --exclude='*/build' \
    --exclude='.gradle' --exclude='*/.gradle' \
    --exclude='local.properties' --exclude='*.apk' \
    -cf - . \
  | ssh "$DEV1" "mkdir -p '$ANDROID_DIR' && tar -C '$ANDROID_DIR' --no-same-owner -xf -"

log "assembleDebug on $DEV1"
# chmod gradlew: the tar from Windows can drop the exec bit.
ssh "$DEV1" "cd ~/$ANDROID_DIR && chmod +x gradlew && ./gradlew --console=plain assembleDebug" \
  || die "android build failed"

log "Publish APK"
ssh "$DEV1" "cp ~/$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk ~/$APK_SERVE/crumb.apk \
  && (tmux has-session -t apk 2>/dev/null || tmux new-session -d -s apk 'cd ~/$APK_SERVE && python3 -m http.server 8088') \
  && curl -s -o /dev/null -w 'APK: HTTP %{http_code} %{size_download}b\n' http://127.0.0.1:8088/crumb.apk" \
  || die "publish failed"
ok "Android APK published → http://$DEV1:8088/crumb.apk"
