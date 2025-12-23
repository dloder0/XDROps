
#!/usr/bin/env bash
set -euxo pipefail

CALDERA_VERSION="5.0.0"

mkdir -p /opt/caldera/app
cd /opt/caldera/app

# Clone CALDERA
if [ ! -d ".git" ]; then
    git clone --branch "$CALDERA_VERSION" https://github.com/mitre/caldera .
fi

# Python venv + install
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Build UI assets
python3 server.py --insecure --build || true

# Make a systemd service if you want
cat >/etc/systemd/system/caldera.service <<EOF
[Unit]
Description=MITRE Caldera
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/caldera/app
ExecStart=/opt/caldera/app/venv/bin/python3 /opt/caldera/app/server.py --insecure
Restart=always

[Install]
WantedBy=multi-user.target
EOF
