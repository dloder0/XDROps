
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

echo "============================================================================="
echo "Docker install steps starting at $(date -Is)"
echo "============================================================================="

apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "============================================================================="
echo "Caldera install steps starting at $(date -Is)"
echo "============================================================================="

git clone https://github.com/mitre/caldera.git --recursive

echo "============================================================================="
echo "Docker build caldera steps starting at $(date -Is)"
echo "============================================================================="

cd caldera
docker build . --build-arg WIN_BUILD=true -t caldera:latest
docker run -d --name caldera_mir -p 8888:8888 caldera:latest
docker exec caldera_mir python3 -m pip config set global.break-system-packages true
docker exec caldera_mir pip3 install -r /usr/src/app/plugins/debrief/requirements.txt
docker exec caldera_mir pip3 install -r /usr/src/app/plugins/emu/requirements.txt
docker exec caldera_mir pip3 install -r /usr/src/app/plugins/human/requirements.txt
docker exec caldera_mir pip3 install -r /usr/src/app/plugins/stockpile/requirements.txt
docker exec caldera_mir sed -i '36i - emu' /usr/src/app/conf/local.yml
docker exec caldera_mir sed -i '37i - gameboard' /usr/src/app/conf/local.yml
docker exec caldera_mir sed -i '39i - human' /usr/src/app/conf/local.yml
docker commit caldera_mir caldera_update
docker stop caldera_mir
docker run -d --name caldera_new -p 8888:8888 caldera_update:latest
docker cp caldera_new:/usr/src/app/conf/local.yml /root/local.yml
docker update --restart unless-stopped caldera_new

echo "============================================================================="
echo "install-caldera.sh complete at $(date -Is)"
echo "============================================================================="
