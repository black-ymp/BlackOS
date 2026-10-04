#!/usr/bin/env bash
# BlackOS build script (Debian live-build) - single edition, 1GB RAM target
# Usage: sudo ./build-blackos.sh
# Host: a Debian/Ubuntu machine with:  sudo apt install live-build
# Output: ./build/live-image-<arch>.hybrid.iso
#
# Keep blackos-wallpaper.png in the same folder as this script.
#
# Options (environment variables, use sudo -E):
#   SUITE=trixie|bookworm      Debian release           (default: trixie)
#   ARCH=amd64|i386            CPU architecture         (default: amd64)
#   INSTALLER=live|none        include the disk installer (default: live)
#
# 32-bit potato PCs: Debian trixie dropped i386, so use
#   SUITE=bookworm ARCH=i386 sudo -E ./build-blackos.sh
#
# Persistence (keep files between reboots without installing): boot the live
# USB with the "persistence" boot parameter and add a partition labelled
# "persistence" containing a file named persistence.conf with "/ union".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER="$SCRIPT_DIR/blackos-wallpaper.png"
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
INSTALLER="${INSTALLER:-live}"
BUILD="build"
CACHE="$PWD/.lb-cache/${SUITE}-${ARCH}"

[[ "$INSTALLER" =~ ^(live|none)$ ]] || { echo "INSTALLER must be live or none"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }
if [[ ! -f "$WALLPAPER" ]]; then
  echo "WARNING: $WALLPAPER not found, the desktop will be plain black."
fi
if [[ "$ARCH" == "i386" && "$INSTALLER" == "live" ]]; then
  echo "NOTE: Debian's i386 installer kernel may require PAE. For non-PAE CPUs"
  echo "      use INSTALLER=none and run the live image from USB instead."
fi

# Clean previous build SAFELY. A failed build can leave /dev, /proc, /sys
# bind-mounted inside the chroot, and rm -rf through those would hit the host.
if [[ -d "$BUILD" ]]; then
  ( cd "$BUILD" && lb clean ) >/dev/null 2>&1 || true
  if grep -qs " $PWD/$BUILD/" /proc/mounts; then
    echo "Mounts are still active under $PWD/$BUILD. Unmount them or reboot,"
    echo "then run this script again. (Refusing to delete.)"
    exit 1
  fi
fi

# Keep downloaded packages between builds (per suite + arch)
mkdir -p "$CACHE"
rm -rf "$BUILD" && mkdir -p "$BUILD"
ln -s "$CACHE" "$BUILD/cache"
cd "$BUILD"

# Extra lb config arguments
LB_EXTRA=()
if [[ "$INSTALLER" == "live" ]]; then
  LB_EXTRA+=(--debian-installer live --debian-installer-gui false)
else
  LB_EXTRA+=(--debian-installer none)
fi
# Debian's default i386 kernel is 686-pae, which won't boot on pre-PAE CPUs
if [[ "$ARCH" == "i386" ]]; then
  LB_EXTRA+=(--linux-flavours 686)
fi

# polkit package name changed between releases
case "$SUITE" in
  bullseye|bookworm) POLKIT=policykit-1 ;;
  *)                 POLKIT=polkitd ;;
esac

# ------------------------------------------------------------------ 1. CORE
lb config \
  --distribution "$SUITE" \
  --architectures "$ARCH" \
  --archive-areas "main non-free-firmware" \
  --apt-recommends false \
  --binary-images iso-hybrid \
  --memtest none \
  --iso-application "BlackOS" \
  --iso-volume "BlackOS" \
  --bootappend-live "boot=live components quiet loglevel=3 nowatchdog zswap.enabled=0 vt.global_cursor_default=0" \
  "${LB_EXTRA[@]}"
# Add "mitigations=off" to the line above for extra speed on very old CPUs.
# It is a real security trade-off, so it is left out by default.

CFG=config
SKEL=$CFG/includes.chroot/etc/skel
mkdir -p $CFG/package-lists $CFG/hooks/live \
         $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml \
         $SKEL/.config/gtk-3.0 $SKEL/.config/autostart \
         $CFG/includes.chroot/etc/sysctl.d \
         $CFG/includes.chroot/etc/systemd \
         $CFG/includes.chroot/etc/lightdm/lightdm.conf.d \
         $CFG/includes.chroot/usr/local/bin \
         $CFG/includes.chroot/usr/share/applications \
         $CFG/includes.chroot/usr/share/backgrounds

# ------------------------------------------------------------ 2. PACKAGES
# --apt-recommends is false, so anything that is only "Recommended" must be
# listed here explicitly (WPA Wi-Fi, USB mounting, audio, sessions...).
cat > $CFG/package-lists/blackos-base.list.chroot <<'EOF'
# kernel + live boot
live-boot
live-config
live-config-systemd
systemd-sysv
dbus-user-session
dbus-x11
libpam-systemd
# minimal X + drivers. The built-in "modesetting" driver covers Intel and
# modern AMD, so only the legacy/fallback drivers are listed.
xserver-xorg-core
xserver-xorg-input-libinput
xserver-xorg-video-fbdev
xserver-xorg-video-vesa
xserver-xorg-video-radeon
xserver-xorg-video-nouveau
x11-xserver-utils
mesa-utils
libgl1-mesa-dri
# XFCE (cherry-picked, no xfdesktop = saves RAM)
xfce4-session
xfce4-panel
xfwm4
xfce4-settings
xfconf
xfce4-whiskermenu-plugin
xfce4-pulseaudio-plugin
xfce4-terminal
lightdm
lightdm-gtk-greeter
# wallpaper setter (tiny, no daemon, replaces xfdesktop)
feh
# theme + fonts
gnome-themes-extra-data
adwaita-icon-theme
fonts-dejavu-core
# utilities
lxtask
pcmanfm
mousepad
xdg-utils
xdg-user-dirs
# removable drives + auth prompts (pcmanfm needs these to mount USB sticks)
udisks2
gvfs
lxpolkit
# networking (wpasupplicant is only a Recommends of network-manager)
network-manager
network-manager-gnome
wpasupplicant
# audio
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
alsa-utils
pavucontrol
# memory tuning (zram swap via systemd, config in /etc/systemd/zram-generator.conf)
systemd-zram-generator
# firmware for old Wi-Fi/GPU
firmware-linux-free
firmware-misc-nonfree
firmware-amd-graphics
firmware-realtek
firmware-atheros
firmware-iwlwifi
EOF
echo "$POLKIT" >> $CFG/package-lists/blackos-base.list.chroot

# ------------------------------------------- 3. SYSTEM TUNING (RAM / ZRAM)
cat > $CFG/includes.chroot/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF

cat > $CFG/includes.chroot/etc/sysctl.d/99-blackos.conf <<'EOF'
vm.swappiness=150
vm.page-cluster=0
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
kernel.nmi_watchdog=0
EOF

# kill background daemons and timers
cat > $CFG/hooks/live/0100-trim.hook.chroot <<'EOF'
#!/bin/sh
for s in bluetooth cups cups-browsed avahi-daemon ModemManager \
         apt-daily apt-daily-upgrade man-db fstrim e2scrub_all \
         NetworkManager-wait-online systemd-networkd-wait-online ; do
  systemctl mask "$s.service" 2>/dev/null || true
done
for t in apt-daily.timer apt-daily-upgrade.timer man-db.timer \
         fstrim.timer e2scrub_all.timer ; do
  systemctl mask "$t" 2>/dev/null || true
done
EOF
chmod +x $CFG/hooks/live/0100-trim.hook.chroot

# autologin (live user is "user")
cat > $CFG/includes.chroot/etc/lightdm/lightdm.conf.d/50-blackos.conf <<'EOF'
[Seat:*]
autologin-user=user
autologin-session=xfce
EOF

# ------------------------------------------------------- 4. XFCE: DARK + WIN
# GTK dark, pitch-black overrides (GTK3 apps; GTK4/libadwaita apps ignore this)
cat > $SKEL/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
EOF

cat > $SKEL/.config/gtk-3.0/gtk.css <<'EOF'
/* BlackOS: force true black surfaces */
window, .background, dialog, menu, menuitem, popover, .view, textview text, entry {
  background-color: #000000;
  color: #e6e6e6;
}
headerbar, toolbar, .titlebar, .sidebar { background-color: #0a0a0a; }
selection, *:selected { background-color: #2b2b2b; color: #ffffff; }
EOF

cat > $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
EOF

cat > $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="button_layout" type="string" value="|HMC"/>
    <property name="title_alignment" type="string" value="left"/>
  </property>
</channel>
EOF

# Windows-style bottom panel: Start | taskbar | tray | volume | clock
cat > $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="length" type="uint" value="100"/>
      <property name="size" type="uint" value="34"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0"/>
        <value type="double" value="0"/>
        <value type="double" value="0"/>
        <value type="double" value="1"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="grouping" type="uint" value="0"/>
      <property name="show-labels" type="bool" value="true"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="pulseaudio"/>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="%I:%M %p"/>
    </property>
  </property>
</channel>
EOF

# Wallpaper without running xfdesktop. The photo is portrait, so it is scaled
# to fit the screen height on a black background (its edges are near-black, so
# the side bars blend in). Change --bg-max to --bg-fill to fill the screen
# instead (crops the top and bottom on landscape monitors).
if [[ -f "$WALLPAPER" ]]; then
  cp "$WALLPAPER" $CFG/includes.chroot/usr/share/backgrounds/blackos.png
  cat > $SKEL/.config/autostart/blackbg.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=BlackOS wallpaper
Exec=feh --no-fehbg --image-bg black --bg-max /usr/share/backgrounds/blackos.png
EOF
else
  cat > $SKEL/.config/autostart/blackbg.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Black background
Exec=xsetroot -solid black
EOF
fi

# ------------------------------------------------- 5. FILE MANAGER: "my bud"
# Phase 1: PCManFM (GTK, ~tiny, no daemons) branded and set as the default.
# Phase 2: swap the Exec line for your own native build (see README notes).
cat > $CFG/includes.chroot/usr/local/bin/mybud <<'EOF'
#!/bin/sh
# my bud - BlackOS file explorer launcher
exec pcmanfm "$@"
EOF
chmod +x $CFG/includes.chroot/usr/local/bin/mybud

cat > $CFG/includes.chroot/usr/share/applications/mybud.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=my bud
GenericName=File Explorer
Comment=BlackOS file explorer
Exec=mybud %U
Icon=system-file-manager
Terminal=false
Categories=System;FileTools;FileManager;
MimeType=inode/directory;
EOF

cat > $SKEL/.config/mimeapps.list <<'EOF'
[Default Applications]
inode/directory=mybud.desktop
EOF

# ------------------------------------------------------------------ 6. BUILD
lb build 2>&1 | tee build.log
echo
echo "Done: $(ls -1 *.iso 2>/dev/null || echo 'check build.log for errors')"
