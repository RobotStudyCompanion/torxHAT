#!/usr/bin/env bash
# =============================================================================
# RSC (Robotic Study Companion) — Shiny node setup
# Tested on: Debian GNU/Linux 13 (Trixie), Raspberry Pi 4, Python 3.13
# Run as: bash setup.sh
# =============================================================================

set -euo pipefail

RSC_USER="${SUDO_USER:-$(whoami)}"
HOME_DIR="/home/${RSC_USER}"
VENV_DIR="${HOME_DIR}/rsc-env"
PIGPIO_DIR="${HOME_DIR}/pigpio"

info()    { echo -e "\n\033[1;34m[RSC]\033[0m $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# -----------------------------------------------------------------------------
# 0. Must run as root
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo bash setup.sh"
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. System packages
# -----------------------------------------------------------------------------
info "Updating package lists..."
apt-get update -qq

info "Installing system packages..."
apt-get install -y \
    git \
    python3-venv \
    python3-dev \
    python3-lgpio \
    build-essential \
    gcc \
    make \
    i2c-tools \
    libi2c-dev \
    libssl-dev \
    syncthing

success "System packages installed."

# -----------------------------------------------------------------------------
# 2. pigpio — build from source (not in Trixie repos)
# -----------------------------------------------------------------------------
if command -v pigpiod &>/dev/null; then
    success "pigpiod already installed — skipping build."
else
    info "Building pigpio from source..."
    sudo -u "${RSC_USER}" git clone https://github.com/joan2937/pigpio.git "${PIGPIO_DIR}" || {
        warn "pigpio dir already exists — pulling latest..."
        git -C "${PIGPIO_DIR}" pull
    }
    make -C "${PIGPIO_DIR}"
    make -C "${PIGPIO_DIR}" install
    ldconfig
    success "pigpio built and installed."
fi

# -----------------------------------------------------------------------------
# 3. pigpiod systemd service — start on boot
# -----------------------------------------------------------------------------
info "Configuring pigpiod systemd service..."
cat > /etc/systemd/system/pigpiod.service << 'EOF'
[Unit]
Description=Pigpio daemon
After=network.target

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
systemctl start pigpiod
success "pigpiod enabled and started."

# -----------------------------------------------------------------------------
# 4. /dev/mem access for NeoPixel (rpi_ws281x needs root or mem group)
# -----------------------------------------------------------------------------
info "Configuring /dev/mem access for NeoPixel..."
# Add rsc user to gpio and kmem groups
usermod -aG gpio,kmem "${RSC_USER}"

# Allow sudo python without password for rsc-env python only
SUDOERS_FILE="/etc/sudoers.d/rsc-neopixel"
cat > "${SUDOERS_FILE}" << EOF
# Allow ${RSC_USER} to run rsc-env python with sudo without password
${RSC_USER} ALL=(ALL) NOPASSWD: ${VENV_DIR}/bin/python3
EOF
chmod 440 "${SUDOERS_FILE}"
success "/dev/mem access configured."

# -----------------------------------------------------------------------------
# 5. Python venv
# -----------------------------------------------------------------------------
info "Creating Python venv at ${VENV_DIR}..."
if [[ ! -d "${VENV_DIR}" ]]; then
    sudo -u "${RSC_USER}" python3 -m venv "${VENV_DIR}" --system-site-packages
    success "venv created."
else
    warn "venv already exists — skipping creation."
fi

# -----------------------------------------------------------------------------
# 6. Python packages inside venv
# -----------------------------------------------------------------------------
info "Installing Python packages into venv..."
sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip --quiet

# pigpio Python bindings (C library already installed above)
sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install pigpio --quiet

# Adafruit NeoPixel / Blinka stack
sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install \
    adafruit-circuitpython-neopixel \
    adafruit-blinka \
    rpi_ws281x \
    gpiozero \
    RPi.GPIO \
    --quiet

# Install from requirements.txt if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
    info "Installing from requirements.txt..."
    sudo -u "${RSC_USER}" "${VENV_DIR}/bin/pip" install \
        -r "${SCRIPT_DIR}/requirements.txt" --quiet
    success "requirements.txt installed."
else
    warn "No requirements.txt found — skipping."
fi

success "Python packages installed."

# -----------------------------------------------------------------------------
# 7. Enable I2C and SPI via raspi-config (non-interactive)
# -----------------------------------------------------------------------------
info "Enabling I2C and SPI interfaces..."
raspi-config nonint do_i2c 0  || warn "raspi-config I2C failed — enable manually"
raspi-config nonint do_spi 0  || warn "raspi-config SPI failed — enable manually"
success "I2C and SPI enabled."

# -----------------------------------------------------------------------------
# 8. Syncthing — enable as user service
# -----------------------------------------------------------------------------
info "Enabling Syncthing for ${RSC_USER}..."
sudo -u "${RSC_USER}" systemctl --user enable syncthing || \
    warn "Syncthing user service failed — may need loginctl enable-linger"
loginctl enable-linger "${RSC_USER}"
sudo -u "${RSC_USER}" systemctl --user start syncthing || \
    warn "Syncthing start failed — check: systemctl --user status syncthing"
success "Syncthing enabled."

# -----------------------------------------------------------------------------
# 9. pigpiod boot persistence check
# -----------------------------------------------------------------------------
info "Verifying pigpiod..."
sleep 1
if pigs t &>/dev/null; then
    success "pigpiod is running (tick: $(pigs t))."
else
    warn "pigpiod not responding — try: sudo systemctl start pigpiod"
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  RSC setup complete."
echo ""
echo "  Run scripts with:"
echo "  sudo ${VENV_DIR}/bin/python3 button_test.py <behaviour>"
echo ""
echo "  Behaviours: solid | brightness | tap_hold | ring | sweep"
echo "              servo_hold | servo_cycle | servo_dir"
echo ""
echo "  Syncthing UI: http://localhost:8384"
echo "  (pair with dev laptop to sync RSC stack)"
echo ""
echo "  Reboot recommended to apply group changes."
echo "============================================================"