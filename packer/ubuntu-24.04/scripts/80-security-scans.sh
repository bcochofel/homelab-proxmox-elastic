#!/bin/bash

###############################################################################
# Ubuntu 24.04 Template Security Baseline
# Purpose: Initialize AIDE's file-integrity database and rkhunter's file
#          property baseline before the template is sealed. Without this,
#          the aide-check/rkhunter systemd timers (installed via autoinstall)
#          would compare against a database that never existed and flag
#          every file as new.
# Usage: Run this script as root
###############################################################################

set -e

###############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

###############################################################################

log_info "Initializing AIDE database..."
mkdir -p /var/lib/aide
if aideinit --yes --force 2>/dev/null; then
  mv -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
else
  aide --init
  mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null || \
    mv -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
fi
log_info "AIDE database initialized."

log_info "Recording rkhunter file property baseline..."
rkhunter --propupd --quiet || log_warn "rkhunter --propupd reported issues; review /var/log/rkhunter.log after boot."

log_info "Security baseline complete."
