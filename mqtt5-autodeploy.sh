#!/bin/bash

set -e

LOG_FILE="deploy_mqtt5.log"
clear
echo "🔧 MQTT5 Docker Setup Wizard (based on sukesh-ak/setup-mosquitto-with-docker)"

read -p "Enter MQTT username [espuser]: " MQTT_USER
MQTT_USER=${MQTT_USER:-espuser}

read -sp "Enter MQTT password [esppass]: " MQTT_PASS
MQTT_PASS=${MQTT_PASS:-esppass}
echo

read -p "Enter port for MQTT TCP (default 1883): " MQTT_PORT
MQTT_PORT=${MQTT_PORT:-1883}

read -p "Enter port for MQTT WebSockets (default 9883): " WS_PORT
WS_PORT=${WS_PORT:-9883}

read -p "Enter Portainer API URL (e.g. http://localhost:9000/api): " PORTAINER_URL
read -p "Enter Portainer API Key: " PORTAINER_API
read -p "Enter Stack Name [mqtt5]: " STACK_NAME
STACK_NAME=${STACK_NAME:-mqtt5}

INSTALL_DIR=/opt/mqtt5
sudo mkdir -p $INSTALL_DIR/config $INSTALL_DIR/data $INSTALL_DIR/log
sudo chown -R $(id -u):$(id -g) $INSTALL_DIR

# Check for existing container or service conflict
if docker ps -a --format '{{.Names}}' | grep -q "^mqtt5$"; then
  echo "❌ Error: A container named 'mqtt5' already exists. Please remove it before proceeding."
  exit 1
fi

# Create a non-root system user if not already present
if ! id "mqttuser" &>/dev/null; then
  echo "Creating system user 'mqttuser'..."
  sudo useradd -r -s /sbin/nologin mqttuser
fi

# Set permissions for the directories
sudo chown -R mqttuser:mqttuser $INSTALL_DIR

# Generate password file
docker run --rm -v "$INSTALL_DIR/config:/mosquitto/config" eclipse-mosquitto:2 \
  mosquitto_passwd -b -c /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASS"

# Generate mosquitto.conf
cat > $INSTALL_DIR/config/mosquitto.conf <<EOF
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
allow_anonymous false
password_file /mosquitto/config/passwd
listener $MQTT_PORT
listener $WS_PORT
protocol websockets
EOF

# Generate docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3'

services:
  mqtt5:
    image: eclipse-mosquitto:2
    container_name: mqtt5
    user: "\$(id -u mqttuser):\$(id -g mqttuser)"
    ports:
      - "$MQTT_PORT:$MQTT_PORT"
      - "$WS_PORT:$WS_PORT"
    volumes:
      - $INSTALL_DIR/config:/mosquitto/config
      - $INSTALL_DIR/data:/mosquitto/data
      - $INSTALL_DIR/log:/mosquitto/log
    restart: unless-stopped
EOF

# Deploy via Portainer API with retry
STACK_PAYLOAD=$(jq -n --arg name "$STACK_NAME" --argjson env "[]" --arg content "$(<docker-compose.yml)" \
  '{Name: $name, StackFileContent: $content, Env: $env, Prune: true}')

MAX_RETRIES=3
RETRY_DELAY=5
TRY=1

while [ $TRY -le $MAX_RETRIES ]; do
  echo "🔄 Attempt $TRY to deploy stack..." | tee -a "$LOG_FILE"
  echo "$STACK_PAYLOAD" > stack_payload.json

  RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" -o response.log -X POST "$PORTAINER_URL/stacks" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $PORTAINER_API" \
    -d @stack_payload.json)

  CODE=$(echo "$RESPONSE" | sed -n 's/.*HTTP_CODE://p')

  cat response.log >> "$LOG_FILE"
  echo "Response code: $CODE" >> "$LOG_FILE"

  if [[ "$CODE" == "200" || "$CODE" == "201" ]]; then
    echo -e "✅ MQTT5 configured and deployed to Portainer as stack '$STACK_NAME'." | tee -a "$LOG_FILE"
    echo -e "📦 You can now manage it via the Portainer UI."
    exit 0
  else
    echo "⚠️  Attempt $TRY failed (HTTP $CODE). Retrying in $RETRY_DELAY seconds..." | tee -a "$LOG_FILE"
    sleep $RETRY_DELAY
    TRY=$((TRY+1))
  fi

done

echo -e "❌ Failed to deploy stack after $MAX_RETRIES attempts." | tee -a "$LOG_FILE"
exit 1
