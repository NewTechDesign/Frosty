cat > /data/local/tmp/status.sh <<'EOF'
#!/system/bin/sh

PKGS="
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

echo "==================================================="
echo " DOZE WHITELIST (deviceidle)"
echo "==================================================="
DOZE_WHITELIST=$(dumpsys deviceidle whitelist 2>/dev/null)
DOZE_SYS=$(dumpsys deviceidle sys-whitelist 2>/dev/null)
DOZE_EXCEPT=$(dumpsys deviceidle except-idle-whitelist 2>/dev/null)

for PKG in $PKGS; do
  echo
  echo "=== $PKG ==="
  if echo "$DOZE_WHITELIST" | grep -q "$PKG"; then
    echo "  [doze user]    WHITELISTED"
  else
    echo "  [doze user]    not whitelisted"
  fi
  if echo "$DOZE_SYS" | grep -q "$PKG"; then
    echo "  [doze sys]     WHITELISTED"
  else
    echo "  [doze sys]     not whitelisted"
  fi
  if echo "$DOZE_EXCEPT" | grep -q "$PKG"; then
    echo "  [doze except]  WHITELISTED"
  else
    echo "  [doze except]  not whitelisted"
  fi
done

echo
echo "==================================================="
echo " APPOPS"
echo "==================================================="
OPS="IGNORE_BATTERY_OPTIMIZATIONS WAKE_LOCK RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND"

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

echo
echo "==================================================="
echo " STANDBY BUCKET"
echo "==================================================="
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

echo
echo "==================================================="
echo " INACTIVE (user 0)"
echo "==================================================="
for PKG in $PKGS; do
  INACT=$(am get-inactive --user 0 $PKG 2>/dev/null)
  STATE=$(echo "$INACT" | tr -d '\r' | grep -oE "Inactive: ?(true|false)" | awk '{print $2}')
  [ -z "$STATE" ] && STATE="n/a (needs root)"
  printf "  %-35s inactive=%s\n" "$PKG" "$STATE"
done

echo
echo "Done."
EOF
sh /data/local/tmp/status.sh
