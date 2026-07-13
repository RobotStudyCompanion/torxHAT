#!/usr/bin/env bash
# =============================================================================
# RSC (Robotic Study Companion) — Shiny node provisioning
# Tested on: Debian GNU/Linux 13 (Trixie), Raspberry Pi 4, Python 3.13
#
# Usage (standalone):
#   chmod +x setup.sh && sudo bash setup.sh
#
# Idempotent — safe to re-run on an already-provisioned node.
#
# What this configures end-to-end:
#   • System:   full upgrade, base tools (git, micro, btop, mc, tmux, gcc...)
#   • Editor:   micro set as default system-wide
#   • Time:     chrony NTP + interactive timezone prompt
#   • I2C/SPI/UART: enabled via raspi-config
#   • Groups:   rsc user added to gpio, i2c, dialout, kmem, spi
#   • pigpio:   built from source (not in Trixie repos), pigpiod systemd service
#   • NeoPixel: passwordless sudo for venv python (rpi_ws281x /dev/mem access)
#   • venv:     ~/rsc-env with full Adafruit/pigpio/gpiozero stack
#   • Ollama:   ARM64 install, low-RAM systemd override, starter models
#   • Syncthing: official repo install, enabled as system service
#   • Smoke:    pigpiod, I2C scan, Ollama ping
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${HOME:-/root}/rsc_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== RSC setup.sh started at $(date -Iseconds) on $(hostname) ==="

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[1;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
info()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()    { echo -e "${RED}[fail]${NC} $*"; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash setup.sh"
[[ "$(uname -m)" == "aarch64" ]] || warn "Not aarch64 — some steps may behave unexpectedly."

RSC_USER="${SUDO_USER:-rsc}"
HOME_DIR="/home/${RSC_USER}"
VENV_DIR="${HOME_DIR}/rsc-env"
PIGPIO_DIR="${HOME_DIR}/pigpio"

log "RSC_USER=${RSC_USER}  HOME=${HOME_DIR}  VENV=${VENV_DIR}"

AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -d 'G ')
log "Free space on /: ${AVAIL_GB}GB"
[[ "$AVAIL_GB" -ge 6 ]] || fail "Less than 6GB free — clear space before running."

log "Checking network..."
curl -fsS --max-time 5 https://deb.debian.org/ >/dev/null || fail "Cannot reach Debian apt mirror."

PI_MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown")
log "Board: ${PI_MODEL}"

# ── Timezone ──────────────────────────────────────────────────────────────────
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
log "Current timezone: ${CURRENT_TZ}"
read -rp "  Set timezone [${CURRENT_TZ}]: " INPUT_TZ
DESIRED_TZ="${INPUT_TZ:-$CURRENT_TZ}"
if [[ "$DESIRED_TZ" != "$CURRENT_TZ" ]]; then
    timedatectl set-timezone "$DESIRED_TZ" || warn "Failed to set timezone to ${DESIRED_TZ}"
    log "Timezone set to ${DESIRED_TZ} ✓"
else
    log "Timezone unchanged: ${CURRENT_TZ} ✓"
fi

# ── System update & base packages ─────────────────────────────────────────────
info "Updating apt and installing base packages (slow step)..."
apt-get update -qq
apt-get full-upgrade -y

apt-get install -y \
    git \
    curl \
    wget \
    micro \
    mc \
    tmux \
    htop \
    btop \
    jq \
    gcc \
    make \
    build-essential \
    python3-venv \
    python3-dev \
    python3-pip \
    python3-lgpio \
    python3-smbus \
    i2c-tools \
    libi2c-dev \
    libssl-dev \
    chrony \
    zram-tools \
    util-linux-extra

log "Base packages installed ✓"

# ── Micro as default editor ───────────────────────────────────────────────────
info "Setting micro as default editor..."
update-alternatives --install /usr/bin/editor editor /usr/bin/micro 100 2>/dev/null || true
update-alternatives --set editor /usr/bin/micro 2>/dev/null || true
BASHRC="${HOME_DIR}/.bashrc"
if ! grep -q "EDITOR=micro" "$BASHRC" 2>/dev/null; then
    {
        echo ''
        echo '# Default editor (RSC setup)'
        echo 'export EDITOR=micro'
        echo 'export VISUAL=micro'
        echo 'export SUDO_EDITOR=micro'
    } >> "$BASHRC"
fi
log "micro set as default editor ✓"

# ── Chrony NTP ────────────────────────────────────────────────────────────────
info "Configuring NTP..."
systemctl disable --now systemd-timesyncd 2>/dev/null || true
systemctl enable --now chrony
timedatectl set-ntp true
sleep 2
chronyc tracking || warn "chrony not yet synced — will catch up on next poll."
mkdir -p /var/log/journal
systemctl restart systemd-journald
log "chrony NTP configured ✓"

# ── ZRAM swap ─────────────────────────────────────────────────────────────────
info "Configuring ZRAM swap..."
tee /etc/default/zramswap >/dev/null <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
modprobe zram 2>/dev/null || warn "zram kernel module not loadable."
systemctl enable --now zramswap 2>/dev/null || warn "zramswap service not available — may need reboot."
log "ZRAM swap configured ✓"

# ── User groups ───────────────────────────────────────────────────────────────
info "Adding ${RSC_USER} to hardware groups..."
for grp in gpio i2c dialout kmem spi; do
    if getent group "$grp" >/dev/null; then
        usermod -aG "$grp" "${RSC_USER}"
        log "  added to ${grp}"
    else
        warn "  group ${grp} does not exist — skipping"
    fi
done

# ── raspi-config: I2C, SPI, UART ─────────────────────────────────────────────
info "Enabling interfaces via raspi-config..."
raspi-config nonint do_i2c 0   || warn "raspi-config I2C failed — enable manually"
raspi-config nonint do_spi 0   || warn "raspi-config SPI failed — enable manually"
raspi-config nonint do_serial_hw 0 || warn "raspi-config UART failed — enable manually"
raspi-config nonint do_serial_cons 1 || true   # disable serial console, keep port
if ! grep -q "^i2c-dev" /etc/modules; then
    echo "i2c-dev" >> /etc/modules
fi
modprobe i2c-dev || warn "i2c-dev not loaded — will require reboot."
log "I2C / SPI / UART enabled ✓"

# ── raspi-config: expand filesystem ──────────────────────────────────────────
info "Expanding filesystem..."
raspi-config nonint do_expand_rootfs || warn "Filesystem expand failed — may already be full size."
log "Filesystem expand queued (takes effect on reboot) ✓"

# ── pigpio — build from source ────────────────────────────────────────────────
if command -v pigpiod &>/dev/null; then
    log "pigpiod already installed — skipping build."
else
    info "Building pigpio from source (not in Trixie repos)..."
    if [[ -d "${PIGPIO_DIR}" ]]; then
        warn "pigpio dir exists — pulling latest..."
        git -C "${PIGPIO_DIR}" pull
    else
        sudo -u "${RSC_USER}" git clone https://github.com/joan2937/pigpio.git "${PIGPIO_DIR}"
    fi
    make -C "${PIGPIO_DIR}"
    make -C "${PIGPIO_DIR}" install
    ldconfig
    log "pigpio built and installed ✓"
fi

# ── pigpiod systemd service ───────────────────────────────────────────────────
info "Configuring pigpiod systemd service..."
tee /etc/systemd/system/pigpiod.service >/dev/null <<'EOF'
[Unit]
Description=Pigpio daemon
After=multi-user.target

[Service]
Type=forking
ExecStart=/usr/local/bin/pigpiod
ExecStop=/bin/systemctl kill pigpiod
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pigpiod
systemctl start pigpiod || warn "pigpiod failed to start — check: journalctl -u pigpiod"
log "pigpiod service enabled ✓"

# ── NeoPixel /dev/mem sudo rule ───────────────────────────────────────────────
info "Configuring passwordless sudo for rsc-env python (NeoPixel /dev/mem)..."
SUDOERS_FILE="/etc/sudoers.d/rsc-neopixel"
cat > "${SUDOERS_FILE}" <<EOF
# Allow ${RSC_USER} to run rsc-env python3 with sudo without password
# Required for rpi_ws281x NeoPixel DMA access via /dev/mem
${RSC_USER} ALL=(ALL) NOPASSWD: ${VENV_DIR}/bin/python3
EOF
chmod 440 "${SUDOERS_FILE}"
visudo -c -f "${SUDOERS_FILE}" || { rm "${SUDOERS_FILE}"; warn "sudoers file invalid — removed."; }
log "NeoPixel sudo rule configured ✓"

# ── Python venv ───────────────────────────────────────────────────────────────
info "Creating Python venv at ${VENV_DIR}..."
if [[ ! -d "${VENV_DIR}" ]]; then
    sudo -u "${RSC_USER}" python3 -m venv "${VENV_DIR}" --system-site-packages
    log "venv created ✓"
else
    warn "venv already exists — skipping creation."
fi

# Auto-activate venv in .bashrc
if ! grep -q "rsc-env/bin/activate" "$BASHRC" 2>/dev/null; then
    {
        echo ''
        echo '# Auto-activate RSC venv (RSC setup)'
        echo "source ${VENV_DIR}/bin/activate 2>/dev/null || true"
    } >> "$BASHRC"
fi

# ── Python packages ───────────────────────────────────────────────────────────
info "Installing Python packages into venv..."
sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip --quiet

# Install from requirements.txt if present (locks exact versions)
if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
    info "Installing from requirements.txt..."
    sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install \
        -r "${SCRIPT_DIR}/requirements.txt" --quiet
    log "requirements.txt installed ✓"
else
    warn "No requirements.txt found — installing baseline packages."
    sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install \
        pigpio \
        adafruit-circuitpython-neopixel \
        adafruit-blinka \
        rpi_ws281x \
        gpiozero \
        RPi.GPIO \
        --quiet
fi
log "Python packages installed ✓"

# ── Ollama ────────────────────────────────────────────────────────────────────
info "Installing Ollama (ARM64)..."
OLLAMA_MIN="0.31.1"
if command -v ollama >/dev/null && ollama --version &>/dev/null; then
    OLLAMA_CURRENT=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
    log "Ollama already installed: ${OLLAMA_CURRENT}"
else
    curl -fsSL https://ollama.com/install.sh | sh
    [[ -s "$(which ollama)" ]] || fail "Ollama install failed."
    log "Ollama installed ✓"
fi

# Low-RAM systemd override for Pi 4
OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
mkdir -p "$OVERRIDE_DIR"
tee "${OVERRIDE_DIR}/override.conf" >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF
systemctl daemon-reload
systemctl enable --now ollama
sleep 5
curl -sf http://localhost:11434/api/tags &>/dev/null \
    && log "Ollama API responsive ✓" \
    || warn "Ollama API not yet responding — may need a moment."

info "Pulling starter models (this will take a while on first run)..."
sudo -u "${RSC_USER}" ollama pull qwen3:0.6b  || warn "qwen3:0.6b pull failed."
sudo -u "${RSC_USER}" ollama pull llama3.2:1b || warn "llama3.2:1b pull failed."
log "Ollama models pulled ✓"

# ── Syncthing — official repo ─────────────────────────────────────────────────
info "Installing Syncthing..."
if ! command -v syncthing >/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL -o /etc/apt/keyrings/syncthing-archive-keyring.gpg \
        https://syncthing.net/release-key.gpg
    echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" \
        | tee /etc/apt/sources.list.d/syncthing.list >/dev/null
    apt-get update -qq
    apt-get install -y syncthing
fi
# Run as system service for the rsc user
systemctl enable --now "syncthing@${RSC_USER}.service" || {
    warn "syncthing@user service failed — trying user service..."
    loginctl enable-linger "${RSC_USER}"
    sudo -u "${RSC_USER}" systemctl --user enable syncthing || true
    sudo -u "${RSC_USER}" systemctl --user start syncthing || true
}
sleep 2
DEVICE_ID=$(sudo -u "${RSC_USER}" syncthing --device-id 2>/dev/null || echo "unknown — run 'syncthing --device-id' after first start")
log "Syncthing installed ✓ — device ID: ${DEVICE_ID}"

# ── I2C scan ──────────────────────────────────────────────────────────────────
info "Scanning I2C bus 1..."
i2cdetect -y 1 || warn "i2cdetect failed — reboot may be required to load i2c-dev."

# ── Smoke test ────────────────────────────────────────────────────────────────
info "Running smoke tests..."
SMOKE_OK=true

sleep 1
if pigs t &>/dev/null; then
    log "[smoke] pigpiod running (tick: $(pigs t)) ✓"
else
    warn "[smoke] pigpiod not responding."
    SMOKE_OK=false
fi

if sudo -u "${RSC_USER}" "${VENV_DIR}/bin/python3" -c "import pigpio, neopixel, board, gpiozero; print('imports ok')" 2>/dev/null; then
    log "[smoke] Python imports OK ✓"
else
    warn "[smoke] Python import check failed."
    SMOKE_OK=false
fi

if echo "ping" | timeout 30 sudo -u "${RSC_USER}" ollama run qwen3:0.6b 2>/dev/null | grep -q .; then
    log "[smoke] Ollama responds ✓"
else
    warn "[smoke] Ollama did not respond within 30s — check: journalctl -u ollama -n 30"
    SMOKE_OK=false
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  RSC node provisioning complete on ${PI_MODEL}"
echo ""
echo "  Smoke test : $([[ "$SMOKE_OK" == true ]] && echo "PASSED ✓" || echo "ISSUES — see warnings above")"
echo "  Models     :"; sudo -u "${RSC_USER}" ollama list 2>/dev/null | sed 's/^/    /' || true
echo "  Disk       :"; df -h / | awk 'NR==1||NR==2' | sed 's/^/    /'
echo "  Syncthing  : ${DEVICE_ID}"
echo "  Pair via   : ssh -L 8384:localhost:8384 ${RSC_USER}@$(hostname).local"
echo ""
echo "  Run scripts with:"
echo "  sudo ${VENV_DIR}/bin/python3 button_test.py <behaviour>"
echo ""
echo "  Behaviours: solid | brightness | tap_hold | ring | sweep"
echo "              servo_hold | servo_cycle | servo_dir"
echo ""
echo "  Next steps:"
echo "    1. exec bash -l          # pick up env + venv changes"
echo "    2. sudo reboot           # if any 'reboot required' warnings above"
echo "    3. tmux new -s rsc       # for long-running sessions"
echo ""
echo "  Log saved to: ${LOG_FILE}"
echo "============================================================"
echo "=== RSC setup.sh finished at $(date -Iseconds) ==="