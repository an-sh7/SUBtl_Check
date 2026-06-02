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
#   ./subtl_check.sh -L subs.txt     # check the hosts listed in a file (one/line)
#   ./subtl_check.sh -d ./some_dir   # check every *.txt in a directory
#
# Tools required: httpx (ProjectDiscovery). Auto-installed on first run.
# =============================================================================

SETUP_FLAG="./.subtl-check_ran_already"

# All status output lands here, one set of files per processed list.
OUTPUT_DIR="./subtl_check"

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

# ── Argument parsing ──────────────────────────────────────────────────────────
LIST_FILE=""
SCAN_DIR=""

SLOW_MODE=false
REMOVE_FAILED=false

usage() {
    echo "Usage: $0 -L <hosts_file> | -d <dir> [-s] [-r]"
    echo "  -L <hosts_file>   check the hosts listed in a file (one per line)"
    echo "  -d <dir>          check every *.txt in <dir>"
    echo "  -s                slow mode: longer timeout, more retries, gentler"
    echo "                    concurrency -- use when targets are slow or flaky"
    echo "                    so live-but-slow hosts aren't marked FAILED."
    echo "  -r                remove failed (dead/unresolved) hosts from the input"
    echo "                    list in place, keeping only live ones. A .bak backup"
    echo "                    of each original list is written first. Pairs well"
    echo "                    with -s so you don't prune hosts that were just slow."
    echo ""
    echo "  You must point the tool at an input explicitly; there is no default path."
    echo "  Examples:"
    echo "    $0 -L subs.txt"
    echo "    $0 -d ../Sub_Recon/sub_recon"
    echo "    $0 -d ../Sub_Recon/sub_recon -s"
    echo "    $0 -L subs.txt -s -r"
}

while getopts "L:d:srh" opt; do
    case $opt in
        L) LIST_FILE="$OPTARG" ;;
        d) SCAN_DIR="$OPTARG" ;;
        s) SLOW_MODE=true ;;
        r) REMOVE_FAILED=true ;;
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

# ── Status-check routine (runs once per input file) ─────────────────────────────
GRAND_TOTAL=0
GRAND_ALIVE=0
GRAND_DEAD=0

check_file() {
    local infile="$1"
    local base status_file alive_file
    base="$(basename "$infile" .txt)"
    status_file="$OUTPUT_DIR/${base}_status.txt"
    alive_file="$OUTPUT_DIR/${base}_alive.txt"

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

    # Basic mode: status code + probe result (SUCCESS/FAILED) for every host,
    # so both alive and dead hosts are recorded. No color so the file is parseable.
    "$HTTPX_BIN" \
        -l "$infile" \
        -silent \
        -no-color \
        -probe \
        -status-code \
        -threads "$HTTPX_THREADS" \
        -timeout "$HTTPX_TIMEOUT" \
        -retries "$HTTPX_RETRIES" \
        -o "$status_file" 2>/dev/null

    # Derive counts and a clean alive-hosts list (handy for feeding other tools).
    local alive dead
    alive=$(grep -c '\[SUCCESS\]' "$status_file" 2>/dev/null); alive=${alive:-0}
    dead=$(grep -c '\[FAILED\]' "$status_file" 2>/dev/null);   dead=${dead:-0}

    # Alive list = first column (the URL) of every SUCCESS line.
    grep '\[SUCCESS\]' "$status_file" 2>/dev/null | awk '{print $1}' > "$alive_file"

    echo ""
    echo "---------------------------------------------"
    echo "   Alive : $alive"
    echo "   Dead  : $dead"
    echo "---------------------------------------------"
    echo "   Status code breakdown:"
    # Pull every [NNN] status token and tally it.
    grep -oE '\[[0-9]{3}\]' "$status_file" 2>/dev/null \
        | tr -d '[]' | sort | uniq -c | sort -rn \
        | awk '{printf "     %s  -> %s host(s)\n", $2, $1}'
    echo "---------------------------------------------"
    echo "   Full status : $status_file"
    echo "   Alive hosts : $alive_file"

    # -r : prune dead/unresolved hosts from the input list itself, keeping only
    # the live ones (original bare-hostname format preserved). A .bak backup is
    # written first so the operation is fully reversible.
    if [ "$REMOVE_FAILED" = true ]; then
        if [ "$dead" -eq 0 ]; then
            echo "   -r          : nothing to remove (no failed hosts)"
        else
            local alive_norm pruned kept
            alive_norm="$(mktemp)"
            pruned="$(mktemp)"
            # Normalize alive URLs down to bare hostnames for matching.
            sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##' "$alive_file" \
                | tr 'A-Z' 'a-z' | sort -u > "$alive_norm"
            # Keep only input lines whose host is alive (preserve the original text).
            awk '
                NR==FNR { alive[$0]=1; next }
                {
                    h=$0
                    sub(/^[[:space:]]+/,"",h); sub(/[[:space:]]+$/,"",h)
                    if (h=="" || h ~ /^#/) next
                    sub(/^[a-zA-Z]+:\/\//,"",h)
                    sub(/[:\/].*$/,"",h)
                    h=tolower(h)
                    if (h in alive) print $0
                }
            ' "$alive_norm" "$infile" > "$pruned"
            cp "$infile" "${infile}.bak"
            mv "$pruned" "$infile"
            rm -f "$alive_norm"
            kept=$(grep -vcE '^\s*(#|$)' "$infile" 2>/dev/null); kept=${kept:-0}
            echo "   -r          : removed $dead failed host(s), kept $kept live"
            echo "   backup      : ${infile}.bak"
        fi
    fi

    echo "============================================="

    GRAND_TOTAL=$((GRAND_TOTAL + total))
    GRAND_ALIVE=$((GRAND_ALIVE + alive))
    GRAND_DEAD=$((GRAND_DEAD + dead))
}

# ── Run over every input file ───────────────────────────────────────────────────
echo ""
echo "[*] Using httpx: $HTTPX_BIN"
echo "[*] Lists to check: ${#INPUT_FILES[@]}"

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
    echo "============================================================="
fi
echo ""
