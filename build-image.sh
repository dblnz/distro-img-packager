#!/usr/bin/env bash
set -euo pipefail
trap 'exit 130' INT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/../imgbuild"

KERNEL_VERSION="${KERNEL_VERSION:-7.0.4}"
KERNEL_SRC="${KERNEL_SRC:-${WORKSPACE}/linux}"
KERNEL_CONFIG="${KERNEL_CONFIG:-${SCRIPT_DIR}/test-kernel-extra.config}"
KERNEL_CONFIG_EXTRA="${KERNEL_CONFIG_EXTRA:-$(
    cat <<'KCONF'
# CONFIG_EFI_SBAT_FILE is not set
# CONFIG_DEBUG_INFO is not set
CONFIG_XFS_FS=y
KCONF
)}"
CUSTOM_LABEL="${CUSTOM_LABEL:-}"
LOCALVERSION_LABEL="${LOCALVERSION_LABEL:-$(whoami)}"
OUTPUT_NAME="${OUTPUT_NAME:-image}"
MKOSI_REF="${MKOSI_REF:-9a28ad20bbea61894ea7b971d318a71f4374cf3b}"
KERNEL_INSTALL_DIR="${WORKSPACE}/kernel-install"

usage() {
    cat <<EOF
Usage: $0 [step...]

Steps:
  kernel    Build the kernel (bzImage + modules)
  install   Install kernel to staging directory
  image     Build the disk image (mkosi)
  convert   Resize and convert raw image to VHD
  verify    Boot the image in QEMU and check kernel version
  all       Run all steps (default)

Workspace: $WORKSPACE
Kernel source: $KERNEL_SRC (cloned from kernel.org v$KERNEL_VERSION if missing)

Override defaults with environment variables:
  KERNEL_SRC, KERNEL_VERSION, KERNEL_CONFIG, KERNEL_CONFIG_EXTRA,
  CUSTOM_LABEL, LOCALVERSION_LABEL, OUTPUT_NAME
EOF
    exit 1
}

install_deps() {
    echo "==> Installing build dependencies"
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        gcc make flex bison libssl-dev libelf-dev bc perl diffutils git ccache \
        dnf rpm qemu-utils jq distribution-gpg-keys genisoimage
}

ensure_kernel_src() {
    if [[ -f "$KERNEL_SRC/Makefile" ]]; then
        echo "==> Using existing kernel source at $KERNEL_SRC"
        return
    fi
    echo "==> Cloning kernel v$KERNEL_VERSION to $KERNEL_SRC"
    git clone --depth 1 --branch "v${KERNEL_VERSION}" \
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" "$KERNEL_SRC"
}

build_kernel() {
    ensure_kernel_src
    echo "==> Building kernel from $KERNEL_SRC"
    pushd "$KERNEL_SRC" >/dev/null

    make defconfig

    if [[ -n "$KERNEL_CONFIG" && -f "$KERNEL_CONFIG" ]]; then
        echo "    Merging config fragment: $KERNEL_CONFIG"
        scripts/kconfig/merge_config.sh -m .config "$KERNEL_CONFIG"
    fi

    if [[ -n "$KERNEL_CONFIG_EXTRA" ]]; then
        echo "    Merging inline config options"
        INLINE_FRAGMENT=$(mktemp)
        printf '%s\n' "$KERNEL_CONFIG_EXTRA" >"$INLINE_FRAGMENT"
        scripts/kconfig/merge_config.sh -m .config "$INLINE_FRAGMENT"
        rm -f "$INLINE_FRAGMENT"
    fi

    make olddefconfig

    COMMIT_SHORT="$(git -C "$SCRIPT_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
    LABEL_PARTS="$LOCALVERSION_LABEL"
    if [[ -n "$CUSTOM_LABEL" ]]; then
        LABEL_PARTS="${LABEL_PARTS}-${CUSTOM_LABEL}"
    fi
    LOCALVERSION="-${LABEL_PARTS}-${COMMIT_SHORT}"
    scripts/config --set-str CONFIG_LOCALVERSION "$LOCALVERSION"
    make olddefconfig

    export KBUILD_BUILD_TIMESTAMP=""
    make CC="ccache gcc" bzImage -j"$(nproc)"
    make CC="ccache gcc" modules -j"$(nproc)"

    popd >/dev/null
    echo "==> Kernel build complete"
}

install_kernel() {
    echo "==> Installing kernel to $KERNEL_INSTALL_DIR"
    pushd "$KERNEL_SRC" >/dev/null

    rm -rf "$KERNEL_INSTALL_DIR"
    mkdir -p "$KERNEL_INSTALL_DIR"
    make modules_install INSTALL_MOD_PATH="$KERNEL_INSTALL_DIR"
    make install INSTALL_PATH="$KERNEL_INSTALL_DIR/boot" INSTALLKERNEL=no

    popd >/dev/null

    KVER=$(basename "$(ls -d "$KERNEL_INSTALL_DIR/lib/modules/"*/)")
    echo "==> Kernel version: $KVER"
}

build_image() {
    echo "==> Building disk image"

    if ! command -v uv &>/dev/null && [[ ! -x "$HOME/.local/bin/uv" ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    UV="${HOME}/.local/bin/uv"

    cp -a "$SCRIPT_DIR/conf"/. "$WORKSPACE/"

    pushd "$WORKSPACE" >/dev/null
    $UV tool run \
        --from "git+https://github.com/systemd/mkosi.git#${MKOSI_REF}" \
        mkosi --force --build-sources="$KERNEL_INSTALL_DIR:/kernel-install"
    popd >/dev/null

    echo "==> Raw image ready: $WORKSPACE/image.raw"
}

convert_image() {
    echo "==> Converting raw image to VHD"
    pushd "$WORKSPACE" >/dev/null

    RAW_IMAGE="image.raw" bash "$SCRIPT_DIR/resize.sh"

    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc \
        image.raw \
        "${OUTPUT_NAME}.vhd"

    popd >/dev/null
    echo "==> VHD ready: $WORKSPACE/${OUTPUT_NAME}.vhd"
}

verify_image() {
    echo "==> Booting image in QEMU to verify kernel version"
    SERIAL_LOG=$(mktemp)
    OVMF_VARS=$(mktemp)
    BOOT_IMAGE=$(mktemp)

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
        if [[ -f "$f" ]]; then
            OVMF_CODE="$f"
            break
        fi
    done
    for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
        if [[ -f "$f" ]]; then
            cp "$f" "$OVMF_VARS"
            break
        fi
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "ERROR: OVMF firmware not found"
        exit 1
    fi

    # Create cloud-init NoCloud seed ISO with a test user
    SEED_DIR=$(mktemp -d)
    SEED_ISO=$(mktemp --suffix=.iso)
    cat > "$SEED_DIR/meta-data" <<EOF
instance-id: test-boot
local-hostname: test-vm
EOF
    cat > "$SEED_DIR/user-data" <<'EOF'
#cloud-config
users:
  - name: testuser
    plain_text_passwd: testpass
    lock_passwd: false
    shell: /bin/bash
runcmd:
  - echo "UNAME_OUTPUT=$(uname -r)" > /dev/ttyS0
  - poweroff
EOF
    genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
        "$SEED_DIR/user-data" "$SEED_DIR/meta-data" 2>/dev/null
    rm -rf "$SEED_DIR"

    # Copy raw image to avoid modifying the build output
    cp "$WORKSPACE/image.raw" "$BOOT_IMAGE"

    COMMIT_SHORT="$(git -C "$SCRIPT_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
    LABEL_PARTS="$LOCALVERSION_LABEL"
    if [[ -n "$CUSTOM_LABEL" ]]; then
        LABEL_PARTS="${LABEL_PARTS}-${CUSTOM_LABEL}"
    fi
    EXPECTED_KVER="${KERNEL_VERSION}-${LABEL_PARTS}-${COMMIT_SHORT}"

    timeout 120 qemu-system-x86_64 \
        -machine q35 \
        -m 2048 \
        -display none \
        -monitor none \
        -serial file:"$SERIAL_LOG" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$BOOT_IMAGE",format=raw,if=virtio \
        -drive file="$SEED_ISO",format=raw,if=virtio \
        -enable-kvm \
        -cpu host \
        -no-reboot &
    QEMU_PID=$!

    for i in $(seq 1 60); do
        if grep -q "UNAME_OUTPUT=" "$SERIAL_LOG" 2>/dev/null; then
            echo "    cloud-init completed after ~$((i * 2))s"
            break
        fi
        sleep 2
    done

    sleep 5
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true

    echo "=== Serial console output ==="
    cat "$SERIAL_LOG"
    echo "=== End serial console output ==="

    BOOT_OK=true
    if ! grep -q "Linux version ${EXPECTED_KVER}" "$SERIAL_LOG"; then
        echo "==> ❌ Expected kernel version ${EXPECTED_KVER} not found in boot log"
        BOOT_OK=false
    fi

    if ! grep -q "UNAME_OUTPUT=${EXPECTED_KVER}" "$SERIAL_LOG"; then
        echo "==> ❌ uname -r did not report expected version ${EXPECTED_KVER}"
        BOOT_OK=false
    fi

    if grep -q "Freezing execution" "$SERIAL_LOG"; then
        echo "==> ❌ systemd failed to initialize (Freezing execution detected)"
        BOOT_OK=false
    fi

    if grep -q "Failed to allocate manager object" "$SERIAL_LOG"; then
        echo "==> ❌ systemd failed to allocate manager object"
        BOOT_OK=false
    fi

    if [[ "$BOOT_OK" == "true" ]]; then
        echo "==> ✅ Kernel version ${EXPECTED_KVER} confirmed via uname -r, system booted successfully"
    else
        rm -f "$SERIAL_LOG" "$OVMF_VARS" "$BOOT_IMAGE" "$SEED_ISO"
        exit 1
    fi

    rm -f "$SERIAL_LOG" "$OVMF_VARS" "$BOOT_IMAGE" "$SEED_ISO"
}

# --- Main ---
mkdir -p "$WORKSPACE"

[[ $# -eq 0 ]] && set -- all

for step in "$@"; do
    case "$step" in
    kernel)
        install_deps
        build_kernel
        ;;
    install) install_kernel ;;
    image) build_image ;;
    convert) convert_image ;;
    verify) verify_image ;;
    all)
        install_deps
        build_kernel
        install_kernel
        build_image
        convert_image
        verify_image
        ;;
    -h | --help) usage ;;
    *)
        echo "Unknown step: $step"
        usage
        ;;
    esac
done
