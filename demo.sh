#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[1;32m"
BLUE="\033[1;34m"
RED="\033[1;31m"
RESET="\033[0m"
SPINNER=( '|' '/' '-' '\\' )

show_banner() {
  local LINE="  C E P H   ↔   P O L A R I S  "
  local WIDTH=${#LINE}
  local BORDER
  BORDER=$(printf '═%.0s' $(seq 1 $WIDTH))
  echo -e "${BLUE}╔${BORDER}╗${RESET}"
  echo -e "${BLUE}║${GREEN}${LINE}${BLUE}║${RESET}"
  echo -e "${BLUE}╚${BORDER}╝${RESET}\n"
}

display_step() {
  echo -ne "${BLUE}Press Enter to review next step...${RESET}"
  read -r
  clear
  show_banner
  echo -e "${GREEN}========================================${RESET}"
  echo -e "${BLUE}▶ $1${RESET}"
  echo -e "${GREEN}========================================${RESET}"
  echo -e "  • $2"

  if [ -n "${3-}" ]; then
    echo
    echo -e "${BLUE}Variables Used:${RESET}"
    if [[ "${3}" == *variables.tf ]]; then
      # Extract name and default values: print name = value
      awk '/^variable[[:space:]]+"/ {name=$2} \
           /^[[:space:]]*default[[:space:]]*=/ {val=$0; sub(/^[^=]*=[[:space:]]*/, "", val); gsub(/^"|"$/, "", val); print name " = " val}' "${3}"
    else
      # Show all non-comment, non-blank lines
      grep -Ev '^[[:space:]]*(#|//|$)' "${3}"
    fi
  fi
  echo
  echo -ne "${BLUE}Press Enter to execute this step...${RESET}"
  read -r
  echo
}

log() {
  printf "\n${BLUE}▶ %s${RESET}\n" "$*"
}

usage() {
  echo "Usage: $0 {up|destroy}"
  exit 1
}

CEPH_TF_DIR="./ceph"
POLARIS_TF_DIR="./polaris"
COMPOSE_FILE="./docker-compose.yml"
COMPOSE_ENV_FILE=".compose-aws.env"
POLARIS_HEALTH_URL="http://localhost:8182/healthcheck"
TOKENS_FILE="./notebooks/tokens.json"

terraform_init()    { terraform -chdir="$1" init -upgrade -input=false; }
terraform_apply()   { terraform -chdir="$1" apply   -auto-approve; }
terraform_destroy() { terraform -chdir="$1" destroy -auto-approve; }

safe_import() {
  dir=$1 addr=$2 id=$3
  terraform -chdir="$dir" state show "$addr" &>/dev/null && return 0
  terraform -chdir="$dir" import "$addr" "$id" 2>/dev/null || true
}

wait_for_polaris() {
  log "Waiting for Polaris healthcheck…"
  for i in $(seq 0 $(( ${#SPINNER[@]} * 10 ))); do
    if curl -fsSL "$POLARIS_HEALTH_URL" &>/dev/null; then
      echo -e " ${GREEN}OK${RESET}"
      return
    fi
    printf "\b${SPINNER[i % ${#SPINNER[@]}]}"
    sleep 0.2
  done
  echo -e " ${RED}FAILED${RESET}"
  exit 1
}

cmd_up() {
  show_banner

  display_step "1️⃣ Ceph Terraform Stack" \
               "Provision S3 bucket; create IAM user, role, policies and catalog bucket" \
               "$CEPH_TF_DIR/terraform.tfvars"

  terraform_init "$CEPH_TF_DIR"
  safe_import "$CEPH_TF_DIR" aws_s3_bucket.catalog_bucket     "polarisdemo"
  safe_import "$CEPH_TF_DIR" aws_iam_user.catalog_admin       "admin"
  safe_import "$CEPH_TF_DIR" aws_iam_role.catalog_client_role "client"
  terraform_apply "$CEPH_TF_DIR"

  export TF_VAR_storage_base_location="$(terraform -chdir="$CEPH_TF_DIR" output -raw location)"
  export TF_VAR_s3_role_arn="$(terraform -chdir="$CEPH_TF_DIR" output -raw role_arn)"
  export TF_VAR_profile_name="polaris-root"
  export TF_VAR_endpoint="https://s3.cephlabs.com"
  COMPOSE_ENV_FILE_PATH="$(terraform -chdir="$CEPH_TF_DIR" output -raw compose_env_path)"

  display_step "2️⃣ Docker Compose" \
               "Launch Polaris & dependencies in Podman Compose"
  log "Starting docker-compose stack"
  AWS_ENV_FILE="$COMPOSE_ENV_FILE_PATH" \
    docker compose -f "$COMPOSE_FILE" \
      --env-file "$COMPOSE_ENV_FILE_PATH" up -d --remove-orphans
  wait_for_polaris

  display_step "2️⃣a Containers Running" \
               "Here are the active containers:"
  podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

  display_step "3️⃣ Polaris Terraform Stack" \
               "Configure Polaris catalog, namespace, principals & roles" \
               "$POLARIS_TF_DIR/variables.tf"
  terraform_init  "$POLARIS_TF_DIR"
  terraform_apply "$POLARIS_TF_DIR"

  display_step "3️⃣a Polaris Outputs" \
               "Summary of created Polaris resources"
  terraform -chdir="$POLARIS_TF_DIR" state list

  display_step "4️⃣ Generate Tokens JSON" \
               "Extract Scoped Polaris OAuth 2.0 tokens for Alice, Bob & Charlie"
  ALICE_TOKEN=$(terraform -chdir="$POLARIS_TF_DIR" output -raw alice_token)
  BOB_TOKEN=$(terraform -chdir="$POLARIS_TF_DIR" output -raw bob_token)
  CHARLIE_TOKEN=$(terraform -chdir="$POLARIS_TF_DIR" output -raw charlie_token)
  rm -f "$TOKENS_FILE"
  jq -n \
    --arg alice   "$ALICE_TOKEN" \
    --arg bob     "$BOB_TOKEN"   \
    --arg charlie "$CHARLIE_TOKEN" \
    '{alice:$alice, bob:$bob, charlie:$charlie}' >"$TOKENS_FILE"
  log "Tokens written to $TOKENS_FILE"

     # ─── 4️⃣a Generate Trino catalog with Charlie’s token ───────────────────
  mkdir -p trino/catalog
  cat > trino/catalog/prod.properties <<EOF
connector.name=iceberg

iceberg.catalog.type=rest
iceberg.rest-catalog.uri=http://polaris:8181/api/catalog
iceberg.rest-catalog.warehouse=prod

iceberg.rest-catalog.security=OAUTH2
iceberg.rest-catalog.oauth2.token=$CHARLIE_TOKEN

fs.native-s3.enabled=true
s3.endpoint=${TF_VAR_endpoint}
s3.path-style-access=true
s3.region=${TF_VAR_s3_region:-default}

iceberg.rest-catalog.vended-credentials-enabled=true
iceberg.rest-catalog.nested-namespace-enabled=false
iceberg.rest-catalog.case-insensitive-name-matching=false
EOF
  log "✔ trino/catalog/prod.properties rendered with Principal token for trino"
  podman restart trino
  display_step "5️⃣ Jupyter Ready" "Copy-and-paste this URL into your browser"
  podman compose logs --tail 20 jupyter 2> /tmp/logs
  TOKEN=$(grep -Eo 'token=[0-9a-f]+' /tmp/logs | head -1 | cut -d= -f2)
  HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)

  echo -e "\n${GREEN}📓 Jupyter Lab is up!${RESET}"
  echo -e "   ${BLUE}http:///${HOST_IP}:8888/lab?token=${TOKEN}${RESET}\n"
}

cmd_destroy() {
  show_banner

  display_step "🛑 Tear Down: Docker Compose" \
               "Stop & remove all Polaris containers"
  docker compose -f "$COMPOSE_FILE" --env-file="$COMPOSE_ENV_FILE" down -v || true

  display_step "🛑 Tear Down: Polaris Terraform" \
               "Destroy Polaris catalog, roles & principals"
  terraform_init  "$POLARIS_TF_DIR" && terraform_destroy "$POLARIS_TF_DIR" || true

  display_step "🛑 Tear Down: Ceph Terraform" \
               "Destroy Ceph S3 bucket & IAM resources"
  terraform_init  "$CEPH_TF_DIR"    && terraform_destroy "$CEPH_TF_DIR"    || true

  [ -f "$COMPOSE_ENV_FILE" ] && rm -f "$COMPOSE_ENV_FILE"
  log "Cleanup complete"
}

case "${1:-}" in
  up)      cmd_up      ;;
  destroy) cmd_destroy ;;
  *)       usage       ;;
esac

