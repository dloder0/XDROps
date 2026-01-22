
#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Logging: everything goes to /var/log/caldera-install.log (and console)
# -----------------------------------------------------------------------------
LOG_FILE="/var/log/install.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

# Send stdout+stderr to log file AND console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================================="
echo "install-caldera.sh starting at $(date -Is)"
echo "============================================================================="


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
fail() {
  echo "[CALDERA][ERROR] $*" >&2
  echo "[CALDERA][ERROR] Failed at $(date -Is)" >&2
  exit 1
}

trap 'fail "Script aborted on line $LINENO"' ERR

curl -sSL -O https://packages.microsoft.com/config/ubuntu/25.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
apt update && apt upgrade -y
apt-get install pip -y
apt install apt-transport-https ca-certificates curl gnupg lsb-release -y
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
