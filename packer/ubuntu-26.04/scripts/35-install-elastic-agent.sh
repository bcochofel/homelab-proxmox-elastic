#!/bin/bash

###############################################################################
# Ubuntu 26.04 Template Install Elastic Agent
# Purpose: Pre-install the Elastic Agent package (pinned to
#          elastic_agent_version) so Ansible only has to render
#          elastic-agent.yml and enable/start the service once the ES
#          cluster exists. Left disabled+stopped here — nothing runs until
#          Ansible configures it.
# Usage: Run this script as root
# Expected env vars:
# INSTALL_ELASTIC_AGENT: If true will install Elastic Agent
# ELASTIC_AGENT_VERSION: Pinned version — MUST match
#                        ansible/group_vars/all.yml's stack_version
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

if [[ "${INSTALL_ELASTIC_AGENT:-true}" != "true" ]]; then
  log_warn "Elastic Agent installation disabled by variable."
  exit 0
fi

ELASTIC_AGENT_VERSION="${ELASTIC_AGENT_VERSION:?ELASTIC_AGENT_VERSION not set}"

log_info "Installing Elastic Agent ${ELASTIC_AGENT_VERSION} (package only — Ansible configures and enables it later)..."

case "$(dpkg --print-architecture)" in
  amd64) EA_ARCH="amd64" ;;
  arm64) EA_ARCH="arm64" ;;
  *) log_error "Unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;;
esac

TMP_DEB="$(mktemp --suffix=.deb)"
curl -fsSL "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELASTIC_AGENT_VERSION}-${EA_ARCH}.deb" -o "$TMP_DEB"
dpkg -i "$TMP_DEB"
rm -f "$TMP_DEB"

log_info "Disabling the Elastic Agent service — Ansible enables it once elastic-agent.yml is rendered and the ES cluster exists."
systemctl stop elastic-agent 2>/dev/null || true
systemctl disable elastic-agent 2>/dev/null || true

elastic-agent version --binary-only

log_info "Elastic Agent ${ELASTIC_AGENT_VERSION} installed (disabled) successfully."
