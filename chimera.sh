#!/usr/bin/env bash
# =============================================================================
# chimera-rice installer
# minimal & clean bspwm setup for Chimera Linux
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dotfiles"
WALLPAPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wallpapers"
LOG="$HOME/.chimera-rice-install.log"
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"

# ── colours ──────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

log()  { printf "${G}[+]${N} %s\n" "$*" | tee -a "$LOG"; }
warn() { printf "${Y}[!]${N} %s\n" "$*" | tee -a "$LOG"; }
die()  { printf "${R}[x]${N} %s\n" "$*" | tee -a "$LOG"; exit 1; }
step() { printf "\n${C}══${W} %s ${C}══${N}\n" "$*" | tee -a "$LOG"; }

# ── privilege ────────────────────────────────────────────────────────────────
if   [ "$(id -u)" -eq 0 ];                  then AS_ROOT=()
elif command -v doas &>/dev/null;            then AS_ROOT=(doas)
elif command -v sudo &>/dev/null;            then AS_ROOT=(sudo)
else die "run as root, or install doas/sudo"; fi

root() { "${AS_ROOT[@]+"${AS_ROOT[@]}"}" "$@"; }

# ── apk helpers ──────────────────────────────────────────────────────────────
APK_TIMEOUT=180
APK_NET=30

apk_add() {
  root timeout "$APK_TIMEOUT" apk \
    --interactive=no --progress=no --timeout="$APK_NET" \
    add "$@"
}

try_apk() {
  local pkg
  for pkg in "$@"; do
    apk_add "$pkg" && return 0 || warn "optional pkg not found: $pkg"
  done
  return 0
}

# ── backup existing config ────────────────────────────────────────────────────
backup_existing() {
  step "backing up existing configs"
  local dirs=(bspwm sxhkd polybar rofi alacritty picom dunst)
  local d
  mkdir -p "$BACKUP_DIR"
  for d in "${dirs[@]}"; do
    [ -d "$HOME/.config/$d" ] && {
      cp -r "$HOME/.config/$d" "$BACKUP_DIR/$d"
      log "backed up ~/.config/$d"
    }
  done
  [ -f "$HOME/.xsession" ] && cp "$HOME/.xsession" "$BACKUP_DIR/.xsession"
}

# ── install packages ──────────────────────────────────────────────────────────
install_packages() {
  step "updating apk"
  root timeout "$APK_TIMEOUT" apk \
    --interactive=no --progress=no --timeout="$APK_NET" update \
    || die "apk update failed"

  step "installing core packages"
  apk_add \
    xserver-xorg \
    xorg-xinit \
    dbus \
    elogind \
    seatd \
    || die "core X11 packages failed"

  step "installing WM and compositor"
  apk_add bspwm sxhkd picom \
    || die "bspwm/sxhkd/picom failed"

  step "installing bar, launcher, notifications"
  apk_add polybar rofi dunst \
    || die "polybar/rofi/dunst failed"

  step "installing terminal"
  apk_add alacritty \
    || apk_add foot \
    || apk_add xterm \
    || warn "no preferred terminal found; install one manually"

  step "installing fonts"
  apk_add \
    font-jetbrains-mono-nerd \
    font-noto \
    font-noto-emoji \
    || true
  try_apk fonts-nerd ttf-jetbrains-mono nerd-fonts-jetbrains-mono

  step "installing lockscreen and wallpaper tools"
  try_apk i3lock betterlockscreen
  apk_add feh || try_apk nitrogen

  step "installing file manager and extras"
  try_apk thunar pcmanfm lf ranger
  try_apk maim xdotool xclip xsel
  try_apk playerctl brightnessctl pamixer
  try_apk network-manager-applet nm-applet

  log "packages done"
}

# ── deploy dotfiles ───────────────────────────────────────────────────────────
deploy() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp -r "$src" "$dest"
  log "deployed: $dest"
}

install_dotfiles() {
  step "installing dotfiles"
  mkdir -p "$HOME/.config"

  deploy "$DOTFILES_DIR/bspwm"    "$HOME/.config/bspwm"
  deploy "$DOTFILES_DIR/sxhkd"   "$HOME/.config/sxhkd"
  deploy "$DOTFILES_DIR/polybar" "$HOME/.config/polybar"
  deploy "$DOTFILES_DIR/rofi"    "$HOME/.config/rofi"
  deploy "$DOTFILES_DIR/alacritty" "$HOME/.config/alacritty"
  deploy "$DOTFILES_DIR/picom"   "$HOME/.config/picom"
  deploy "$DOTFILES_DIR/dunst"   "$HOME/.config/dunst"

  chmod +x "$HOME/.config/bspwm/bspwmrc"
  chmod +x "$HOME/.config/polybar/launch.sh"

  # wallpaper
  mkdir -p "$HOME/.local/share/wallpapers"
  cp "$WALLPAPER_DIR/"* "$HOME/.local/share/wallpapers/" 2>/dev/null || true

  # .xsession
  cat > "$HOME/.xsession" <<'EOF'
#!/bin/sh
# chimera-rice xsession
export XDG_SESSION_TYPE=x11
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

# dbus
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi

# seatd / elogind
[ -r /run/seatd.sock ] && export LIBSEAT_BACKEND=seatd

# system tray polkit agent (optional)
if command -v lxpolkit >/dev/null 2>&1; then
  lxpolkit &
elif command -v polkit-gnome-authentication-agent-1 >/dev/null 2>&1; then
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
fi

# notifications
dunst &

exec bspwm
EOF
  chmod +x "$HOME/.xsession"
  log ".xsession written"
}

# ── enable services ───────────────────────────────────────────────────────────
enable_services() {
  step "enabling dinit services"
  for svc in dbus elogind seatd; do
    root dinitctl enable "$svc" 2>/dev/null && log "enabled: $svc" \
      || warn "could not enable $svc (may already be enabled)"
  done
}

# ── done ──────────────────────────────────────────────────────────────────────
print_done() {
  printf "\n"
  printf "${G}╔══════════════════════════════════════════╗${N}\n"
  printf "${G}║   chimera-rice installed successfully    ║${N}\n"
  printf "${G}╚══════════════════════════════════════════╝${N}\n"
  printf "\n"
  printf "  ${W}start X:${N}       startx\n"
  printf "  ${W}or via DM:${N}     doas dinitctl start xdm\n"
  printf "  ${W}super+enter${N}    terminal\n"
  printf "  ${W}super+d${N}        launcher (rofi)\n"
  printf "  ${W}super+q${N}        close window\n"
  printf "  ${W}backup at:${N}     $BACKUP_DIR\n"
  printf "  ${W}log at:${N}        $LOG\n\n"
}

main() {
  exec > >(tee -a "$LOG") 2>&1
  printf "${C}chimera-rice installer${N}\n"
  printf "log: $LOG\n\n"

  backup_existing
  install_packages
  install_dotfiles
  enable_services
  print_done
}

main "$@"
