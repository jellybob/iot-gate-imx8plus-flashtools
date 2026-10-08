#!/usr/bin/env bash
#
# flash_iot_nix_darwin.sh - Flash balenaOS to iot-gate-imx8plus on macOS
#
# Variant of flash_iot_macos.sh that takes its dependencies (uuu, gzip,
# unzip) from the Nix devshell defined in flake.nix instead of Homebrew.
# If uuu isn't on PATH the script re-executes itself inside `nix develop`.
#
# Usage: ./flash_iot_nix_darwin.sh -i <balena-image.img[.gz|.zip]>
#

set -euo pipefail

###############################################################################
# Section 1: Constants & Globals
###############################################################################

readonly NXP_USB_VID="0x1fc9"  # i.MX8M Plus (PID: 0x0146)
readonly DEVICE_DETECT_TIMEOUT=60
readonly DEVICE_DETECT_INTERVAL=2
readonly UBOOT_INIT_WAIT=5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=""
MOUNT_POINT=""
ATTACHED_DISK=""
VERBOSE=0
BALENA_IMAGE=""
CUSTOM_BOOTLOADER=""
UUU_BIN=""

###############################################################################
# Section 2: Cleanup & Signal Handling
###############################################################################

cleanup() {
    log_warn "Cleaning up..."

    # hdiutil detach handles unmounting automatically
    if [[ -n "${ATTACHED_DISK}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
    fi

    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

###############################################################################
# Section 3: Utility Functions
###############################################################################

log_info() {
    echo -e "\033[1;32m[INFO]\033[0m $*" >&2
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

###############################################################################
# Section 4: Root Privilege Check
###############################################################################

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_warn "Root privileges required for USB device access. Re-running with sudo..."
        # sudo resets PATH (secure_path), which would drop the Nix store paths
        exec sudo env "PATH=${PATH}" "$0" "${ORIG_ARGS[@]}"
    fi
}

###############################################################################
# Section 5: Dependency Management
###############################################################################

# All tools come from the devshell in flake.nix. If uuu isn't on PATH and we
# aren't already inside a Nix shell, re-execute inside `nix develop`.
ensure_nix_env() {
    if command -v uuu &>/dev/null; then
        return 0
    fi

    if [[ -n "${IN_NIX_SHELL:-}" ]]; then
        log_error "uuu not found on PATH inside the Nix shell. Check flake.nix."
    fi

    if ! command -v nix &>/dev/null; then
        log_error "nix is required but was not found on PATH."
    fi

    log_info "Entering Nix devshell..."
    exec nix develop "${SCRIPT_DIR}" --command "$0" "${ORIG_ARGS[@]}"
}

check_dependencies() {
    local tool
    for tool in uuu gunzip unzip hdiutil system_profiler; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "Required tool not found on PATH: ${tool}"
        fi
    done

    UUU_BIN="$(command -v uuu)"
    log_info "uuu found at ${UUU_BIN}"
}

###############################################################################
# Section 6: Device Detection
###############################################################################

detect_device() {
    # macOS 26 (Tahoe) renamed the USB profiler datatype to SPUSBHostDataType;
    # earlier macOS versions use SPUSBDataType. Query both for compatibility —
    # system_profiler silently ignores an unknown datatype (exit 0, no output).
    if system_profiler SPUSBHostDataType SPUSBDataType 2>/dev/null \
        | grep -qi "${NXP_USB_VID#0x}"; then
        return 0
    fi
    return 1
}

wait_for_device() {
    if detect_device; then
        log_info "NXP USB device detected."
        return 0
    fi

    echo ""
    log_warn "No NXP USB device detected."
    echo ""
    echo "To put the iot-gate-imx8plus into recovery (serial download) mode:"
    echo "  1. Power OFF the device"
    echo "  2. Connect a micro-USB cable from the PROG port to your Mac"
    echo "  3. Power ON the device"
    echo ""
    read -rp "Press Enter to start scanning for the device (timeout: ${DEVICE_DETECT_TIMEOUT}s)... "

    local elapsed=0
    while [[ ${elapsed} -lt ${DEVICE_DETECT_TIMEOUT} ]]; do
        if detect_device; then
            log_info "NXP USB device detected!"
            return 0
        fi
        printf "\r  Scanning... (%ds / %ds)" "${elapsed}" "${DEVICE_DETECT_TIMEOUT}"
        sleep "${DEVICE_DETECT_INTERVAL}"
        elapsed=$((elapsed + DEVICE_DETECT_INTERVAL))
    done

    echo ""
    log_error "Timed out waiting for NXP USB device. Ensure the device is in recovery mode and connected via the PROG USB port."
}

###############################################################################
# Section 7: Image Handling (macOS-specific)
###############################################################################

decompress_image() {
    local image_path="$1"
    local decompressed=""

    case "${image_path}" in
        *.img.gz)
            log_info "Decompressing gzipped image..."
            decompressed="${TEMP_DIR}/$(basename "${image_path}" .gz)"
            gunzip -k -c "${image_path}" > "${decompressed}"
            ;;
        *.img.zip)
            log_info "Decompressing zipped image..."
            unzip -o "${image_path}" -d "${TEMP_DIR}"
            decompressed="$(find "${TEMP_DIR}" -name '*.img' -maxdepth 1 | head -1)"
            if [[ -z "${decompressed}" ]]; then
                log_error "No .img file found inside zip archive."
            fi
            ;;
        *.img)
            decompressed="${image_path}"
            ;;
        *)
            log_error "Unsupported image format: ${image_path}\nSupported formats: .img, .img.gz, .img.zip"
            ;;
    esac

    echo "${decompressed}"
}

extract_bootloader() {
    local image_path="$1"

    log_info "Attaching image as virtual disk..."

    # Detach any stale attachment of this image from a previous failed run
    local stale_disk
    stale_disk="$(hdiutil info 2>/dev/null | grep -B20 "${image_path}" | grep -oE '/dev/disk[0-9]+' | head -1)" || true
    if [[ -n "${stale_disk}" ]]; then
        log_warn "Image already attached as ${stale_disk} (stale). Detaching..."
        hdiutil detach "${stale_disk}" -force >/dev/null 2>&1 || true
    fi

    # Let macOS attach and auto-mount partitions (like losetup + kpartx on Linux)
    local attach_output
    if ! attach_output=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage \
                          -readonly "${image_path}" 2>&1); then
        log_warn "hdiutil attach failed:"
        echo "${attach_output}" >&2
        log_error "Could not attach disk image. Use -b to provide a bootloader binary manually."
    fi

    # Parse the base disk device for cleanup
    ATTACHED_DISK="$(echo "${attach_output}" | grep -oE '/dev/disk[0-9]+' | head -1)"
    log_info "Image attached as ${ATTACHED_DISK}"
    log_info "Mount output:"
    echo "${attach_output}" >&2

    # Find the auto-mounted boot partition volume
    # hdiutil output shows mount points like: /dev/disk4s1  Windows_FAT_32  /Volumes/resin-boot
    local boot_volume
    boot_volume="$(echo "${attach_output}" | awk -F'\t' '/Volumes/{print $NF}' | head -1)"

    if [[ -z "${boot_volume}" ]]; then
        # Try alternative: look for any mounted volume from this disk
        boot_volume="$(echo "${attach_output}" | grep -oE '/Volumes/[^ ]+' | head -1)"
    fi

    if [[ -z "${boot_volume}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
        ATTACHED_DISK=""
        log_error "No partition was auto-mounted from the image. Use -b to provide a bootloader binary manually."
    fi

    MOUNT_POINT="${boot_volume}"
    log_info "Boot partition mounted at ${MOUNT_POINT}"

    # Find the imx-boot binary
    local boot_binary
    boot_binary="$(find "${MOUNT_POINT}" -name 'imx-boot-*' -o -name 'imx-boot' 2>/dev/null | head -1)"

    if [[ -z "${boot_binary}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
        ATTACHED_DISK=""
        MOUNT_POINT=""
        log_error "Could not find imx-boot binary in boot partition. Use -b to provide one manually."
    fi

    # Copy bootloader to temp dir
    local dest
    dest="${TEMP_DIR}/$(basename "${boot_binary}")"
    cp "${boot_binary}" "${dest}"
    log_info "Extracted bootloader: $(basename "${boot_binary}")"

    # Cleanup: detach handles unmount automatically
    hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
    ATTACHED_DISK=""
    MOUNT_POINT=""

    echo "${dest}"
}

###############################################################################
# Section 8: Flash Execution
###############################################################################

flash_device() {
    local imx_boot_bin="$1"
    local balena_image="$2"
    local verbose_flag=""

    if [[ "${VERBOSE}" -eq 1 ]]; then
        verbose_flag="-v"
    fi

    echo ""
    log_info "========================================="
    log_info "  Starting flash process"
    log_info "========================================="
    echo ""

    # Step 1: Load bootloader via USB (SDPS mode)
    log_info "Step 1/2: Loading bootloader via USB..."
    if ! "${UUU_BIN}" ${verbose_flag} "${imx_boot_bin}"; then
        echo ""
        log_warn "If you see a USB permissions error, you may need to unload the Apple USB HID driver:"
        echo "  sudo kextunload -b com.apple.driver.usb.IOUSBHostHIDDevice"
        echo "  (Re-run this script after unloading)"
        echo ""
        log_error "Failed to load bootloader via USB."
    fi

    # Wait for u-boot to initialize
    log_info "Waiting ${UBOOT_INIT_WAIT}s for U-Boot initialization..."
    sleep "${UBOOT_INIT_WAIT}"

    # Step 2: Flash full image to eMMC
    log_info "Step 2/2: Flashing full image to eMMC (this will take several minutes)..."
    if ! "${UUU_BIN}" ${verbose_flag} -b emmc_all "${imx_boot_bin}" "${balena_image}"; then
        log_error "Failed to flash image to eMMC."
    fi

    echo ""
    log_info "========================================="
    log_info "  Flash completed successfully!"
    log_info "========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Disconnect the micro-USB cable from the PROG port"
    echo "  2. Power cycle the device"
    echo "  3. The device should boot from eMMC into balenaOS"
    echo ""
}

###############################################################################
# Section 9: Main / Argument Parsing
###############################################################################

usage() {
    cat <<'USAGE'
Usage: ./flash_iot_nix_darwin.sh -i <image> [options]

Flash a balenaOS image to the iot-gate-imx8plus via USB on macOS, using
dependencies from the Nix devshell in flake.nix. Re-runs itself under
`nix develop` and sudo as needed.

Required:
  -i <path>         Path to balenaOS image (.img, .img.gz, or .img.zip)

Options:
  -b <path>         Custom imx-boot binary (skips extraction from image)
  -v                Verbose uuu output
  -h, --help        Show this help message

Recovery mode instructions:
  To put the iot-gate-imx8plus into serial download (recovery) mode:
    1. Power OFF the device completely
    2. Connect a micro-USB cable from the PROG port on the device to your Mac
    3. Power ON the device

  The device should appear as an NXP USB device (VID 0x1FC9).

Examples:
  # Flash with automatic bootloader extraction
  ./flash_iot_nix_darwin.sh -i balena-cloud-iot-gate-imx8plus-2.x.x.img.gz

  # Flash with a custom bootloader binary
  ./flash_iot_nix_darwin.sh -i balena.img -b imx-boot-iot-gate-imx8plus
USAGE
}

main() {
    # Save original args before parsing shifts them away
    ORIG_ARGS=("$@")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i)
                shift
                BALENA_IMAGE="${1:-}"
                [[ -z "${BALENA_IMAGE}" ]] && log_error "Missing argument for -i"
                ;;
            -b)
                shift
                CUSTOM_BOOTLOADER="${1:-}"
                [[ -z "${CUSTOM_BOOTLOADER}" ]] && log_error "Missing argument for -b"
                ;;
            -v)
                VERBOSE=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1\nRun with -h for usage."
                ;;
        esac
        shift
    done

    # Validate image argument
    if [[ -z "${BALENA_IMAGE}" ]]; then
        log_error "No image specified. Use -i <path> to provide a balenaOS image.\nRun with -h for usage."
    fi

    if [[ ! -f "${BALENA_IMAGE}" ]]; then
        log_error "Image file not found: ${BALENA_IMAGE}"
    fi

    # Enter the Nix devshell as the invoking user (not root) so the Nix
    # store/eval cache isn't touched by root
    ensure_nix_env

    # Ensure root for USB access (before allocating temp resources so
    # exec sudo doesn't leak a temp dir from the non-root process)
    ensure_root

    # Create temp directory (after privilege escalation)
    TEMP_DIR="$(mktemp -d -t flash_iot_nix_darwin.XXXXXX)"

    check_dependencies

    # Validate/resolve image path to absolute
    BALENA_IMAGE="$(cd "$(dirname "${BALENA_IMAGE}")" && pwd)/$(basename "${BALENA_IMAGE}")"

    # Decompress if needed
    local working_image
    working_image="$(decompress_image "${BALENA_IMAGE}")"

    # Detect device
    wait_for_device

    # Get bootloader
    local imx_boot_bin
    if [[ -n "${CUSTOM_BOOTLOADER}" ]]; then
        if [[ ! -f "${CUSTOM_BOOTLOADER}" ]]; then
            log_error "Custom bootloader not found: ${CUSTOM_BOOTLOADER}"
        fi
        imx_boot_bin="${CUSTOM_BOOTLOADER}"
        log_info "Using custom bootloader: ${imx_boot_bin}"
    else
        imx_boot_bin="$(extract_bootloader "${working_image}")"
        if [[ -z "${imx_boot_bin}" ]]; then
            log_error "Failed to extract bootloader from image."
        fi
    fi

    # Flash
    flash_device "${imx_boot_bin}" "${working_image}"
}

main "$@"
