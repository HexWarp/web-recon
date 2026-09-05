#!/bin/bash

# ==============================================================================
# DISCLAIMER: This tool is created strictly for educational research, defensive 
# analysis, and authorized penetration testing purposes only. The author 
# accepts zero liability for any misuse or damage caused by this software.
# ==============================================================================

echo "What domain do you wan to scan today:"
read -r TARGET

OUTPUT_DIR="${TARGET}_SCANS"
mkdir -p "$OUTPUT_DIR"

LOG_FILE="$OUTPUT_DIR/scan_progress.log"
echo "=== SCAN STARTED FOR $TARGET AT $(date) ===" > "$LOG_FILE"

# ==========================================
# STEP 1: SUBDOMAIN ENUMERATION & LIVE EXTRACTION
# ==========================================
echo "==SCANNING FOR SUBDOMAINS=="
subfinder -d "$TARGET" -o "$OUTPUT_DIR/domains.txt"
echo "[DONE] Subdomain harvested into domains.txt." | tee -a "$LOG_FILE"

echo "==CHECKING LIVE SUBDOMAINS PRE-SCAN=="
# Filter active targets immediately to avoid firewall drops
httpx -l "$OUTPUT_DIR/domains.txt" -silent -o "$OUTPUT_DIR/live.txt"
echo "[DONE] Live hosts identified and isolated." | tee -a "$LOG_FILE"

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
echo "[DONE] Subdomain takeover check complete." | tee -a "$LOG_FILE"

# 2. Base Vulnerability Check
echo "==CHECKING FOR VULN=="
# Rate-limit and bulk-size are throttled to bypass aggressive WAF blockages
nuclei -l "$OUTPUT_DIR/live.txt" -rate-limit 20 -bulk-size 5 -o "$OUTPUT_DIR/nuclei_results.txt"
echo "[DONE] Nuclei live host scan complete." | tee -a "$LOG_FILE"

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
echo "[DONE] Katana crawling and secondary Nuclei scan complete." | tee -a "$LOG_FILE"

echo "==SQL TESTING=="
# Rely on Katana to isolate query-string endpoints from the live hosts
katana -list "$OUTPUT_DIR/live.txt" -f qurl -silent -o "$OUTPUT_DIR/sqlmap_targets.txt"
if [ -s "$OUTPUT_DIR/sqlmap_targets.txt" ]; then
    sqlmap -m "$OUTPUT_DIR/sqlmap_targets.txt" --batch --crawl=0 --output-dir="$OUTPUT_DIR/sqlmap_results"
    echo "[DONE] SQL testing complete." | tee -a "$LOG_FILE"
else
    echo "[INFO] No parameterized URLs found for SQL injection testing." | tee -a "$LOG_FILE"
fi

# ==========================================
# STEP 4: WORKSPACE CLEANUP (POST-SCAN)
# ==========================================
echo "==CLEANING UP TEMPORARY RAW DATA FOLDERS=="
# Deletes raw intermediate noise dumps to keep the results folder lightweight
rm -f "$OUTPUT_DIR/katana_urls_raw.txt"
rm -f "$OUTPUT_DIR/sqlmap_targets.txt"

echo "=== ALL SCANS COMPLETED AT $(date) ===" | tee -a "$LOG_FILE"
