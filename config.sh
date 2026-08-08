# ─── Firecracker release ─────────────────────────────────────────────────────
# Base URL for Firecracker GitHub releases. The scripts append /latest,
# /download/<version>/..., etc.
RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
 
# ─── Kernel (Firecracker CI artifacts on S3) ─────────────────────────────────
# Bucket listing endpoint (used to discover the latest vmlinux-* key).
KERNEL_S3_BUCKET_URL="http://spec.ccfc.min.s3.amazonaws.com"
# Download base for fetching a specific kernel key.
KERNEL_DOWNLOAD_BASE="https://s3.amazonaws.com/spec.ccfc.min"
 
# ─── AWS Lambda base image source ────────────────────────────────────────────
LAMBDA_REPO_URL="https://github.com/aws/aws-lambda-base-images.git"
LAMBDA_REPO_BRANCH="python3.10"
LAMBDA_REPO_ARCH_DIR="x86_64"
LAMBDA_API_URL="https://api.github.com/repos/aws/aws-lambda-base-images"
 
# ─── Local scratch dir (git-ignored) ─────────────────────────────────────────
# Downloads that aren't part of the repo but should live next to it rather than
# in the system /tmp (which gets cleared between reboots).
TMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmp"

# ─── busybox (injected into the guest rootfs) ────────────────────────────────
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
BUSYBOX_PATH="${TMP_DIR}/busybox"

# ─── Vendored static binaries ────────────────────────────────────────────────
# Prebuilt, fully statically-linked x86_64 Linux binaries checked into
# static_build/ (see docs/static_binaries.md for how/why they were built).
# The AWS Lambda base rootfs ships none of these; install_build.sh copies them
# straight into the guest at boot-strap-injection time instead of building
# from source on every install (openssl/sysbench/fio all take several minutes
# to compile, and none publish an official static binary release).
STATIC_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/static_build"
OPENSSL_BIN="${STATIC_BUILD_DIR}/openssl"   # function/benchmark/chacha20.py
SYSBENCH_BIN="${STATIC_BUILD_DIR}/sysbench" # prime_number.py, thread.py
FIO_BIN="${STATIC_BUILD_DIR}/fio"           # readdisk.py

# ─── Output filenames ────────────────────────────────────────────────────────
# The final rootfs image produced by part 2 and verified by part 3.
ROOTFS_IMAGE="aws_baseimage.ext4"