#!/usr/bin/env bash
#
# Part 2 of 3: Build the rootfs and unpack/verify Firecracker.
#
# Assumes part 1 has already run and the following exist in the current dir:
#   - aws-lambda-base-images/        (or aws_baseimage.ext4 already built)
#   - firecracker-<version>-<arch>.tgz
#   - firecracker-<version>-<arch>.tgz.sha256.txt
#   - /tmp/busybox
#   - build.env                      (written by part 1)
#
# Produces:
#   - aws_baseimage.ext4             (1G ext4 image with bootstrap wrapper injected)
#   - release-<version>-<arch>/      (extracted Firecracker archive)
#   - ./firecracker, ./jailer        (renamed binaries in current dir)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.env"

# ─── Build AWS Lambda base image rootfs ──────────────────────────────────────
if [[ -f "aws_baseimage.ext4" ]]; then
  echo "Skipping rootfs build, already exists: aws_baseimage.ext4"
else
  echo "Building AWS Lambda base image rootfs..."

  # Extract all tar.xz layers into staging directory
  if [[ ! -d "lambda-rootfs" ]]; then
    mkdir -p lambda-rootfs
    for tarfile in aws-lambda-base-images/x86_64/*.tar.xz; do
      echo "Extracting layer: $tarfile"
      sudo tar -xf "$tarfile" -C lambda-rootfs
    done
  fi

  # Clean up cloned repo to free space before image creation
  echo "Cleaning up source files..."
  rm -rf aws-lambda-base-images

  # Create ext4 filesystem image
  echo "Creating ext4 image..."
  sudo chown -R root:root lambda-rootfs
  truncate -s 1G aws_baseimage.ext4
  sudo mkfs.ext4 -d lambda-rootfs -F aws_baseimage.ext4

  # Clean up extracted rootfs
  echo "Cleaning up extracted rootfs..."
  sudo rm -rf lambda-rootfs

  # Inject bootstrap wrapper into rootfs (single mount operation)
  echo "Injecting bootstrap wrapper into rootfs..."
  MOUNT_DIR="$(mktemp -d)"
  sudo mount -o loop aws_baseimage.ext4 "$MOUNT_DIR"

  # Mount doesn't exist on AWS Linux; need it to mount task dir
  sudo cp /tmp/busybox "$MOUNT_DIR/usr/bin/busybox"
  sudo chmod +x "$MOUNT_DIR/usr/bin/busybox"

  # Ensure /var/task exists as a mount point
  sudo mkdir -p "$MOUNT_DIR/var/task"

  # Move the real bootstrap aside
  sudo mv "$MOUNT_DIR/var/runtime/bootstrap" "$MOUNT_DIR/var/runtime/bootstrap.real"
  sudo sed -i 's|RUNTIME_ENTRYPOINT=/var/runtime/bootstrap|RUNTIME_ENTRYPOINT=/var/runtime/bootstrap.real|' \
    "$MOUNT_DIR/lambda-entrypoint.sh"

  # Write wrapper: mounts pseudo-fs, sets env, mounts function drive, starts RIE
  sudo tee "$MOUNT_DIR/var/runtime/bootstrap" > /dev/null << 'WRAPPER'
#!/bin/bash

# ── Pseudo-filesystems ──
# /proc must come first (needed for /proc/cmdline)
/usr/bin/busybox mount -t proc proc /proc
/usr/bin/busybox mount -t sysfs sysfs /sys

# devtmpfs may already be mounted by the kernel; remount to ensure /dev is populated
/usr/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null

# Initialize commandline values
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
# ── Mount function drive ──
mkdir -p /var/task
/usr/bin/busybox mount /dev/vdb /var/task
if [ $? -eq 0 ]; then
    echo "Mounted /dev/vdb at /var/task"
else
    echo "ERROR: Failed to mount /dev/vdb at /var/task"
    echo "Available block devices:"
    ls -la /dev/vd* /dev/sd* /dev/xvd* 2>/dev/null
fi

# ── Configure guest network ──
/usr/bin/busybox ip link set lo up
/usr/bin/busybox ip addr add 172.16.0.2/30 dev eth0
/usr/bin/busybox ip link set eth0 up
/usr/bin/busybox ip route add default via 172.16.0.1 dev eth0
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "Guest network configured: 172.16.0.2/30 via 172.16.0.1"

# ── Parse handler from kernel cmdline ──
HANDLER=$(grep -oP 'handler=\K\S+' /proc/cmdline || echo "function.handler")
echo "Handler: $HANDLER"

# ── Hand off to Lambda entrypoint ──
exec /lambda-entrypoint.sh "$HANDLER"
WRAPPER
  sudo chmod +x "$MOUNT_DIR/var/runtime/bootstrap"

  sudo umount "$MOUNT_DIR"
  rmdir "$MOUNT_DIR"
  echo "Bootstrap wrapper injected."

  echo "Done: aws_baseimage.ext4"
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

  # Verify SHA256 checksum
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

  # Extract archive
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