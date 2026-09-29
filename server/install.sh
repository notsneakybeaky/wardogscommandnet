#!/usr/bin/env bash
# Sets up the squad leader bot next to an Ubuntu/Debian mumble-server.
# Usage:  sudo SQUADS=4 bash install.sh      (SQUADS = max number of squad channels, 0 = no limit)
set -euo pipefail

SQUADS="${SQUADS:-4}"
LEADER_KEY_HINT="${LEADER_KEY_HINT:-V}"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/squad-bot

[ "$(id -u)" -eq 0 ] || { echo "Run this with sudo."; exit 1; }

INI=/etc/mumble/mumble-server.ini
[ -f "$INI" ] || INI=/etc/mumble-server.ini
[ -f "$INI" ] || { echo "Could not find mumble-server.ini"; exit 1; }

SLICE=/etc/mumble/MumbleServer.ice
[ -f "$SLICE" ] || SLICE="$(find /etc /usr/share -name MumbleServer.ice 2>/dev/null | head -n1)"
[ -n "$SLICE" ] && [ -f "$SLICE" ] || { echo "Could not find MumbleServer.ice"; exit 1; }

echo "==> Installing Python Ice packages"
apt-get update -qq
apt-get install -y -qq python3-zeroc-ice zeroc-ice-slice

# Set "key=value" in the ini's top (general) section, whether the key exists, is commented out, or is missing.
set_ini() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" "$INI"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$INI"
    elif grep -qE "^;[[:space:]]*${key}=" "$INI"; then
        sed -i "0,/^;[[:space:]]*${key}=.*/s||${key}=${value}|" "$INI"
    else
        sed -i "1i ${key}=${value}" "$INI"
    fi
}

echo "==> Configuring $INI"
[ -f "$INI.before-squad-bot" ] || cp "$INI" "$INI.before-squad-bot"
SECRET="$(grep -E '^icesecretwrite=' "$INI" | head -n1 | cut -d= -f2- | tr -d '"' || true)"
if [ -z "$SECRET" ]; then
    SECRET="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
fi
set_ini ice '"tcp -h 127.0.0.1 -p 6502"'
set_ini icesecretwrite "$SECRET"
if [ "$SQUADS" -gt 0 ]; then
    set_ini channelcountlimit "$((SQUADS + 1))"   # +1 because Root counts as a channel
fi

echo "==> Installing bot to $DEST"
mkdir -p "$DEST"
install -m 644 "$SRC/squad_leader_bot.py" "$DEST/squad_leader_bot.py"
install -m 644 "$SLICE" "$DEST/MumbleServer.ice"
umask 077
cat > /etc/squad-bot.env <<EOF
MUMBLE_ICE_SECRET=$SECRET
LEADER_KEY_HINT=$LEADER_KEY_HINT
EOF
install -m 644 "$SRC/squad-bot.service" /etc/systemd/system/squad-bot.service

echo "==> Restarting Mumble server and starting bot"
systemctl restart mumble-server
sleep 2
systemctl daemon-reload
systemctl enable --now squad-bot
systemctl restart squad-bot
sleep 3
systemctl --no-pager --lines=15 status squad-bot || true

echo
echo "Done. Squad limit: ${SQUADS} (0 = unlimited). Watch the bot with:  journalctl -u squad-bot -f"
