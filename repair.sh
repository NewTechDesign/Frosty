#!/system/bin/sh
# fix_all.sh
# Full "immunity" (Doze / AppOps / Standby / Freezer / Jobscheduler /
# OEM autostart / netpolicy / runtime permissions) for a list of packages.
# Run AS ROOT, after removing Frosty and REBOOTING.

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

# AppOps that we allow
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
PROJECT_MEDIA
ACTIVATE_VPN
QUERY_ALL_PACKAGES
AUTO_START
"

# Runtime permissions that we try to grant (for music apps / messengers / background)
PERMS="
android.permission.POST_NOTIFICATIONS
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK
android.permission.FOREGROUND_SERVICE_DATA_SYNC
android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE
android.permission.READ_MEDIA_AUDIO
android.permission.READ_MEDIA_VIDEO
android.permission.READ_MEDIA_IMAGES
android.permission.READ_EXTERNAL_STORAGE
android.permission.WRITE_EXTERNAL_STORAGE
android.permission.ACCESS_MEDIA_LOCATION
android.permission.WAKE_LOCK
android.permission.RECEIVE_BOOT_COMPLETED
android.permission.BLUETOOTH_CONNECT
android.permission.BLUETOOTH_SCAN
android.permission.MODIFY_AUDIO_SETTINGS
android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
android.permission.SCHEDULE_EXACT_ALARM
android.permission.USE_EXACT_ALARM
"

LOG="/data/local/tmp/fix_all.log"

# ─────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "ERROR: must be run as root (su)"
    exit 1
  fi
}

# returns a space-separated list of user_id
all_user_ids() {
  local _ids
  _ids=$(pm list users 2>/dev/null | grep -oE 'UserInfo\{[0-9]+' | grep -oE '[0-9]+')
  [ -z "$_ids" ] && _ids=$(ls /data/user 2>/dev/null)
  [ -z "$_ids" ] && _ids="0"
  echo "$_ids"
}

# UID of the package (first user, usually 0)
pkg_uid() {
  local pkg="$1" uid
  uid=$(dumpsys package "$pkg" 2>/dev/null \
    | grep -m1 "userId=" | grep -o 'userId=[0-9]*' | cut -d= -f2)
  [ -z "$uid" ] && uid=$(pm list packages -U 2>/dev/null \
    | grep -F "$pkg" | awk -F'uid:' '{print $2}' | head -1)
  echo "$uid"
}

# whether the package is installed in at least one user
pkg_installed() {
  pm list packages 2>/dev/null | grep -qx "package:$1"
}

# ─────────────────────────────────────────────────────────────
# 1. Doze runtime whitelist
# ─────────────────────────────────────────────────────────────
fix_doze() {
  local pkg="$1"
  dumpsys deviceidle whitelist "+$pkg"        >/dev/null 2>&1
  cmd deviceidle whitelist "+$pkg"            >/dev/null 2>&1
  cmd deviceidle sys-whitelist "+$pkg"        >/dev/null 2>&1
  cmd deviceidle except-idle-whitelist "+$pkg" >/dev/null 2>&1
  log "  [+] doze whitelist (user/sys/except-idle): $pkg"
}

# ─────────────────────────────────────────────────────────────
# 2. Doze XML (persistent) + restorecon
# ─────────────────────────────────────────────────────────────
fix_doze_xml() {
  local pkg="$1"
  local xml="/data/system/deviceidle.xml"
  [ -f "$xml" ] || return 0
  grep -q "<wl n=\"$pkg\"" "$xml" 2>/dev/null && return 0
  if grep -q '</config>' "$xml"; then
    sed -i "s#</config>#<wl n=\"$pkg\" />\n</config>#" "$xml" 2>/dev/null
    restorecon "$xml" 2>/dev/null
    log "  [+] deviceidle.xml: added $pkg"
  fi
}

# ─────────────────────────────────────────────────────────────
# 3. Standby bucket → active
# ─────────────────────────────────────────────────────────────
fix_standby() {
  local pkg="$1"
  am set-standby-bucket "$pkg" active      >/dev/null 2>&1
  am set-standby-bucket --user 0 "$pkg" active >/dev/null 2>&1
  log "  [+] standby bucket = active: $pkg"
}

# ─────────────────────────────────────────────────────────────
# 4. AppOps: reset + allow the extended list
# ─────────────────────────────────────────────────────────────
fix_appops() {
  local pkg="$1"
  cmd appops reset "$pkg"        >/dev/null 2>&1
  cmd appops reset --uid "$pkg"  >/dev/null 2>&1
  cmd appops reset -p "$pkg"     >/dev/null 2>&1

  local op
  for op in $OPS; do
    cmd appops set "$pkg" "$op" allow          >/dev/null 2>&1
    cmd appops set --uid "$pkg" "$op" allow    >/dev/null 2>&1
  done
  log "  [+] appops reset + allow ($OPS): $pkg"
}

# ─────────────────────────────────────────────────────────────
# 5. Battery optimization + am set-inactive --user
# ─────────────────────────────────────────────────────────────
fix_battery() {
  local pkg="$1" u
  for u in $(all_user_ids); do
    am set-inactive --user "$u" "$pkg" false >/dev/null 2>&1
  done
  cmd deviceidle whitelist "+$pkg" >/dev/null 2>&1
  dumpsys deviceidle whitelist "+$pkg" >/dev/null 2>&1
  log "  [+] battery optimization + inactive=false: $pkg"
}

# ─────────────────────────────────────────────────────────────
# 6. Runtime permissions
# ─────────────────────────────────────────────────────────────
fix_permissions() {
  local pkg="$1" p
  for p in $PERMS; do
    pm grant "$pkg" "$p" >/dev/null 2>&1
  done
  # SYSTEM_ALERT_WINDOW — only via appops (already in OPS)
  cmd appops set "$pkg" SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
  log "  [+] runtime permissions granted: $pkg"
}

# ─────────────────────────────────────────────────────────────
# 7. Jobscheduler: give it a nudge (cancelled Frosty jobs cannot be restored,
#    but we can ask the system to run the package's jobs)
# ─────────────────────────────────────────────────────────────
fix_jobscheduler() {
  local pkg="$1" uid
  uid=$(pkg_uid "$pkg")
  [ -z "$uid" ] && return 0
  cmd jobscheduler run -f -u "$uid" "$pkg" >/dev/null 2>&1
  log "  [+] jobscheduler run: $pkg (uid=$uid)"
}

# ─────────────────────────────────────────────────────────────
# 8. Freezer cgroup (use_freezer=true)
# ─────────────────────────────────────────────────────────────
fix_freezer() {
  local pkg="$1" uid
  uid=$(pkg_uid "$pkg")
  [ -z "$uid" ] && return 0
  local f
  for f in \
    "/sys/fs/cgroup/freezer/uid_${uid}/cgroup.freeze" \
    "/sys/fs/cgroup/freezer/uid_${uid}/freezer.state" \
    "/sys/fs/cgroup/freezer/uid_${uid}/freezer" ; do
    [ -e "$f" ] && { echo 0 > "$f" 2>/dev/null; log "  [+] freezer=0: $f"; }
  done
}

# ─────────────────────────────────────────────────────────────
# 9. netpolicy: remove from blacklist, add to whitelist
# ─────────────────────────────────────────────────────────────
fix_netpolicy() {
  local pkg="$1" uid
  uid=$(pkg_uid "$pkg")
  [ -z "$uid" ] && return 0
  cmd netpolicy remove restrict-background-blacklist "$uid" >/dev/null 2>&1
  cmd netpolicy add restrict-background-whitelist "$uid"    >/dev/null 2>&1
  log "  [+] netpolicy: whitelisted $pkg (uid=$uid)"
}

# ─────────────────────────────────────────────────────────────
# 10. OEM autostart (real keys, not fake cmd)
# ─────────────────────────────────────────────────────────────
fix_oem() {
  local pkg="$1"

  # MIUI / HyperOS
  cmd appops set "$pkg" AUTO_START allow >/dev/null 2>&1
  settings put secure miui.allow_autostart "$pkg" 1 >/dev/null 2>&1

  # vivo / iQOO
  settings put secure com.vivo.permissionmanager.allow_bg_start "$pkg" 1 >/dev/null 2>&1
  settings put secure com.vivo.permissionmanager.allow_bg_show  "$pkg" 1 >/dev/null 2>&1
  settings put secure com.iqoo.secure.permissionmanager.allow_bg_start "$pkg" 1 >/dev/null 2>&1

  # Samsung
  settings put secure com.samsung.android.sm.allow_bg_start "$pkg" 1 >/dev/null 2>&1

  # Oppo / Realme / OnePlus (ColorOS)
  cmd appops set "$pkg" START_FOREGROUND allow >/dev/null 2>&1

  log "  [+] OEM autostart keys: $pkg"
}

# ─────────────────────────────────────────────────────────────
# 11. Forced restart (reset the process)
# ─────────────────────────────────────────────────────────────
restart_pkg() {
  local pkg="$1"
  am force-stop "$pkg" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────
# Verification
# ─────────────────────────────────────────────────────────────
verify_pkg() {
  local pkg="$1"
  local bucket inactive wl wlbg ign batt_uid
  bucket=$(am get-standby-bucket "$pkg" 2>/dev/null | tr -d '\r')
  inactive=$(am get-inactive --user 0 "$pkg" 2>/dev/null \
    | tr -d '\r' | grep -oE 'Inactive: ?(true|false)' | awk '{print $2}')
  wl=$(cmd appops get "$pkg" WAKE_LOCK 2>/dev/null | head -1)
  wlbg=$(cmd appops get "$pkg" RUN_ANY_IN_BACKGROUND 2>/dev/null | head -1)
  ign=$(cmd appops get "$pkg" IGNORE_BATTERY_OPTIMIZATIONS 2>/dev/null | head -1)
  batt_uid=$(dumpsys deviceidle whitelist 2>/dev/null | grep -c "$pkg")

  log "    bucket=$bucket  inactive=${inactive:-?}  wl=$wl"
  log "    run_bg=$wlbg  ign=$ign  whitelist_hits=$batt_uid"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
require_root
: > "$LOG"
log "=== fix_all.sh start ==="
log "users: $(all_user_ids)"

for PKG in $PKGS; do
  if ! pkg_installed "$PKG"; then
    log ""
    log "=== SKIP (not installed): $PKG ==="
    continue
  fi

  log ""
  log "==================================================="
  log " FIXING: $PKG"
  log "==================================================="

  fix_doze           "$PKG"
  fix_doze_xml       "$PKG"
  fix_standby        "$PKG"
  fix_appops         "$PKG"
  fix_battery        "$PKG"
  fix_permissions    "$PKG"
  fix_jobscheduler   "$PKG"
  fix_freezer        "$PKG"
  fix_netpolicy      "$PKG"
  fix_oem            "$PKG"

  restart_pkg        "$PKG"

  log "  -- verify --"
  verify_pkg         "$PKG"
done

log ""
log "=== DONE. Reboot recommended. Log: $LOG ==="
