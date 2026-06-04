#!/bin/bash

# =============================================================================
# subtl_check.sh - Subdomain Status Checker (basic mode)
# -----------------------------------------------------------------------------
# Probes a list of hosts (e.g. the subdomain lists produced by Sub_Recon) with
# ProjectDiscovery httpx and reports which are alive and what HTTP status code
# they return. You point it at the input explicitly -- it does not read from any
# hardcoded/default location.
#
# Usage:
#   ./subtl_check.sh -L subs.txt              # check hosts in a file
#   ./subtl_check.sh -d ./some_dir            # check every *.txt in a directory
#   ./subtl_check.sh -L subs.txt -o out.txt   # also save the breakdown to a file
#   ./subtl_check.sh -L subs.txt -s           # slow probe (patient on flaky hosts)
#
# Tools required: httpx (ProjectDiscovery). Auto-installed on first run.
# =============================================================================

SETUP_FLAG="./.subtl-check_ran_already"

# Per-list output (full status + clean alive list) always lands here.
OUTPUT_DIR="./domain_status_output"

# httpx tuning (basic mode).
HTTPX_THREADS=50
HTTPX_TIMEOUT=10
HTTPX_RETRIES=1

# Resolved at runtime to the ProjectDiscovery httpx binary (NOT the python one).
HTTPX_BIN=""

# ── Loading Bar (matches Sub_Recon's look) ─────────────────────────────────────
loading_bar() {
    local label="$1"
    local pid="$2"
    local width=40
    local i=0

    printf "  %-20s\n  [" "$label"
    while kill -0 "$pid" 2>/dev/null; do
        if [ $i -lt $width ]; then
            printf "#"
            i=$((i + 1))
        fi
        sleep 0.3
    done
    while [ $i -lt $width ]; do
        printf "#"
        i=$((i + 1))
    done
    printf "] done\n"
}

# ── Locate the ProjectDiscovery httpx ──────────────────────────────────────────
# On Kali, /usr/bin/httpx is the *python* httpx HTTP client, which is NOT what we
# want. The real prober responds to `-version`; the python one does not. We probe
# known install locations first, then fall back to a PATH httpx only if it passes
# the `-version` test.
resolve_httpx() {
    local candidates=(
        "$HOME/go/bin/httpx"
        "/root/go/bin/httpx"
        "$(command -v httpx-toolkit 2>/dev/null)"
    )

    local c
    for c in "${candidates[@]}"; do
        if [ -n "$c" ] && [ -x "$c" ] && "$c" -version >/dev/null 2>&1; then
            HTTPX_BIN="$c"
            return 0
        fi
    done

    if command -v httpx >/dev/null 2>&1 && httpx -version >/dev/null 2>&1; then
        HTTPX_BIN="$(command -v httpx)"
        return 0
    fi

    return 1
}

# ── First-run setup: make sure Go + ProjectDiscovery httpx are present ──────────
if [ ! -f "$SETUP_FLAG" ]; then
    echo "First run detected. Running initial setup..."
    echo ""

    # Go is required to `go install` httpx. Install it if missing (mirrors Sub_Recon).
    if command -v go >/dev/null 2>&1; then
        echo "  Go-Lib              Already present. Skipping..."
    else
        if command -v apt >/dev/null 2>&1; then
            (sudo apt update -qq && sudo apt install -y golang-go -qq) > /dev/null 2>&1 &
        elif command -v dnf >/dev/null 2>&1; then
            (sudo dnf install -y golang -q) > /dev/null 2>&1 &
        elif command -v pacman >/dev/null 2>&1; then
            (sudo pacman -Sy --noconfirm go) > /dev/null 2>&1 &
        elif command -v brew >/dev/null 2>&1; then
            (brew install go) > /dev/null 2>&1 &
        else
            echo "Unsupported package manager. Install Go manually."
            exit 1
        fi
        loading_bar "installing go" $!
        wait
        if command -v go >/dev/null 2>&1; then
            echo "  go                   Installed successfully."
        else
            echo "  go                   Installation failed. Aborting."
            exit 1
        fi
    fi

    export PATH="$PATH:$HOME/go/bin"

    echo ""

    # ProjectDiscovery httpx — install via `go install` if the real prober is absent.
    if resolve_httpx; then
        echo "  httpx               Already present. Skipping..."
    else
        go install github.com/projectdiscovery/httpx/cmd/httpx@latest > /dev/null 2>&1 &
        loading_bar "Installing httpx" $!
        wait
        hash -r
        if resolve_httpx; then
            echo "  httpx                installed successfully."
        else
            echo "  httpx                installation failed."
            echo ""
            echo "[!] Could not install ProjectDiscovery httpx. Install it manually:"
            echo "    go install github.com/projectdiscovery/httpx/cmd/httpx@latest"
            exit 1
        fi
    fi

    touch "$SETUP_FLAG"
    echo ""
    echo "Initial setup complete."
    echo ""
else
    echo "Setup already completed. Skipping installation checks."
    export PATH="$PATH:$HOME/go/bin"
fi

# ── Banner ──────────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "\033[1;36m"
    echo '+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++'
    echo '   ____  _   _ ____  _   _        ____ _               _              '
    echo '  / ___|| | | | __ )| |_| |      / ___| |__   ___  ___| | __          '
    echo '  \___ \| | | |  _ \| __| |_____| |   | |_ \ / _ \/ __| |/ /          '
    echo '   ___) | |_| | |_) | |_| |_____| |___| | | |  __/ (__|   <           '
    echo '  |____/ \___/|____/ \__|_|      \____|_| |_|\___|\___|_|\_\          '
    echo '                                                                      '
    echo '            Subdomain Status Checker  ::  powered by httpx            '
    echo '++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++'
    echo -e "\033[0m"
}

print_banner

# Make sure we actually have a usable httpx before doing any work.
if ! resolve_httpx; then
    echo "[!] ProjectDiscovery httpx not found. Delete '$SETUP_FLAG' and re-run to reinstall."
    exit 1
fi

# ── Colour helpers ─────────────────────────────────────────────────────────────
C_RESET="\033[0m"
C_BOLD="\033[1m"

# Colour by status class: 2xx green, 3xx yellow, 4xx red, 5xx bright red.
status_color() {
    case "${1:0:1}" in
        2) echo "\033[1;32m" ;;
        3) echo "\033[1;33m" ;;
        4) echo "\033[1;31m" ;;
        5) echo "\033[1;91m" ;;
        *) echo "\033[1;37m" ;;
    esac
}

# ── Human-readable label for a status code ─────────────────────────────────────
status_label() {
    case "$1" in
        100) echo "Continue" ;;
        101) echo "Switching Protocols" ;;
        200) echo "OK" ;;
        201) echo "Created" ;;
        204) echo "No Content" ;;
        206) echo "Partial Content" ;;
        301) echo "Moved Permanently" ;;
        302) echo "Found (Redirect)" ;;
        303) echo "See Other" ;;
        304) echo "Not Modified" ;;
        307) echo "Temporary Redirect" ;;
        308) echo "Permanent Redirect" ;;
        400) echo "Bad Request" ;;
        401) echo "Unauthorized" ;;
        403) echo "Forbidden" ;;
        404) echo "Not Found" ;;
        405) echo "Method Not Allowed" ;;
        408) echo "Request Timeout" ;;
        409) echo "Conflict" ;;
        410) echo "Gone" ;;
        413) echo "Payload Too Large" ;;
        414) echo "URI Too Long" ;;
        415) echo "Unsupported Media Type" ;;
        429) echo "Too Many Requests" ;;
        500) echo "Internal Server Error" ;;
        501) echo "Not Implemented" ;;
        502) echo "Bad Gateway" ;;
        503) echo "Service Unavailable" ;;
        504) echo "Gateway Timeout" ;;
        521) echo "Web Server Is Down" ;;
        522) echo "Connection Timed Out" ;;
        523) echo "Origin Is Unreachable" ;;
        524) echo "A Timeout Occurred" ;;
        525) echo "SSL Handshake Failed" ;;
        526) echo "Invalid SSL Certificate" ;;
        530) echo "Site Frozen" ;;
        *)   echo "" ;;
    esac
}

# ── Argument parsing ──────────────────────────────────────────────────────────
LIST_FILE=""
SCAN_DIR=""
OUTPUT_FILE=""
SLOW_MODE=false

usage() {
    echo "Usage: $0 -L <hosts_file> | -d <dir> [-s] [-o <file>]"
    echo "  -L <hosts_file>   check the hosts listed in a file (one per line)"
    echo "  -d <dir>          check every *.txt in <dir>"
    echo "  -s                slow mode: longer timeout, more retries, gentler"
    echo "                    concurrency -- use when targets are slow or flaky"
    echo "                    so live-but-slow hosts aren't marked FAILED."
    echo "  -o <file>         also save the status-code breakdown to a single file"
    echo "                    (in addition to the per-list alive files in $OUTPUT_DIR)."
    echo ""
    echo "  You must point the tool at an input explicitly; there is no default path."
    echo "  Examples:"
    echo "    $0 -L subs.txt"
    echo "    $0 -L subs.txt -o results.txt"
    echo "    $0 -d ../Sub_Recon/sub_recon -s"
}

while getopts "L:d:o:sh" opt; do
    case $opt in
        L) LIST_FILE="$OPTARG" ;;
        d) SCAN_DIR="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        s) SLOW_MODE=true ;;
        h) usage; exit 0 ;;
        *) echo "Invalid option. Use -h for help."; exit 1 ;;
    esac
done

# Slow mode: be patient and gentle so flaky/slow hosts get a fair chance and
# aren't falsely reported as dead. Lower concurrency avoids hammering targets
# that rate-limit or drop connections under load.
if [ "$SLOW_MODE" = true ]; then
    HTTPX_THREADS=15
    HTTPX_TIMEOUT=30
    HTTPX_RETRIES=3
fi

# Require exactly one input source -- never fall back to a predefined path.
if [ -z "$LIST_FILE" ] && [ -z "$SCAN_DIR" ]; then
    echo "[!] Error: no input given. Provide a hosts file (-L) or a directory (-d)."
    echo ""
    usage
    exit 1
fi
if [ -n "$LIST_FILE" ] && [ -n "$SCAN_DIR" ]; then
    echo "[!] Error: use either -L or -d, not both."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ── Build the list of input files to process ────────────────────────────────────
INPUT_FILES=()

if [ -n "$LIST_FILE" ]; then
    # Explicit file of hosts.
    if [ ! -f "$LIST_FILE" ]; then
        echo "[!] Error: hosts file not found: $LIST_FILE"
        exit 1
    fi
    INPUT_FILES+=("$LIST_FILE")

else
    # Explicit directory of subdomain lists.
    if [ ! -d "$SCAN_DIR" ]; then
        echo "[!] Error: directory not found: $SCAN_DIR"
        exit 1
    fi
    shopt -s nullglob
    for f in "$SCAN_DIR"/*.txt; do
        INPUT_FILES+=("$f")
    done
    shopt -u nullglob
    if [ ${#INPUT_FILES[@]} -eq 0 ]; then
        echo "[!] Error: no *.txt subdomain lists found in $SCAN_DIR"
        exit 1
    fi
fi

# Prepare the optional combined breakdown file (wipe once so multi-list runs append cleanly).
if [ -n "$OUTPUT_FILE" ]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null
    > "$OUTPUT_FILE"
fi

# ── Status-check routine (runs once per input file) ─────────────────────────────
GRAND_TOTAL=0
GRAND_ALIVE=0
GRAND_DEAD=0

check_file() {
    local infile="$1"
    local base tmp_status alive_file
    base="$(basename "$infile" .txt)"
    alive_file="$OUTPUT_DIR/${base}_alive.txt"      # the only saved per-list file: clean alive URLs

    # Count non-blank, non-comment input hosts.
    local total
    total=$(grep -vcE '^\s*(#|$)' "$infile" 2>/dev/null)
    total=${total:-0}

    echo ""
    echo "============================================="
    echo "   Status Check  |  $base"
    echo "============================================="
    echo "[*] Input hosts : $total   ($infile)"

    if [ "$total" -eq 0 ]; then
        echo "[!] No hosts to check in this list. Skipping."
        return
    fi

    local mode_label="normal"
    [ "$SLOW_MODE" = true ] && mode_label="SLOW"
    echo "[*] Probing with httpx [$mode_label] (threads=$HTTPX_THREADS, timeout=${HTTPX_TIMEOUT}s, retries=$HTTPX_RETRIES) ..."

    # Probe every host (status code + SUCCESS/FAILED) into a temp scratch file --
    # used only for counts/breakdown below, then deleted. stdout is silenced
    # (>/dev/null) so only our formatted breakdown reaches the screen.
    tmp_status="$(mktemp)"
    "$HTTPX_BIN" \
        -l "$infile" \
        -silent \
        -no-color \
        -probe \
        -status-code \
        -threads "$HTTPX_THREADS" \
        -timeout "$HTTPX_TIMEOUT" \
        -retries "$HTTPX_RETRIES" \
        -o "$tmp_status" >/dev/null 2>&1

    # Derive counts and the clean alive-hosts list (the one file we keep).
    local alive dead
    alive=$(grep -c '\[SUCCESS\]' "$tmp_status" 2>/dev/null); alive=${alive:-0}
    dead=$(grep -c '\[FAILED\]' "$tmp_status" 2>/dev/null);   dead=${dead:-0}

    # Alive list = bare hostname of every SUCCESS line (scheme/port/path stripped),
    # ready to feed straight into Subdomain_Takeover and similar tools.
    grep '\[SUCCESS\]' "$tmp_status" 2>/dev/null | awk '{print $1}' \
        | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##' | sort -u > "$alive_file"

    echo ""
    echo "---------------------------------------------"
    echo "   Alive : $alive"
    echo "   Dead  : $dead"
    echo "---------------------------------------------"

    # ── Status-code breakdown: group the live URLs under each code ──────────────
    # Grab the SUCCESS lines once, then slice them per code (no repeated file reads).
    local succ codes
    succ=$(grep '\[SUCCESS\]' "$tmp_status" 2>/dev/null)
    codes=$(printf '%s\n' "$succ" | grep -oE '\[[0-9]{3}\]' | tr -d '[]' | sort -un)

    if [ -n "$codes" ]; then
        echo ""
        echo "   Status Code Breakdown:"
        [ -n "$OUTPUT_FILE" ] && printf "Status Code Breakdown — %s\n" "$base" >> "$OUTPUT_FILE"

        local code color label count host_word line_hdr
        while IFS= read -r code; do
            color=$(status_color "$code")
            label=$(status_label "$code")
            count=$(printf '%s\n' "$succ" | grep -c "\[$code\]"); count=${count:-0}
            [ "$count" -ne 1 ] && host_word="hosts" || host_word="host"

            if [ -n "$label" ]; then
                line_hdr="[$code]  $label  ($count $host_word)"
            else
                line_hdr="[$code]  ($count $host_word)"
            fi

            printf "\n   ${color}${C_BOLD}%s${C_RESET}\n" "$line_hdr"
            [ -n "$OUTPUT_FILE" ] && printf "\n%s\n" "$line_hdr" >> "$OUTPUT_FILE"

            # The live URLs that returned this code.
            printf '%s\n' "$succ" | grep "\[$code\]" | awk '{print $1}' \
                | while IFS= read -r url; do
                    [ -z "$url" ] && continue
                    printf "   ${color}${C_BOLD}[%s]${C_RESET}  %s\n" "$code" "$url"
                    [ -n "$OUTPUT_FILE" ] && printf "[%s]  %s\n" "$code" "$url" >> "$OUTPUT_FILE"
                  done
        done <<< "$codes"
        echo ""
        [ -n "$OUTPUT_FILE" ] && echo "" >> "$OUTPUT_FILE"
    fi

    echo "---------------------------------------------"
    echo "   Alive hosts : $alive_file"
    [ -n "$OUTPUT_FILE" ] && echo "   Breakdown   : $OUTPUT_FILE"
    echo "============================================="

    rm -f "$tmp_status"

    GRAND_TOTAL=$((GRAND_TOTAL + total))
    GRAND_ALIVE=$((GRAND_ALIVE + alive))
    GRAND_DEAD=$((GRAND_DEAD + dead))
}

# ── Run over every input file ───────────────────────────────────────────────────
echo ""
echo "[*] Using httpx : $HTTPX_BIN"
echo "[*] Lists       : ${#INPUT_FILES[@]}"
[ -n "$OUTPUT_FILE" ] && echo "[*] Output file : $OUTPUT_FILE"

for f in "${INPUT_FILES[@]}"; do
    check_file "$f"
done

# ── Grand summary (only meaningful when >1 list processed) ───────────────────────
if [ ${#INPUT_FILES[@]} -gt 1 ]; then
    echo ""
    echo "============================================================="
    echo "   SUBtl-Check Complete  |  ${#INPUT_FILES[@]} lists processed"
    echo "-------------------------------------------------------------"
    echo "   Total hosts checked : $GRAND_TOTAL"
    echo "   Alive               : $GRAND_ALIVE"
    echo "   Dead                : $GRAND_DEAD"
    echo "   Output directory    : $OUTPUT_DIR"
    [ -n "$OUTPUT_FILE" ] && echo "   Breakdown saved     : $OUTPUT_FILE"
    echo "============================================================="
fi
echo ""
