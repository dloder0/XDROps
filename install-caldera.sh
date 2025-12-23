
#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Logging: everything goes to /var/log/caldera-install.log (and console)
# -----------------------------------------------------------------------------
LOG_FILE="/var/log/caldera-install.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Send stdout+stderr to log file AND console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================================="
echo "[CALDERA] install-caldera.sh starting at $(date -Is)"
echo "============================================================================="

# -----------------------------------------------------------------------------
# Config (edit as needed)
# -----------------------------------------------------------------------------
CALDERA_DIR="/opt/caldera/app"
CALDERA_VERSION="${CALDERA_VERSION:-5.0.0}"   # can be overridden via env var
CALDERA_PORT="${CALDERA_PORT:-8888}"
CALDERA_USER="${CALDERA_USER:-root}"          # simplest for lab use; see note below
BUILD_UI="${BUILD_UI:-false}"                 # true/false
INSECURE_FLAG="--insecure"                    # use "--insecure" (recommended format)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
fail() {
  echo "[CALDERA][ERROR] $*" >&2
  echo "[CALDERA][ERROR] Failed at $(date -Is)" >&2
  exit 1
}

trap 'fail "Script aborted on line $LINENO"' ERR

echo "[CALDERA] Using:"
echo "  CALDERA_VERSION=$CALDERA_VERSION"
echo "  CALDERA_DIR=$CALDERA_DIR"
echo "  CALDERA_PORT=$CALDERA_PORT"
echo "  CALDERA_USER=$CALDERA_USER"
echo "  BUILD_UI=$BUILD_UI"
echo

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
echo "[CALDERA] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git python3 python3-venv python3-pip \
  nodejs npm

# -----------------------------------------------------------------------------
# Create target dir / clone or update CALDERA
# -----------------------------------------------------------------------------
echo "[CALDERA] Preparing directory: $CALDERA_DIR"
mkdir -p "$(dirname "$CALDERA_DIR")"

if [[ ! -d "$CALDERA_DIR/.git" ]]; then
  echo "[CALDERA] Cloning CALDERA into $CALDERA_DIR ..."
  git clone --recursive https://github.com/mitre/caldera.git "$CALDERA_DIR"
else
  echo "[CALDERA] Existing repo found; updating..."
  git -C "$CALDERA_DIR" fetch --all --tags --prune
fi

echo "[CALDERA] Checking out version/tag/branch: $CALDERA_VERSION"
git -C "$CALDERA_DIR" checkout "$CALDERA_VERSION" || \
  git -C "$CALDERA_DIR" checkout "tags/$CALDERA_VERSION" || \
  fail "Could not checkout CALDERA_VERSION=$CALDERA_VERSION"

# ensure submodules are correct for that version
git -C "$CALDERA_DIR" submodule update --init --recursive

# -----------------------------------------------------------------------------
# Python venv + deps
# -----------------------------------------------------------------------------
echo "[CALDERA] Setting up Python virtual environment..."
if [[ ! -d "$CALDERA_DIR/venv" ]]; then
  python3 -m venv "$CALDERA_DIR/venv"
fi

# shellcheck disable=SC1091
source "$CALDERA_DIR/venv/bin/activate"

echo "[CALDERA] Upgrading pip/setuptools/wheel..."
pip install --upgrade pip setuptools wheel

echo "[CALDERA] Installing CALDERA Python requirements..."
pip install -r "$CALDERA_DIR/requirements.txt"

# -----------------------------------------------------------------------------
# Optional UI build (best-effort; CALDERA can also build on first run)
# -----------------------------------------------------------------------------
if [[ "$BUILD_UI" == "true" ]]; then
  echo "[CALDERA] Attempting UI build (best effort)..."
  # The build flag may vary slightly by version; if it fails, we log it and continue.
  set +e
  timeout 600 python3 "$CALDERA_DIR/server.py" $INSECURE_FLAG --build
  BUILD_RC=$?
  set -e
  if [[ $BUILD_RC -ne 0 ]]; then
    echo "[CALDERA][WARN] UI build returned code $BUILD_RC (continuing)."
  else
    echo "[CALDERA] UI build completed."
  fi
fi

# -----------------------------------------------------------------------------
# systemd service
# -----------------------------------------------------------------------------
echo "[CALDERA] Creating systemd service: /etc/systemd/system/caldera.service"

cat > /etc/systemd/system/caldera.service <<EOF
[Unit]
Description=MITRE CALDERA Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$CALDERA_DIR
ExecStart=$CALDERA_DIR/venv/bin/python3 $CALDERA_DIR/server.py $INSECURE_FLAG --port $CALDERA_PORT
Restart=always
RestartSec=5
User=$CALDERA_USER

# Logging (journald + also your installer log is separate)
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[CALDERA] Reloading systemd + enabling service..."
systemctl daemon-reload
systemctl enable caldera

echo "[CALDERA] Starting service..."
systemctl restart caldera

echo "[CALDERA] Service status:"
systemctl --no-pager --full status caldera || true

echo "============================================================================="
echo "[CALDERA] install-caldera.sh completed at $(date -Is)"
echo "Log file: $LOG_FILE"
echo "To view service logs: journalctl -u caldera -n 200 --no-pager"
echo "============================================================================="
