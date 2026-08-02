#!/usr/bin/env bash
#
# Part 2 of 3: Build the rootfs and unpack/verify Firecracker.
#
# Assumes part 1 has already run and the following exist in the current dir:
#   - aws-lambda-base-images/        (or aws_baseimage.ext4 already built)
#   - firecracker-<version>-<arch>.tgz
#   - firecracker-<version>-<arch>.tgz.sha256.txt
#   - tmp/busybox
#   - build.env                      (written by part 1)
#
# Produces:
#   - aws_baseimage.ext4             (1.5G ext4 image with bootstrap wrapper injected
#                                     and guest-requirements.txt deps vendored in)
#   - release-<version>-<arch>/      (extracted Firecracker archive)
#   - ./firecracker, ./jailer        (renamed binaries in current dir)
#
# Every stage is skipped if its output already exists, so the script is safe to
# re-run; delete the artefact to force a rebuild.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.env"

# ─── Static OpenSSL binary ───────────────────────────────────────────────────
# The chacha20 benchmark shells out to openssl in the guest, which has none. 
# Necessary for benchmarking functions
if [[ -f "$OPENSSL_BIN" ]]; then
  echo "Static OpenSSL binary already built at $OPENSSL_BIN, skipping..."
else
  echo "Building static OpenSSL binary..."
  if [[ ! -f "$OPENSSL_TARBALL" ]]; then
    curl -L -o "$OPENSSL_TARBALL" "$OPENSSL_URL"
  else
    echo "Source tarball already exists: $OPENSSL_TARBALL, skipping download..."
  fi
  # --strip-components drops the top-level openssl-3.5.7/ so the build dir is
  # exactly $OPENSSL_SRC_DIR.
  if [[ ! -d "$OPENSSL_SRC_DIR" ]]; then
    mkdir -p "$OPENSSL_SRC_DIR"
    tar xzf "$OPENSSL_TARBALL" -C "$OPENSSL_SRC_DIR" --strip-components=1
  else
    echo "Source directory already exists: $OPENSSL_SRC_DIR, skipping extraction..."
  fi
  # Subshell so the cd doesn't leak into the rest of the script.
  (
    cd "$OPENSSL_SRC_DIR"
    ./Configure no-shared no-dso -static linux-x86_64
    make -j"$(nproc)"
  )
  echo "Static OpenSSL binary built at: $OPENSSL_BIN"
fi

# ─── Build AWS Lambda base image rootfs ──────────────────────────────────────
if [[ -f "$ROOTFS_IMAGE" ]]; then
  echo "Skipping rootfs build, already exists: $ROOTFS_IMAGE"
else
  echo "Building AWS Lambda base image rootfs..."

  IMG_PARTIAL="${ROOTFS_IMAGE}.partial"
  MOUNT_DIR=""
  cleanup_rootfs_build() {
    [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] && {
      sudo umount "$MOUNT_DIR" 2>/dev/null || true
      sudo rmdir "$MOUNT_DIR" 2>/dev/null || true
    }
    [[ -f "$IMG_PARTIAL" ]] && sudo rm -f "$IMG_PARTIAL"
  }
  trap cleanup_rootfs_build EXIT

  if [[ ! -d "lambda-rootfs" ]]; then
    mkdir -p lambda-rootfs
    for tarfile in aws-lambda-base-images/x86_64/*.tar.xz; do
      echo "Extracting layer: $tarfile"
      sudo tar -xf "$tarfile" -C lambda-rootfs
    done
  fi

  echo "Cleaning up source files..."
  sudo rm -rf aws-lambda-base-images

  echo "Creating ext4 image..."
  sudo chown -R root:root lambda-rootfs
  # 1.5G leaves headroom for the vendored guest deps (igraph + bundled libs).
  sudo truncate -s 1536M "$IMG_PARTIAL"
  sudo mkfs.ext4 -d lambda-rootfs -F "$IMG_PARTIAL"

  echo "Cleaning up extracted rootfs..."
  sudo rm -rf lambda-rootfs

  # Everything below happens under a single loop mount, held until the deps are
  # vendored in.
  echo "Injecting bootstrap wrapper into rootfs..."
  MOUNT_DIR="$(mktemp -d)"
  sudo mount -o loop "$IMG_PARTIAL" "$MOUNT_DIR"

  # The AWS base image ships neither mount(8) (needed for the drives the wrapper
  # mounts) nor openssl (needed by the chacha20 benchmark).
  sudo cp "$BUSYBOX_PATH" "$MOUNT_DIR/usr/bin/busybox"
  sudo chmod +x "$MOUNT_DIR/usr/bin/busybox"
  sudo cp "$OPENSSL_BIN" "$MOUNT_DIR/usr/bin/openssl"
  sudo chmod +x "$MOUNT_DIR/usr/bin/openssl"
  sudo mkdir -p "$MOUNT_DIR/var/task"

  # Baked in at build time rather than written at boot: the nameserver is
  # constant (only guest IP/gateway vary, and those come from the kernel
  # cmdline), and this way the rootfs can be mounted read-only.
  echo "nameserver 8.8.8.8" | sudo tee "$MOUNT_DIR/etc/resolv.conf" >/dev/null

  # ─── Guest bootstrap wrapper ───────────────────────────────────────────────
  # The wrapper takes over /var/runtime/bootstrap as the guest's PID 1; the
  # image's own bootstrap moves aside to bootstrap.real, and lambda-entrypoint
  # is repointed at it so the wrapper can hand off once the guest is set up.
  sudo mv "$MOUNT_DIR/var/runtime/bootstrap" "$MOUNT_DIR/var/runtime/bootstrap.real"
  sudo sed -i 's|RUNTIME_ENTRYPOINT=/var/runtime/bootstrap|RUNTIME_ENTRYPOINT=/var/runtime/bootstrap.real|' \
    "$MOUNT_DIR/lambda-entrypoint.sh"

  sudo tee "$MOUNT_DIR/var/runtime/bootstrap" >/dev/null <<'WRAPPER'
#!/bin/bash
# Guest PID 1. Does the work Docker would normally do for a Lambda image --
# pseudo-filesystems, environment, drives, network -- then execs the real Lambda
# entrypoint.
#
# The rootfs and the function drive are shared read-only by every concurrent
# microVM, so nothing here may write outside /tmp, which is this instance's own
# scratch drive. Per-VM values (IP, gateway, memory, handler) arrive on the
# kernel cmdline, written per instance by run_firecracker.sh.
#
# As PID 1 this inherits /dev/console, so everything echoed below lands in that
# instance's console log on the host.

# ── Pseudo-filesystems ──
# /proc first: everything after it reads /proc/cmdline.
/usr/bin/busybox mount -t proc proc /proc
/usr/bin/busybox mount -t sysfs sysfs /sys

# devtmpfs may already be mounted by the kernel; remount to ensure /dev is populated
/usr/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

MEM_SIZE=$(grep -oP 'func_mem_size=\K\S+' /proc/cmdline || echo "128")
TIMEOUT=$(grep -oP 'func_timeout=\K\S+' /proc/cmdline || echo "300")

# ── Environment (normally set by Docker ENV) ──
export LANG=en_US.UTF-8
export TZ=:/etc/localtime
export PATH=/var/lang/bin:/usr/local/bin:/usr/bin:/bin:/opt/bin
export LD_LIBRARY_PATH=/var/lang/lib:/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib:/opt/lib
export LAMBDA_TASK_ROOT=/var/task
export LAMBDA_RUNTIME_DIR=/var/runtime
export AWS_LAMBDA_FUNCTION_TIMEOUT=$TIMEOUT
export AWS_LAMBDA_FUNCTION_MEMORY_SIZE=$MEM_SIZE
export CONFIG_VIRT_CPU_ACCOUNTING_GEN=y
export CONFIG_IRQ_TIME_ACCOUNTING=y
# __pycache__ writes next to modules would hit EROFS. Harmless, but each is a
# wasted open() per import and forces a recompile every cold start -- noise in
# the power measurement.
export PYTHONDONTWRITEBYTECODE=1

# ── Drives ──
# /var/task read-only (shared, and read-only on real Lambda anyway); /tmp is the
# only writable path in the guest, and must be mounted before the RIE starts so
# the runtime and the handler both see it.
mkdir -p /var/task
/usr/bin/busybox mount -o ro /dev/vdb /var/task
if [ $? -eq 0 ]; then
    echo "Mounted /dev/vdb at /var/task (ro)"
else
    echo "ERROR: Failed to mount /dev/vdb at /var/task"
    echo "Available block devices:"
    ls -la /dev/vd* /dev/sd* /dev/xvd* 2>/dev/null
fi

/usr/bin/busybox mount /dev/vdc /tmp
if [ $? -eq 0 ]; then
    echo "Mounted /dev/vdc at /tmp (rw)"
else
    echo "ERROR: Failed to mount /dev/vdc at /tmp -- /tmp writes will fail (read-only root)"
    ls -la /dev/vd* 2>/dev/null
fi

# ── Network ──
# Defaults reproduce the original single-VM addressing.
GUEST_IP=$(grep -oP 'guest_ip=\K\S+' /proc/cmdline || echo "172.16.0.2")
GATEWAY=$(grep -oP 'gateway=\K\S+' /proc/cmdline || echo "172.16.0.1")
/usr/bin/busybox ip link set lo up
/usr/bin/busybox ip addr add "$GUEST_IP/30" dev eth0
/usr/bin/busybox ip link set eth0 up
/usr/bin/busybox ip route add default via "$GATEWAY" dev eth0
echo "Guest network configured: $GUEST_IP/30 via $GATEWAY"

HANDLER=$(grep -oP 'handler=\K\S+' /proc/cmdline || echo "function.handler")
echo "Handler: $HANDLER"

exec /lambda-entrypoint.sh "$HANDLER"
WRAPPER
  sudo chmod +x "$MOUNT_DIR/var/runtime/bootstrap"

  # ─── Vendor guest Python deps into the rootfs ──────────────────────────────
  # Installed with the image's OWN pip under chroot, so the wheels match the
  # guest exactly (cp310 / manylinux2014 / x86_64). They land in the guest's 
  # site-packages and are importable by any function (e.g. igraph for sebs_502).
  GUEST_REQS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guest-requirements.txt"
  if [[ -s "$GUEST_REQS" ]]; then
    if [[ -x "$MOUNT_DIR/var/lang/bin/pip" ]]; then
      echo "Installing guest Python deps via the image's own pip (chroot)..."
      sudo cp "$GUEST_REQS" "$MOUNT_DIR/tmp/guest-requirements.txt"
      # pip needs DNS + /dev/urandom + /proc inside the chroot.
      [[ -s "$MOUNT_DIR/etc/resolv.conf" ]] ||
        echo "nameserver 8.8.8.8" | sudo tee "$MOUNT_DIR/etc/resolv.conf" >/dev/null
      sudo mount --bind /dev "$MOUNT_DIR/dev"
      sudo mount --bind /proc "$MOUNT_DIR/proc"
      sudo mount --bind /sys "$MOUNT_DIR/sys"
      pip_rc=0
      sudo chroot "$MOUNT_DIR" /var/lang/bin/pip install \
        --no-cache-dir --no-input --disable-pip-version-check \
        --only-binary=:all: \
        -r /tmp/guest-requirements.txt || pip_rc=$?
      # Unbind before the rootfs umount, even on failure, or it stays busy.
      sudo umount "$MOUNT_DIR/sys" || true
      sudo umount "$MOUNT_DIR/proc" || true
      sudo umount "$MOUNT_DIR/dev" || true
      sudo rm -f "$MOUNT_DIR/tmp/guest-requirements.txt"
      ((pip_rc == 0)) || {
        echo "ERROR: guest pip install failed (rc=$pip_rc)" >&2
        exit 1
      }
      echo "Guest deps installed: $(tr '\n' ' ' <"$GUEST_REQS")"
    else
      echo "WARNING: /var/lang/bin/pip not found in rootfs -- skipping guest deps." >&2
    fi
  fi

  sudo umount "$MOUNT_DIR"
  sudo rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
  echo "Bootstrap wrapper injected."

  sudo mv "$IMG_PARTIAL" "$ROOTFS_IMAGE"
  trap - EXIT
  echo "Done: $ROOTFS_IMAGE"
fi

# ─── Verify and extract Firecracker archive ──────────────────────────────────
ARCHIVE="firecracker-${LATEST_VERSION}-${ARCH}.tgz"
SHA256="${ARCHIVE}.sha256.txt"
folder="release-${LATEST_VERSION}-${ARCH}"
if [[ ! -f "firecracker" ]]; then
  if [[ ! -f "$ARCHIVE" ]]; then
    echo "Error: Firecracker archive not found: $ARCHIVE" >&2
    echo "Did part 1 run successfully?" >&2
    exit 1
  fi

  if [[ ! -f "$SHA256" ]]; then
    echo "Error: SHA256 file not found: $SHA256" >&2
    exit 1
  fi

  echo "Verifying SHA256 checksum..."
  if command -v sha256sum &>/dev/null; then
    EXPECTED="$(awk '{print $1}' "$SHA256")"
    ACTUAL="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  elif command -v shasum &>/dev/null; then
    EXPECTED="$(awk '{print $1}' "$SHA256")"
    ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  else
    echo "Error: No SHA256 utility found (sha256sum or shasum required)." >&2
    exit 1
  fi

  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "Error: SHA256 mismatch!" >&2
    echo "  Expected: $EXPECTED" >&2
    echo "  Actual:   $ACTUAL" >&2
    exit 1
  fi
  echo "SHA256 verified successfully."

  if [[ -d "$folder" ]]; then
    echo "Skipping extraction, directory '$folder' already exists."
  else
    echo "Extracting $ARCHIVE..."
    tar -xzf "$ARCHIVE"
    echo "Done."
  fi
else
  echo "Firecracker binary found, skipping..."
fi

# ─── Rename binaries to bare 'firecracker' and 'jailer' ──────────────────────
if [[ -f "firecracker" ]]; then
  echo "Skipping firecracker binary rename, 'firecracker' already exists."
else
  mv "${folder}/firecracker-${LATEST_VERSION}-${ARCH}" firecracker
  echo "firecracker binary renamed to 'firecracker'"
fi

if [[ -f "jailer" ]]; then
  echo "Skipping jailer binary rename, 'jailer' already exists."
else
  mv "${folder}/jailer-${LATEST_VERSION}-${ARCH}" jailer
  echo "jailer binary renamed to 'jailer'"
fi

echo
echo "Build stage complete."

# ─── Host networking and function drive ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo
echo "Setting up host TAP interface and NAT..."
"${SCRIPT_DIR}/function_scripts/setup_tap.sh"

echo
echo "Building function drive..."
"${SCRIPT_DIR}/function_scripts/build_function.sh"
