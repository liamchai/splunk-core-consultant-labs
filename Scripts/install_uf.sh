#!/bin/bash
#
# install_splunk.sh - Install Splunk Enterprise and run it as the "splunk" user.
# Run this script as root.
#

set -euo pipefail

SPLUNK_USER="splunk"
SPLUNK_HOME="/opt/splunkforwarder"
ADMIN_USER="admin"
ADMIN_PASS="9maomk44"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0: Must be run as root
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script must be run as root."

# ---------------------------------------------------------------------------
# Step 1: Create the splunk user with no password
# ---------------------------------------------------------------------------
if id "$SPLUNK_USER" >/dev/null 2>&1; then
  log "User '$SPLUNK_USER' already exists, skipping."
elif [ -f /etc/debian_version ]; then
  log "Creating user '$SPLUNK_USER' with adduser..."
  adduser --disabled-password --gecos "" "$SPLUNK_USER"
else
  # RHEL/CentOS/Rocky: adduser does not support --disabled-password.
  # useradd without a password leaves the account locked for password login.
  log "Creating user '$SPLUNK_USER' with useradd..."
  useradd -m -s /bin/bash "$SPLUNK_USER"
fi

# ---------------------------------------------------------------------------
# Step 2: Extract the tarball
# The .tgz already contains a top-level "splunk/" directory, so extract into
# /opt (not /opt/splunk) to end up with /opt/splunk/bin/splunk.
# ---------------------------------------------------------------------------
shopt -s nullglob
TARBALLS=(/opt/splunkforwarder-*.tgz)
shopt -u nullglob

[ "${#TARBALLS[@]}" -eq 1 ] || die "Expected exactly one /opt/splunkforwarder-*.tgz, found ${#TARBALLS[@]}."
[ ! -e "$SPLUNK_HOME" ] || die "$SPLUNK_HOME already exists. Remove it first if you want a fresh install."

log "Extracting ${TARBALLS[0]} into /opt..."
tar -xvzf "${TARBALLS[0]}" -C /opt
[ -x "$SPLUNK_HOME/bin/splunk" ] || die "$SPLUNK_HOME/bin/splunk not found after extraction."

# ---------------------------------------------------------------------------
# Step 3: Set owner to root
# ---------------------------------------------------------------------------
log "Setting owner of $SPLUNK_HOME to root..."
chown -R root:root "$SPLUNK_HOME"

# ---------------------------------------------------------------------------
# Step 4: Create admin credentials and first start as root
# ---------------------------------------------------------------------------
log "Creating admin credentials..."
mkdir -p "$SPLUNK_HOME/etc/system/local"
cat > "$SPLUNK_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = ${ADMIN_USER}
PASSWORD = ${ADMIN_PASS}
EOF
chmod 600 "$SPLUNK_HOME/etc/system/local/user-seed.conf"

log "Starting Splunk as root for the first time..."
"$SPLUNK_HOME/bin/splunk" start --accept-license --answer-yes --no-prompt

# Splunk consumes user-seed.conf on first start; remove it if it is still there
rm -f "$SPLUNK_HOME/etc/system/local/user-seed.conf"

# ---------------------------------------------------------------------------
# Step 5: Hand over to the splunk user
# ---------------------------------------------------------------------------
log "Stopping Splunk (root)..."
"$SPLUNK_HOME/bin/splunk" stop

log "Changing owner of $SPLUNK_HOME to $SPLUNK_USER..."
chown -R "$SPLUNK_USER": "$SPLUNK_HOME"

# The init script runs '"$SPLUNK_HOME/bin/splunk"' inside single quotes, so
# SPLUNK_HOME must be defined in the splunk user's login shell.
SPLUNK_USER_HOME="$(getent passwd "$SPLUNK_USER" | cut -d: -f6)"
PROFILE="$SPLUNK_USER_HOME/.bash_profile"
for f in .bash_profile .bash_login .profile; do
  if [ -f "$SPLUNK_USER_HOME/$f" ]; then
    PROFILE="$SPLUNK_USER_HOME/$f"
    break
  fi
done

if ! grep -q '^export SPLUNK_HOME=' "$PROFILE" 2>/dev/null; then
  log "Adding SPLUNK_HOME to $PROFILE..."
  echo "export SPLUNK_HOME=$SPLUNK_HOME" >> "$PROFILE"
  chown "$SPLUNK_USER": "$PROFILE"
fi

# ---------------------------------------------------------------------------
# Step 6: Enable boot start as the splunk user and install the init script
# ---------------------------------------------------------------------------
log "Enabling boot start for user $SPLUNK_USER..."
"$SPLUNK_HOME/bin/splunk" enable boot-start -user "$SPLUNK_USER" -systemd-managed 0

log "Writing /etc/init.d/splunk..."
cat > /etc/init.d/splunk <<'EOF'
#!/bin/sh
#
# chkconfig: 2345 90 60
# description: Splunk indexer service
#

RETVAL=0
USER=splunk

. /etc/init.d/functions

splunk_start() {
  echo Starting Splunk...
  su - ${USER} -c '"$SPLUNK_HOME/bin/splunk" start --no-prompt --answer-yes'
  RETVAL=$?
  [ $RETVAL -eq 0 ] && touch /var/lock/subsys/splunk
}
splunk_stop() {
  echo Stopping Splunk...
  su - ${USER} -c '"$SPLUNK_HOME/bin/splunk" stop'
  RETVAL=$?
  [ $RETVAL -eq 0 ] && rm -f /var/lock/subsys/splunk
}
splunk_restart() {
  echo Restarting Splunk...
  su - ${USER} -c '"$SPLUNK_HOME/bin/splunk" restart'
  RETVAL=$?
  [ $RETVAL -eq 0 ] && touch /var/lock/subsys/splunk
}
splunk_status() {
  echo Splunk status:
  su - ${USER} -c '"$SPLUNK_HOME/bin/splunk" status'
  RETVAL=$?
}
case "$1" in
  start)
    splunk_start
    ;;
  stop)
    splunk_stop
    ;;
  restart)
    splunk_restart
    ;;
  status)
    splunk_status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac

exit $RETVAL
EOF
chmod 755 /etc/init.d/splunk

if [ ! -f /etc/init.d/functions ]; then
  echo "WARNING: /etc/init.d/functions not found (non-RHEL system)." >&2
  echo "         Remove the '. /etc/init.d/functions' line from /etc/init.d/splunk." >&2
fi

if command -v chkconfig >/dev/null 2>&1; then
  chkconfig --add splunk
  chkconfig splunk on
elif command -v update-rc.d >/dev/null 2>&1; then
  update-rc.d splunk defaults
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
# Step 7: Enable HTTPS for Splunk Web (uses Splunk's default certificate)
# ---------------------------------------------------------------------------
WEB_CONF="$SPLUNK_HOME/etc/system/local/web.conf"
log "Enabling HTTPS in $WEB_CONF..."

if [ -f "$WEB_CONF" ] && grep -q '^enableSplunkWebSSL' "$WEB_CONF"; then
  sed -i 's/^enableSplunkWebSSL.*/enableSplunkWebSSL = true/' "$WEB_CONF"
elif [ -f "$WEB_CONF" ] && grep -q '^\[settings\]' "$WEB_CONF"; then
  sed -i '/^\[settings\]/a enableSplunkWebSSL = true' "$WEB_CONF"
else
  printf '\n[settings]\nenableSplunkWebSSL = true\n' >> "$WEB_CONF"
fi
chown "$SPLUNK_USER": "$WEB_CONF"

# ---------------------------------------------------------------------------
# Step 8: Start Splunk as the splunk user with the splunk binary
# ---------------------------------------------------------------------------
log "Starting Splunk as $SPLUNK_USER..."
su - "$SPLUNK_USER" -c "$SPLUNK_HOME/bin/splunk start --no-prompt --answer-yes"

HOST="$(hostname -f 2>/dev/null || hostname)"
log "Done. Splunk Web: https://${HOST}:8000  (login: ${ADMIN_USER})"
