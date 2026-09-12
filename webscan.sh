#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ==============================================================================
# DISCLAIMER: This tool is created strictly for educational research, defensive 
# analysis, and authorized penetration testing purposes only. The author 
# accepts zero liability for any misuse or damage caused by this software.
# ==============================================================================

usage() {
    printf 'Usage: %s [domain]\n' "${0##*/}"
    printf '       %s --help\n' "${0##*/}"
}

log() {
    printf '%s\n' "$1" | tee -a "$LOG_FILE"
}

on_error() {
    local exit_code=$?
    printf '[ERROR] Scan failed near line %s (exit %s).\n' "${BASH_LINENO[0]:-unknown}" "$exit_code" | tee -a "${LOG_FILE:-/dev/stderr}" >&2
    exit "$exit_code"
}

trap on_error ERR

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    printf 'What domain do you want to scan today: '
    if ! read -r TARGET; then
        printf '\n[ERROR] No target was provided.\n' >&2
        exit 2
    fi
fi

if [[ ! "$TARGET" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$TARGET" == *..* ]]; then
    printf '[ERROR] Enter a hostname such as example.com, without a scheme or path.\n' >&2
    exit 2
fi

for required_command in subfinder httpx subzy nuclei katana sqlmap; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf '[ERROR] Required command not found: %s\n' "$required_command" >&2
        exit 127
    fi
done

OUTPUT_DIR="${TARGET}_SCANS"
mkdir -p "$OUTPUT_DIR"

LOG_FILE="$OUTPUT_DIR/scan_progress.log"
printf '=== SCAN STARTED FOR %s AT %s ===\n' "$TARGET" "$(date)" > "$LOG_FILE"

# ==========================================
# STEP 1: SUBDOMAIN ENUMERATION & LIVE EXTRACTION
# ==========================================
echo "==SCANNING FOR SUBDOMAINS=="
subfinder -d "$TARGET" -o "$OUTPUT_DIR/domains.txt"
log "[DONE] Subdomain harvested into domains.txt."

echo "==CHECKING LIVE SUBDOMAINS PRE-SCAN=="
# Filter active targets immediately to avoid firewall drops
httpx -l "$OUTPUT_DIR/domains.txt" -silent -o "$OUTPUT_DIR/live.txt"
log "[DONE] Live hosts identified and isolated."

# Fallback safety: If httpx found zero live subdomains, default safely to the apex target
if [ ! -s "$OUTPUT_DIR/live.txt" ]; then
    echo "https://$TARGET" > "$OUTPUT_DIR/live.txt"
fi

# ==========================================
# STEP 2: RUN VULNERABILITY SQUEEZE PIPELINE
# ==========================================

# 1. Subdomain Takeover (Fed from verified live list)
echo "==CHECKING FOR SUBDOMAIN TAKEOVER=="
subzy run --targets "$OUTPUT_DIR/domains.txt" --output "$OUTPUT_DIR/subzy_results.txt"
log "[DONE] Subdomain takeover check complete."

# 2. Base Vulnerability Check
echo "==CHECKING FOR VULN=="
# Rate-limit and bulk-size are throttled to bypass aggressive WAF blockages
nuclei -l "$OUTPUT_DIR/live.txt" -rate-limit 20 -bulk-size 5 -o "$OUTPUT_DIR/nuclei_results.txt"
log "[DONE] Nuclei live host scan complete."

# ==========================================
# STEP 3: CRAWL & TARGETED ENDPOINT TESTING
# ==========================================
echo "==RUNNING KATANA=="
# Crawl the live targets discovered earlier
katana -list "$OUTPUT_DIR/live.txt" -depth 2 -silent -o "$OUTPUT_DIR/katana_urls_raw.txt"

# Strip out resource-heavy static file noise (.js, .css) to prevent Nuclei verification blocks
if [ -s "$OUTPUT_DIR/katana_urls_raw.txt" ]; then
    grep -E -v "\.(css|js|png|jpg|jpeg|gif|svg|woff|woff2|ttf|ico|mp4|avi)$" "$OUTPUT_DIR/katana_urls_raw.txt" > "$OUTPUT_DIR/katana_urls.txt" || true
else
    touch "$OUTPUT_DIR/katana_urls.txt"
fi

if [ -s "$OUTPUT_DIR/katana_urls.txt" ]; then
    echo "==RUNNING TARGETED NUCLEI ON CRAWLED ENDPOINTS=="
    nuclei -l "$OUTPUT_DIR/katana_urls.txt" -rate-limit 15 -severity medium,high,critical -o "$OUTPUT_DIR/katana_nuclei.txt"
fi
log "[DONE] Katana crawling and secondary Nuclei scan complete."

echo "==SQL TESTING=="
# Rely on Katana to isolate query-string endpoints from the live hosts
katana -list "$OUTPUT_DIR/live.txt" -f qurl -silent -o "$OUTPUT_DIR/sqlmap_targets.txt"
if [ -s "$OUTPUT_DIR/sqlmap_targets.txt" ]; then
    sqlmap -m "$OUTPUT_DIR/sqlmap_targets.txt" --batch --crawl=0 --output-dir="$OUTPUT_DIR/sqlmap_results"
    log "[DONE] SQL testing complete."
else
    log "[INFO] No parameterized URLs found for SQL injection testing."
fi

# ==========================================
# STEP 4: WORKSPACE CLEANUP (POST-SCAN)
# ==========================================
echo "==CLEANING UP TEMPORARY RAW DATA FOLDERS=="
# Deletes raw intermediate noise dumps to keep the results folder lightweight
rm -f "$OUTPUT_DIR/katana_urls_raw.txt"
rm -f "$OUTPUT_DIR/sqlmap_targets.txt"

log "=== ALL SCANS COMPLETED AT $(date) ==="
