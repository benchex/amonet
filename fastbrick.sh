#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ ! -f "$SCRIPT_DIR/profile.sh" ]; then
    echo "Error: profile.sh not found next to this script."
    echo "The package is incomplete - re-extract it and try again."
    exit 1
fi

# The paths below (bin/..., the payload) are relative to the package, so run
# from there no matter where the script was launched from.
cd "$SCRIPT_DIR"

. "$SCRIPT_DIR/profile.sh"

HOST_OS=$(uname -s)
SPARSE_ARGS=""

if [ "$HOST_OS" = "Darwin" ]; then
    # bin/fastboot and bin/fastboot32 are Linux ELF binaries and cannot run on
    # macOS. Use a bundled bin/fastboot-macos if the package has one, otherwise
    # Google's macOS fastboot from Android platform-tools.
    if [ -f bin/fastboot-macos ]; then
        FASTBOOT=bin/fastboot-macos
        chmod a+x "$FASTBOOT"
        xattr -d com.apple.quarantine "$FASTBOOT" 2>/dev/null || true
    elif command -v fastboot >/dev/null 2>&1; then
        FASTBOOT=$(command -v fastboot)
    else
        echo "Error: macOS fastboot not found."
        echo "Install Android platform-tools, then run this script again:"
        echo "    brew install --cask android-platform-tools"
        exit 1
    fi
else
    if [ `uname -m | grep 64` ]; then
        FASTBOOT=bin/fastboot
    else
        FASTBOOT=bin/fastboot32
    fi

    chmod a+x bin/fastboot{,32}
fi

# Replaces `declare -A DEVICE_MAP` (needs bash 4+, macOS ships bash 3.2).
device_name() {
    case "$1" in
        CRONOS)   echo "Echo Show 5 2nd Generation - 2021" ;;
        CROWN)    echo "Echo Show 8 1st Generation - 2019" ;;
        CHECKERS) echo "Echo Show 5 1st Generation - 2019" ;;
        *)        echo "" ;;
    esac
}

# GNU `timeout` is not part of macOS. Use timeout/gtimeout when present,
# otherwise emulate it: send SIGTERM after N seconds and return 124 if the
# command had to be killed, the same exit code GNU timeout uses.
run_with_timeout() {
    local secs=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return $?
    fi

    local marker
    marker=$(mktemp "${TMPDIR:-/tmp}/amonet-timeout.XXXXXX")
    rm -f "$marker"

    "$@" &
    local pid=$!

    # Watcher output goes to /dev/null so it never holds the $(...) pipe open.
    ( sleep "$secs"
      if kill -0 "$pid" 2>/dev/null; then
          touch "$marker"
          kill -TERM "$pid" 2>/dev/null
      fi ) >/dev/null 2>&1 &
    local watcher=$!

    local rc=0
    wait "$pid" || rc=$?

    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    if [ -f "$marker" ]; then
        rm -f "$marker"
        return 124
    fi
    return $rc
}

# Current platform-tools fastboot refuses to send a raw image larger than the
# device's max-download-size, and fastbrick.img can be larger than that.
# Raise the limit with -S so it still goes in as one download. Only applied on
# macOS; the Linux path keeps the bundled fastboot and its behavior.
detect_sparse_args() {
    SPARSE_ARGS=""
    if [ "$HOST_OS" != "Darwin" ]; then
        return 0
    fi

    local payload_bytes max_raw max_bytes
    payload_bytes=$(wc -c < "$FULL_IMAGE" | tr -d ' ')

    max_raw=$($FASTBOOT getvar max-download-size 2>&1 | grep "max-download-size:" | cut -d' ' -f2 | head -n1)
    if [ -n "$max_raw" ]; then
        max_bytes=$(( max_raw ))
        echo -e "${CYAN}Payload size: $payload_bytes bytes, device max-download-size: $max_bytes bytes${RESET}"
        if [ "$payload_bytes" -le "$max_bytes" ]; then
            return 0
        fi
    else
        echo -e "${YELLOW}Could not read max-download-size, raising the limit to be safe.${RESET}"
    fi

    SPARSE_ARGS="-S $(( (payload_bytes + 1048575) / 1048576 ))M"
    echo -e "${CYAN}Payload is larger than the device limit, will send with: $SPARSE_ARGS${RESET}"
}

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1 && [ $(tput colors) -ge 8 ]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    MAGENTA='\033[35m'
    CYAN='\033[36m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    RESET=''
fi

print_banner() {
    echo -e "${MAGENTA}                                   _   "
    echo -e "                                  | |  "
    echo -e "   __ _ _ __ ___   ___  _ __   ___| |_ "
    echo -e "  / _' | '_ ' _ \\ / _ \\| '_ \\ / _ \\ __|"
    echo -e " | (_| | | | | | | (_) | | | |  __/ |_  (-fastbrick)"
    echo -e "  \\__,_|_| |_| |_|\\___/|_| |_|\\___|\\_|"
    echo -e "            by k4y0z & r0rt1z2         "
    echo -e "                                       ${RESET}"
}

# The payload itself rejects the wrong device ("Device mismatch"), so this only
# waits for something to show up - without it the first getvar blocks silently.
wait_for_device() {
    echo -e "${YELLOW}Make sure device is in fastboot mode and connected!${RESET}"
    echo ""
    echo -e "${YELLOW}To enter fastboot mode:${RESET}"
    echo -e "${YELLOW}  1. Power off the device${RESET}"
    echo -e "${YELLOW}  2. Hold Volume Down + Volume Up + Mute buttons simultaneously${RESET}"
    echo -e "${YELLOW}  3. Keep holding until the fastboot screen appears${RESET}"
    echo ""
    echo -e "${YELLOW}If the device is already in fastboot mode, just connect it via USB.${RESET}"
    echo ""

    while true; do
        OUTPUT=$($FASTBOOT getvar product 2>&1)

        if echo "$OUTPUT" | grep -q "waiting for any device"; then
            sleep 1
            continue
        fi

        PRODUCT=$(echo "$OUTPUT" | grep "product:" | cut -d' ' -f2)

        if [ -z "$PRODUCT" ]; then
            sleep 1
            continue
        fi

        FRIENDLY_NAME=$(device_name "$PRODUCT")
        if [ -z "$FRIENDLY_NAME" ]; then
            FRIENDLY_NAME="Unknown device"
        fi

        echo -e "${CYAN}Detected: $PRODUCT - $FRIENDLY_NAME${RESET}"
        break
    done
}

check_unlocked() {
    OUTPUT=$($FASTBOOT getvar unlock_status 2>&1)
    UNLOCK_STATUS=$(echo "$OUTPUT" | grep "unlock_status:" | cut -d' ' -f2 | head -n1 | tr '[:upper:]' '[:lower:]')

    if [ "$UNLOCK_STATUS" = "true" ]; then
        echo ""
        echo -e "${GREEN}Your bootloader is already unlocked!${RESET}"
        echo ""
        echo -e "${GREEN}The amonet-fastbrick exploit cannot be run on a device that is${RESET}"
        echo -e "${GREEN}already unlocked. There is no need to run it again.${RESET}"
        echo ""
        echo "Press any key to exit..."
        read -n 1 -s
        exit 0
    fi
}

detect_image() {
    FULL_IMAGE="$DEFAULT_IMAGE"

    OUTPUT=$($FASTBOOT getvar lk_build_desc 2>&1)
    LK_BUILD_DESC=$(echo "$OUTPUT" | grep "lk_build_desc:" | cut -d' ' -f2- | head -n1)

    if [ -n "$LK_BUILD_DESC" ]; then
        echo -e "${CYAN}LK build: $LK_BUILD_DESC${RESET}"
    fi

    if [ -n "$LK_BUILD_DESC" ]; then
        for entry in "${IMAGE_MAP_ENTRIES[@]}"; do
            build="${entry%%=*}"
            case "$LK_BUILD_DESC" in
                "$build"*)
                    FULL_IMAGE="${entry#*=}"
                    break
                    ;;
            esac
        done
    fi

    echo -e "${CYAN}Will use payload: $(basename "$FULL_IMAGE")${RESET}"

    if [ ! -f "$FULL_IMAGE" ]; then
        echo -e "${RED}Error: Payload file not found: $FULL_IMAGE${RESET}"
        exit 1
    fi
}

flash_payload() {
    echo -e "${YELLOW}Sending payload, this might take a few attempts...${RESET}"
    local attempt=1
    while true; do
        set +e
        OUTPUT=$(run_with_timeout 8 $FASTBOOT $SPARSE_ARGS flash brick "$FULL_IMAGE" 2>&1)
        EXIT_CODE=$?
        set -e

        if echo "$OUTPUT" | grep -q "eMMC-RO"; then
            echo ""
            echo -e "${RED}eMMC is in permanent read-only mode!${RESET}"
            echo ""
            echo -e "${RED}This device's storage has reached the end of its life and has${RESET}"
            echo -e "${RED}locked itself read-only. Writes report success but never persist,${RESET}"
            echo -e "${RED}so the bootloader cannot be unlocked and nothing can be flashed.${RESET}"
            echo ""

            BOOTS=$(echo "$OUTPUT" | sed -n 's/.*boots=\([0-9][0-9]*\).*/\1/p' | head -n1)
            if [ -n "$BOOTS" ]; then
                echo -e "${YELLOW}For reference, this device has booted $BOOTS times.${RESET}"
                if [ "$BOOTS" -lt 100 ]; then
                    echo -e "${YELLOW}Damn... only $BOOTS boots and the flash already gave out.${RESET}"
                    echo -e "${YELLOW}You must've been seriously unlucky with this one.${RESET}"
                fi
                echo ""
            fi

            echo -e "${RED}This is a hardware failure - the eMMC chip would need to be${RESET}"
            echo -e "${RED}physically replaced. The device was not modified and is safe to${RESET}"
            echo -e "${RED}reboot.${RESET}"
            exit 1
        fi

        if echo "$OUTPUT" | grep -q "Device mismatch"; then
            echo ""
            echo -e "${RED}Device mismatch detected!${RESET}"
            echo ""
            echo -e "${RED}The payload is not compatible with your device. You may be running${RESET}"
            echo -e "${RED}this script on an unsupported device or with the wrong payload.${RESET}"
            echo ""
            echo -e "${RED}Please verify your device and try again with the correct payload.${RESET}"
            exit 1
        fi

        if [ $EXIT_CODE -eq 124 ]; then
            echo -e "${GREEN}Exploit most likely successful!${RESET}"
            return 0
        fi

        echo -e "${YELLOW}Attempt $attempt did not go through (exit $EXIT_CODE): $(echo "$OUTPUT" | tail -n1)${RESET}"
        sleep 2
        attempt=$((attempt + 1))
    done
}

clear
print_banner

echo -e "${CYAN}Host: $HOST_OS, fastboot: $FASTBOOT${RESET}"
echo ""

wait_for_device
check_unlocked
detect_image
detect_sparse_args

echo ""
echo -n "Run amonet-fastbrick to unlock the bootloader? (Type \"YES\" to continue): "
read YES
if [ "$YES" = "YES" ]; then
    echo ""
    flash_payload
    echo ""
    echo -e "${YELLOW}Please wait until the process finishes and DO NOT INTERRUPT IT.${RESET}"
else
    echo ""
    echo -e "${YELLOW}Aborting.${RESET}"
    exit 0
fi

echo ""
echo "Press any key to exit..."
read -n 1 -s
