#!/usr/bin/env bash
#
# Part 1 of 3: Download all required files.
#
# Downloads:
#   - Latest Firecracker CI kernel (vmlinux-*)
#   - AWS Lambda base image source repo (via git-lfs)
#   - Firecracker release archive + SHA256 checksum file
#   - busybox static binary (used later when injecting the bootstrap wrapper)
#
# Outputs (in current directory):
#   - vmlinux-<version>
#   - aws-lambda-base-images/        (cloned repo with LFS objects pulled)
#   - firecracker-<version>-<arch>.tgz
#   - firecracker-<version>-<arch>.tgz.sha256.txt
#   - /tmp/busybox
#
# Also writes ./build.env with the resolved version/arch values so that
# parts 2 and 3 don't have to re-discover them.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

ARCH="$(uname -m)"

LATEST_VERSION=$(basename $(curl -fsSLI -o /dev/null -w  %{url_effective} ${RELEASE_URL}/latest))
CI_VERSION=${LATEST_VERSION%.*}

# ─── Kernel ──────────────────────────────────────────────────────────────────
latest_kernel_key=$(curl "${KERNEL_S3_BUCKET_URL}/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

KERNEL_FILENAME=$(basename $latest_kernel_key)

if [[ -f "$KERNEL_FILENAME" ]]; then
  echo "Skipping kernel download, already exists: $KERNEL_FILENAME"
else
  echo "Downloading kernel: $KERNEL_FILENAME"
  wget "${KERNEL_DOWNLOAD_BASE}/${latest_kernel_key}"
fi

# ─── AWS Lambda base image source ────────────────────────────────────────────
# We just download here; extraction + image creation happens in part 2.
if [[ -f "$ROOTFS_IMAGE" ]]; then
  echo "Skipping Lambda base image download, $ROOTFS_IMAGE already exists."
elif [[ -d "aws-lambda-base-images" ]]; then
  echo "Skipping Lambda base image clone, aws-lambda-base-images/ already exists."
else
  echo "Downloading AWS Lambda base image source..."

  # Ensure git-lfs is installed
  if ! command -v git-lfs &>/dev/null; then
    echo "Installing git-lfs..."
    sudo apt-get install -y git-lfs
  fi
  git lfs install

  git clone --branch "$LAMBDA_REPO_BRANCH" --single-branch "$LAMBDA_REPO_URL"

  echo "Pulling LFS objects..."
  git -C aws-lambda-base-images lfs pull

  # Verify the tar files are real (not LFS pointers); fall back to GitHub API if not
  for tarfile in aws-lambda-base-images/${LAMBDA_REPO_ARCH_DIR}/*.tar.xz; do
    if file "$tarfile" | grep -q "ASCII text"; then
      echo "LFS pull failed for $tarfile, falling back to GitHub API download..."

      filename=$(basename "$tarfile")
      curl -L \
        -H "Accept: application/vnd.github.v3.raw" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        -o "$tarfile" \
        "${LAMBDA_API_URL}/contents/${LAMBDA_REPO_ARCH_DIR}/${filename}?ref=${LAMBDA_REPO_BRANCH}"

      if file "$tarfile" | grep -q "ASCII text"; then
        echo "ERROR: Could not download $filename. Try: export GITHUB_TOKEN=your_token"
        exit 1
      fi
    fi
    echo "OK: $tarfile"
  done
fi

# ─── busybox (used by bootstrap wrapper inside the rootfs) ───────────────────
if [[ -f "$BUSYBOX_PATH" ]]; then
  echo "Skipping busybox download, $BUSYBOX_PATH already exists."
else
  echo "Downloading busybox..."
  wget -O "$BUSYBOX_PATH" "$BUSYBOX_URL"
fi
if [[ -f "$OPENSSL_PATH" ]]; then
  echo "Skipping OpenSSL download, $OPENSSL_PATH already exists."
else
  echo "Downloading static OpenSSL binary..."
  curl -LO "$OPENSSL_PATH" "$OPENSSL_URL"
fi

# ─── Firecracker release archive + checksum ──────────────────────────────────
ARCHIVE="firecracker-${LATEST_VERSION}-${ARCH}.tgz"
SHA256="${ARCHIVE}.sha256.txt"

if [[ -f "$ARCHIVE" ]]; then
  echo "Skipping Firecracker archive download, already exists: $ARCHIVE"
else
  echo "Downloading Firecracker archive: $ARCHIVE"
  curl -L -o "$ARCHIVE" "${RELEASE_URL}/download/${LATEST_VERSION}/${ARCHIVE}"
fi

if [[ -f "$SHA256" ]]; then
  echo "Skipping SHA256 download, already exists: $SHA256"
else
  echo "Downloading SHA256 file: $SHA256"
  curl -L -o "$SHA256" "${RELEASE_URL}/download/${LATEST_VERSION}/${SHA256}"
fi

# ─── Persist resolved values for parts 2 and 3 ───────────────────────────────
cat > build.env <<EOF
ARCH="${ARCH}"
LATEST_VERSION="${LATEST_VERSION}"
CI_VERSION="${CI_VERSION}"
KERNEL_FILENAME="${KERNEL_FILENAME}"
EOF

echo
echo "Downloads complete. Resolved values written to ./build.env"