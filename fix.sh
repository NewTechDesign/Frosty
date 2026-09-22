
cat > /data/local/tmp/fix.sh << 'EOF'
#!/system/bin/sh

# =========================================================
#  Doze / AppOps / Standby / Background fixer
#  Usage:
#    sh status.sh                - diagnostics only
#    sh status.sh --fix          - apply all fixes
#    sh status.sh --fix <pkg>    - fix a single package
# =========================================================

PKGS="
com.spotify.music
com.google.android.apps.youtube.music
ru.yandex.music
com.gokadzev.musify.fdroid
com.theveloper.pixelplay
org.oxycblt.auxio
com.sosauce.cutemusic
org.telegram.messenger
com.whatsapp.w4b
com.whatsapp
com.google.android.gms
com.google.android.youtube
tv.twitch.android.app
com.discord
com.x8bit.bitwarden
"

OPS="
IGNORE_BATTERY_OPTIMIZATIONS
WAKE_LOCK
RUN_ANY_IN_BACKGROUND
RUN_IN_BACKGROUND
START_FOREGROUND
BOOT_COMPLETED
SCHEDULE_EXACT_ALARM
USE_EXACT_ALARM
POST_NOTIFICATION
FOREGROUND_SERVICE
FOREGROUND_SERVICE_MEDIA_PLAYBACK
FOREGROUND_SERVICE_DATA_SYNC
FOREGROUND_SERVICE_LOCATION
FOREGROUND_SERVICE_MICROPHONE
FOREGROUND_SERVICE_CONNECTED_DEVICE
FOREGROUND_SERVICE_SPECIAL_USE
SYSTEM_ALERT_WINDOW
"

MODE="diag"
TARGET=""

case "$1" in
  --fix) MODE="fix"; TARGET="$2" ;;
  *)     MODE="diag" ;;
esac

# ---------------------------------------------------------
# helpers
# ---------------------------------------------------------
has_root() {
  [ "$(id -u)" = "0" ] && return 0
  command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0" && return 0
  return 1
}

run_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  else
    su -c "$*"
  fi
}

# ---------------------------------------------------------
# FIX functions
# ---------------------------------------------------------
fix_doze() {
  PKG="$1"
  echo "  [+] doze user whitelist: $PKG"
  run_root "dumpsys deviceidle whitelist +$PKG" >/dev/null 2>&1
  run_root "cmd deviceidle whitelist +$PKG"     >/dev/null 2>&1
}

fix_standby() {
  PKG="$1"
  echo "  [+] standby bucket = active (10): $PKG"
  run_root "am set-standby-bucket $PKG active" >/dev/null 2>&1
  run_root "am set-standby-bucket $PKG 10"     >/dev/null 2>&1
}

fix_appops() {
  PKG="$1"
  for OP in $OPS; do
    run_root "cmd appops set $PKG $OP allow" >/dev/null 2>&1
  done
  echo "  [+] appops: allow for $PKG"
}

fix_battery_optimization() {
  PKG="$1"
  echo "  [+] battery optimization: $PKG"
  run_root "dumpsys deviceidle whitelist +$PKG" >/dev/null 2>&1
  run_root "cmd deviceidle whitelist +$PKG"     >/dev/null 2>&1
  run_root "am set-inactive $PKG false"         >/dev/null 2>&1
}

fix_oem() {
  PKG="$1"
  # Xiaomi
  run_root "cmd miui whitelist +$PKG" >/dev/null 2>&1
  # Samsung
  run_root "cmd samsung whitelist +$PKG" >/dev/null 2>&1
  # Huawei
  run_root "cmd huawei whitelist +$PKG" >/dev/null 2>&1
  echo "  [+] OEM whitelist (if supported): $PKG"
}

fix_all() {
  PKG="$1"
  echo
  echo "==================================================="
  echo " FIXING: $PKG"
  echo "==================================================="
  fix_doze "$PKG"
  fix_standby "$PKG"
  fix_appops "$PKG"
  fix_battery_optimization "$PKG"
  fix_oem "$PKG"
}

# ---------------------------------------------------------
# DIAG functions
# ---------------------------------------------------------
diag_doze() {
  DOZE_WHITELIST=$(dumpsys deviceidle whitelist 2>/dev/null)
  DOZE_SYS=$(dumpsys deviceidle sys-whitelist 2>/dev/null)
  DOZE_EXCEPT=$(dumpsys deviceidle except-idle-whitelist 2>/dev/null)

  for PKG in $PKGS; do
    echo
    echo "=== $PKG ==="
    echo "$DOZE_WHITELIST" | grep -q "$PKG" && echo "  [doze user]    WHITELISTED" || echo "  [doze user]    not whitelisted"
    echo "$DOZE_SYS"      | grep -q "$PKG" && echo "  [doze sys]     WHITELISTED" || echo "  [doze sys]     not whitelisted"
    echo "$DOZE_EXCEPT"   | grep -q "$PKG" && echo "  [doze except]  WHITELISTED" || echo "  [doze except]  not whitelisted"
  done
}

diag_appops() {
  for PKG in $PKGS; do
    echo
    echo "=== $PKG ==="
    OPS_DUMP=$(cmd appops get $PKG 2>/dev/null)
    for OP in $OPS; do
      LINE=$(echo "$OPS_DUMP" | grep -E "^$OP:")
      if [ -n "$LINE" ]; then
        echo "  $LINE"
      else
        echo "  $OP: (not set / default)"
      fi
    done
  done
}

diag_standby() {
  for PKG in $PKGS; do
    BUCKET=$(am get-standby-bucket $PKG 2>/dev/null)
    case "$BUCKET" in
      5)  NAME="exempted" ;;
      10) NAME="active" ;;
      20) NAME="working_set" ;;
      30) NAME="frequent" ;;
      40) NAME="rare" ;;
      45) NAME="restricted" ;;
      50) NAME="never" ;;
      *)  NAME="unknown" ;;
    esac
    printf "  %-35s bucket=%s (%s)\n" "$PKG" "$BUCKET" "$NAME"
  done
}

diag_inactive() {
  for PKG in $PKGS; do
    INACT=$(am get-inactive --user 0 $PKG 2>/dev/null)
    STATE=$(echo "$INACT" | tr -d '\r' | grep -oE "Inactive: ?(true|false)" | awk '{print $2}')
    [ -z "$STATE" ] && STATE="n/a (needs root)"
    printf "  %-35s inactive=%s\n" "$PKG" "$STATE"
  done
}

diag_permissions() {
  echo
  echo "==================================================="
  echo " PERMISSIONS"
  echo "==================================================="
  PERMS="WAKE_LOCK FOREGROUND_SERVICE RECEIVE_BOOT_COMPLETED REQUEST_IGNORE_BATTERY_OPTIMIZATIONS SCHEDULE_EXACT_ALARM USE_EXACT_ALARM POST_NOTIFICATIONS"
  for PKG in $PKGS; do
    echo
    echo "=== $PKG ==="
    DUMP=$(dumpsys package $PKG 2>/dev/null)
    for P in $PERMS; do
      if echo "$DUMP" | grep -q "$P"; then
        GRANTED=$(echo "$DUMP" | grep -A1 "$P" | grep -oE "granted=(true|false)" | head -1)
        [ -z "$GRANTED" ] && GRANTED="granted=?"
        echo "  $P: $GRANTED"
      else
        echo "  $P: (not declared)"
      fi
    done
  done
}

diag_process() {
  echo
  echo "==================================================="
  echo " PROCESS STATE / EXIT INFO / ALARMS / JOBS"
  echo "==================================================="
  for PKG in $PKGS; do
    echo
    echo "=== $PKG ==="
    PROC=$(dumpsys activity processes 2>/dev/null | grep -A2 "$PKG" | head -3 | tr '\n' ' ')
    echo "  proc: $PROC"
    EXIT=$(dumpsys activity exit-info "$PKG" 2>/dev/null | grep -E "reason|subreason|timestamp" | head -5)
    if [ -n "$EXIT" ]; then
      echo "  exit-info:"
      echo "$EXIT" | sed 's/^/    /'
    else
      echo "  exit-info: (none)"
    fi
    ALARM=$(dumpsys alarm 2>/dev/null | grep -c "$PKG")
    JOB=$(dumpsys jobscheduler 2>/dev/null | grep -c "$PKG")
    echo "  alarms: $ALARM"
    echo "  jobs:   $JOB"
  done
}

diag_wakelocks() {
  echo
  echo "==================================================="
  echo " ACTIVE WAKELOCKS"
  echo "==================================================="
  for PKG in $PKGS; do
    WL=$(dumpsys power 2>/dev/null | grep -A3 "$PKG" | head -3 | tr '\n' ' ')
    [ -n "$WL" ] && echo "  $PKG: $WL"
  done
}

diag_oem() {
  echo
  echo "==================================================="
  echo " OEM WHITELISTS"
  echo "==================================================="
  echo "--- MIUI ---"
  dumpsys miui.power 2>/dev/null | grep -iE "whitelist|autostart" | head -20
  echo "--- Samsung ---"
  dumpsys activity service com.samsung.android.sm 2>/dev/null | head -20
  echo "--- Huawei ---"
  dumpsys huawei.power 2>/dev/null | head -20
}

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------
if [ "$MODE" = "fix" ]; then
  if [ -n "$TARGET" ]; then
    fix_all "$TARGET"
  else
    for PKG in $PKGS; do
      fix_all "$PKG"
    done
  fi
  echo
  echo "==================================================="
  echo " DONE. Restart the apps or reboot the device."
  echo "==================================================="
  exit 0
fi

# --- diag mode ---
echo "==================================================="
echo " DOZE WHITELIST (deviceidle)"
echo "==================================================="
diag_doze

echo
echo "==================================================="
echo " APPOPS"
echo "==================================================="
diag_appops

echo
echo "==================================================="
echo " STANDBY BUCKET"
echo "==================================================="
diag_standby

echo
echo "==================================================="
echo " INACTIVE (user 0)"
echo "==================================================="
diag_inactive

diag_permissions
diag_process
diag_wakelocks
diag_oem

echo
echo "Done."
EOF
chmod 755 /data/local/tmp/fix.sh

/data/local/tmp/fix.sh --fix
