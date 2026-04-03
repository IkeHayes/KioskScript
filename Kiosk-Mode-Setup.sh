#!/usr/bin/env bash
set -euo pipefail

# Purpose:
# This script sets up a Debian-based Linux system to automatically log in a specified user and
# launch Chromium in kiosk mode pointing to a specified URL. It also configures x11vnc for remote
# access and ensures the system is optimized for kiosk use.

# Usage:
# 1. Set the KIOSK_URL variable to the desired URL to display in kiosk mode.
# 2. Set the KIOSK_USER variable to the desired username for the kiosk account.
# 3. Optionally set the HOSTNAME_SET variable to change the system hostname.
# 4. Set the VNC_PASSWORD environment variable to the desired password for x11vnc, or run the script interactively to be prompted for it.
# 5. Run the script as root: sudo bash Kiosk-Mode-Setup.sh
# 6. Reboot

# To run non-interactively with environment variable for VNC password:
# VNC_PASSWORD="yourpassword" sudo bash Kiosk-Mode-Setup.sh

########################################
# EDIT THESE SETTINGS
########################################
KIOSK_URL="https://192.168.105.29/app/operation/dashboard/summary"
KIOSK_USER="kiosk"
HOSTNAME_SET=""   # Optional, example: "industrial-kiosk-01"
# Set VNC_PASSWORD in the environment before running, or enter it when prompted.

########################################
# SANITY CHECKS
########################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

VNC_PASSWORD="${VNC_PASSWORD:-}"

echo "=== Preseeding LightDM as the default display manager ==="
if command -v debconf-set-selections >/dev/null 2>&1; then
  echo "lightdm shared/default-x-display-manager select /usr/sbin/lightdm" | debconf-set-selections
  echo "lightdm lightdm/default-display-manager select /usr/sbin/lightdm" | debconf-set-selections
fi

echo "=== Updating packages ==="
apt-get update

echo "=== Installing required packages ==="
apt-get install -y \
  snapd \
  xorg \
  openbox \
  lightdm \
  lightdm-gtk-greeter \
  x11-xserver-utils \
  x11-utils \
  x11vnc \
  unclutter \
  dbus-x11 \
  curl \
  ca-certificates \
  openssh-server

if [[ -n "$HOSTNAME_SET" ]]; then
  echo "=== Setting hostname to $HOSTNAME_SET ==="
  hostnamectl set-hostname "$HOSTNAME_SET"
fi

echo "=== Ensuring snapd is running ==="
systemctl enable snapd.service || true
systemctl start snapd.service || true
snap wait system seed.loaded || true

echo "=== Installing Chromium ==="
if ! snap list chromium >/dev/null 2>&1; then
  snap install chromium
fi

echo "=== Creating kiosk user if needed ==="
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$KIOSK_USER"
fi

echo "=== Creating needed directories ==="
install -d -m 755 -o "$KIOSK_USER" -g "$KIOSK_USER" "/home/$KIOSK_USER/.config/openbox"
install -d -m 755 -o "$KIOSK_USER" -g "$KIOSK_USER" "/home/$KIOSK_USER/.local/bin"

echo "=== Saving kiosk URL ==="
cat >/etc/kiosk-url <<EOF
$KIOSK_URL
EOF
chmod 644 /etc/kiosk-url

echo "=== Creating Openbox session entry ==="
mkdir -p /usr/share/xsessions
cat >/usr/share/xsessions/openbox.desktop <<'EOF'
[Desktop Entry]
Name=Openbox
Comment=Openbox session
Exec=openbox-session
Type=Application
DesktopNames=Openbox
EOF
chmod 644 /usr/share/xsessions/openbox.desktop

echo "=== Configuring x11vnc password ==="
mkdir -p /etc/x11vnc
if [[ -z "$VNC_PASSWORD" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Enter x11vnc password: " VNC_PASSWORD
    echo
    read -r -s -p "Confirm x11vnc password: " VNC_PASSWORD_CONFIRM
    echo
    if [[ "$VNC_PASSWORD" != "$VNC_PASSWORD_CONFIRM" ]]; then
      echo "x11vnc passwords did not match"
      exit 1
    fi
    unset VNC_PASSWORD_CONFIRM
  else
    echo "Set VNC_PASSWORD in the environment before running this script"
    exit 1
  fi
fi
x11vnc -storepasswd "$VNC_PASSWORD" /etc/x11vnc/passwd >/dev/null
unset VNC_PASSWORD
chmod 600 /etc/x11vnc/passwd

echo "=== Configuring LightDM autologin ==="
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-kiosk.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=openbox
autologin-session=openbox
greeter-hide-users=false
allow-guest=false
EOF

echo "=== Writing browser launcher loop ==="
cat >/usr/local/bin/kiosk-browser-loop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

URL="$(cat /etc/kiosk-url)"

export DISPLAY=:0

for _ in $(seq 1 30); do
  if xdpyinfo >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

while true; do
  /snap/bin/chromium \
    --kiosk \
    --start-fullscreen \
    --app="$URL" \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-features=Translate,InfiniteSessionRestore \
    --overscroll-history-navigation=0 \
    --incognito \
    --touch-events=enabled

  sleep 2
done
EOF
chmod 755 /usr/local/bin/kiosk-browser-loop.sh

echo "=== Writing x11vnc launcher ==="
cat >/usr/local/bin/kiosk-x11vnc-launcher.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:0

for _ in $(seq 1 60); do
  if xdpyinfo -display :0 >/dev/null 2>&1; then
    exec /usr/bin/x11vnc \
      -display :0 \
      -auth guess \
      -forever \
      -loop \
      -noxdamage \
      -repeat \
      -shared \
      -rfbauth /etc/x11vnc/passwd \
      -rfbport 5900
  fi
  sleep 2
done

echo "x11vnc could not find an active X11 display on :0" >&2
exit 1
EOF
chmod 755 /usr/local/bin/kiosk-x11vnc-launcher.sh

echo "=== Writing Openbox autostart ==="
cat >"/home/$KIOSK_USER/.config/openbox/autostart" <<'EOF'
#!/usr/bin/env bash

export DISPLAY=:0

# Disable blanking and power saving
xset s off
xset -dpms
xset s noblank

# Hide mouse cursor after short idle
unclutter --timeout 0.5 --jitter 5 --ignore-scrolling &

# Start Chromium in restart loop
/usr/local/bin/kiosk-browser-loop.sh &
EOF

chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.config/openbox/autostart"
chmod 755 "/home/$KIOSK_USER/.config/openbox/autostart"

echo "=== Writing Xorg kiosk restrictions ==="
mkdir -p /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/10-kiosk.conf <<'EOF'
Section "ServerFlags"
    Option "DontZap" "true"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF

echo "=== Writing x11vnc systemd service ==="
cat >/etc/systemd/system/x11vnc.service <<'EOF'
[Unit]
Description=Start x11vnc for the kiosk display
After=display-manager.service systemd-user-sessions.service
Requires=display-manager.service

[Service]
Type=simple
ExecStartPre=/usr/bin/test -f /etc/x11vnc/passwd
ExecStart=/usr/local/bin/kiosk-x11vnc-launcher.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

echo "=== Ensuring kiosk user owns its home directory ==="
chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER"

echo "=== Setting system to boot to graphical target ==="
systemctl set-default graphical.target

echo "=== Selecting LightDM as default display manager ==="
if command -v debconf-set-selections >/dev/null 2>&1; then
  echo "lightdm shared/default-x-display-manager select /usr/sbin/lightdm" | debconf-set-selections
  echo "lightdm lightdm/default-display-manager select /usr/sbin/lightdm" | debconf-set-selections
fi
echo '/usr/sbin/lightdm' >/etc/X11/default-display-manager
dpkg-reconfigure -f noninteractive lightdm

echo "=== Ensuring display-manager.service points to LightDM ==="
if [[ -f /lib/systemd/system/lightdm.service ]]; then
  ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
elif [[ -f /usr/lib/systemd/system/lightdm.service ]]; then
  ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
else
  echo "Could not find lightdm.service unit file"
  exit 1
fi

echo "=== Disabling conflicting display managers ==="
if systemctl list-unit-files gdm.service >/dev/null 2>&1; then
  systemctl disable gdm.service || true
fi
if systemctl list-unit-files gdm3.service >/dev/null 2>&1; then
  systemctl disable gdm3.service || true
fi

echo "=== Enabling LightDM ==="
systemctl unmask lightdm.service || true
systemctl enable lightdm.service

echo "=== Reloading systemd ==="
systemctl daemon-reload

echo "=== Enabling x11vnc service ==="
systemctl enable x11vnc.service

echo "=== Running post-install self-check ==="
if [[ "$(systemctl get-default)" != "graphical.target" ]]; then
  echo "Expected graphical.target to be the default boot target"
  exit 1
fi

if [[ ! -f /etc/X11/default-display-manager ]] || ! grep -qx '/usr/sbin/lightdm' /etc/X11/default-display-manager; then
  echo "LightDM is not configured as the default display manager"
  exit 1
fi

if [[ ! -L /etc/systemd/system/display-manager.service ]]; then
  echo "display-manager.service is not a symlink"
  exit 1
fi

if [[ "$(readlink -f /etc/systemd/system/display-manager.service)" != *"/lightdm.service" ]]; then
  echo "display-manager.service does not point to LightDM"
  exit 1
fi

systemctl is-enabled lightdm.service >/dev/null
systemctl is-enabled x11vnc.service >/dev/null

if systemctl is-active --quiet lightdm.service; then
  echo "LightDM is active; verifying x11vnc runtime state"
  systemctl restart x11vnc.service

  for _ in $(seq 1 15); do
    if systemctl is-active --quiet x11vnc.service && ss -ltn '( sport = :5900 )' | grep -q ':5900'; then
      break
    fi
    sleep 2
  done

  if ! systemctl is-active --quiet x11vnc.service; then
    echo "x11vnc service failed to stay active"
    systemctl status x11vnc.service --no-pager || true
    exit 1
  fi

  if ! ss -ltn '( sport = :5900 )' | grep -q ':5900'; then
    echo "x11vnc is not listening on TCP port 5900"
    systemctl status x11vnc.service --no-pager || true
    exit 1
  fi
else
  echo "LightDM is not active yet; runtime x11vnc port check will occur after reboot"
fi

echo "=== Final checks ==="
echo "Default target: $(systemctl get-default)"
echo "Default display manager file:"
cat /etc/X11/default-display-manager || true
echo "display-manager.service ->"
ls -l /etc/systemd/system/display-manager.service || true
echo "Enabled services:"
systemctl is-enabled lightdm.service || true
systemctl is-enabled x11vnc.service || true

echo
echo "Setup complete."
echo "Kiosk URL: $KIOSK_URL"
echo "Kiosk user: $KIOSK_USER"
echo
echo "Rebooting in 10 seconds..."
sleep 10
reboot