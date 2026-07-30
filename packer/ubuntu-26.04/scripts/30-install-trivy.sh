#!/bin/bash

###############################################################################
# Ubuntu 26.04 Template Install Trivy
# Purpose: Install Trivy and schedule a daily OS-package vulnerability scan
# Usage: Run this script as root
# Expected env vars:
# INSTALL_TRIVY: If true will install Trivy
# TRIVY_VERSION: Pinned Trivy release to install (matches Makefile's TRIVY_VERSION)
# TRIVY_REPORT_PATH: Path the daily cron overwrites with the latest JSON report
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

if [[ "${INSTALL_TRIVY:-true}" != "true" ]]; then
  log_warn "Trivy installation disabled by variable."
  exit 0
fi

TRIVY_VERSION="${TRIVY_VERSION:?TRIVY_VERSION not set}"
TRIVY_REPORT_PATH="${TRIVY_REPORT_PATH:?TRIVY_REPORT_PATH not set}"

log_info "Installing Trivy ${TRIVY_VERSION}..."

case "$(dpkg --print-architecture)" in
  amd64) TRIVY_ARCH="64bit" ;;
  arm64) TRIVY_ARCH="ARM64" ;;
  *) log_error "Unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;;
esac

TMP_TAR="$(mktemp)"
curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" -o "$TMP_TAR"
tar -xzf "$TMP_TAR" -C /usr/local/bin trivy
chmod +x /usr/local/bin/trivy
rm -f "$TMP_TAR"

/usr/local/bin/trivy --version

# ubuntu-minimal doesn't guarantee cron is present.
if ! dpkg -s cron &>/dev/null; then
  apt-get update -y
  apt-get install -y cron
fi
systemctl enable --now cron

REPORT_DIR="$(dirname "$TRIVY_REPORT_PATH")"
mkdir -p "$REPORT_DIR"

log_info "Pre-downloading Trivy's vulnerability DB into the template (so each clone's first daily scan doesn't need one)..."
mkdir -p /var/cache/trivy
# --quiet: the DB download's progress bar redraws the same line hundreds of
# times via carriage returns, which Packer's log capture can't collapse —
# it prints as one giant line of percentage spam instead. --quiet suppresses
# that (and startup log lines) without hiding actual scan results below.
/usr/local/bin/trivy rootfs --download-db-only --cache-dir /var/cache/trivy --quiet / \
  || log_warn "DB pre-download failed (no network during build?) — each clone's cron will fetch it on first run instead."

# Build-time scan only: scoped to --scanners vuln --pkg-types os (Trivy's
# defaults are "vuln,secret" scanners and "os,library" package types) purely
# so the one-line summary below stays fast and readable in the Packer build
# log. The daily cron further down deliberately does NOT use this scoping —
# it runs Trivy's full default scan (secrets + OS + library CVEs) so the
# persisted JSON report is the comprehensive one, meant for later ingestion
# into Elasticsearch (see TODO.md). Without this build-time scoping, a first
# attempt at this made the build log worse instead of better: the secret
# scanner flags /etc/ssh/ssh_host_*_key as "AsymmetricPrivateKey" findings,
# and "library" scanning walks every language-specific dependency tree
# embedded in installed binaries (docker-buildx, docker-compose, and Trivy
# itself all bundle their own Go module list), printing a full CVE table
# per binary.
log_info "Running an initial vulnerability scan (OS packages only) for a build-time summary..."
TMP_BUILD_SCAN="$(mktemp)"
/usr/local/bin/trivy rootfs --cache-dir /var/cache/trivy --quiet --scanners vuln --pkg-types os --format json --output "$TMP_BUILD_SCAN" / \
  || log_warn "Build-time scan failed — the daily cron will still attempt a full scan on schedule."

if [ -s "$TMP_BUILD_SCAN" ]; then
  SUMMARY="$(jq -r '
    [.Results[]?.Vulnerabilities[]?.Severity] as $sevs |
    "Total: \($sevs | length) (CRITICAL: \([$sevs[] | select(.=="CRITICAL")] | length), HIGH: \([$sevs[] | select(.=="HIGH")] | length), MEDIUM: \([$sevs[] | select(.=="MEDIUM")] | length), LOW: \([$sevs[] | select(.=="LOW")] | length), UNKNOWN: \([$sevs[] | select(.=="UNKNOWN")] | length))"
  ' "$TMP_BUILD_SCAN")"
  log_info "OS package vulnerability summary: ${SUMMARY}"
else
  log_warn "No scan output found to summarize."
fi
rm -f "$TMP_BUILD_SCAN"

log_info "Installing daily cron job -> ${TRIVY_REPORT_PATH}"
cat >/etc/cron.d/trivy-scan <<EOF
# Managed by Packer (scripts/30-install-trivy.sh) — daily full vulnerability
# scan (OS packages, libraries, and secrets); JSON report is overwritten on
# each run.
0 3 * * * root mkdir -p "${REPORT_DIR}" && /usr/local/bin/trivy rootfs --format json --output "${TRIVY_REPORT_PATH}" --cache-dir /var/cache/trivy --quiet / >>/var/log/trivy-cron.log 2>&1
EOF
chmod 644 /etc/cron.d/trivy-scan

log_info "Trivy installed and daily scan scheduled successfully."
