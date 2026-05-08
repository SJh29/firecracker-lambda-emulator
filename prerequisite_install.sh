#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

ARCH="$(uname -m)"

latest_version=$(basename $(curl -fsSLI -o /dev/null -w  %{url_effective} ${release_url}/latest))

CI_VERSION=${latest_version%.*}

latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

kernel_filename=$(basename $latest_kernel_key)

# Download kernel if not already present
if [[ -f "$kernel_filename" ]]; then
  echo "Skipping kernel download, already exists: $kernel_filename"
else
  echo "Downloading kernel: $kernel_filename"
  # Download a linux kernel binary
  wget "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}" 
fi
 
# Download and build AWS Lambda base image rootfs
if [[ -f "aws_baseimage.ext4" ]]; then
  echo "Skipping rootfs build, already exists: aws_baseimage.ext4"
else
  echo "Building AWS Lambda base image rootfs..."

  # Ensure git-lfs is installed
  if ! command -v git-lfs &>/dev/null; then
    echo "Installing git-lfs..."
    sudo apt-get install -y git-lfs
  fi
  git lfs install

  # Clone the lambda base image repo (python3.10 x86_64 branch)
  if [[ ! -d "aws-lambda-base-images" ]]; then
    git clone --branch python3.10 --single-branch https://github.com/aws/aws-lambda-base-images.git
  fi

  # Pull LFS files
  echo "Pulling LFS objects..."
  git -C aws-lambda-base-images lfs pull

  # Verify the tar files are real (not LFS pointers)
  for tarfile in aws-lambda-base-images/x86_64/*.tar.xz; do
    if file "$tarfile" | grep -q "ASCII text"; then
      echo "LFS pull failed for $tarfile, falling back to GitHub API download..."

      filename=$(basename "$tarfile")
      curl -L \
        -H "Accept: application/vnd.github.v3.raw" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        -o "$tarfile" \
        "https://api.github.com/repos/aws/aws-lambda-base-images/contents/x86_64/${filename}?ref=python3.10"

      if file "$tarfile" | grep -q "ASCII text"; then
        echo "ERROR: Could not download $filename. Try: export GITHUB_TOKEN=your_token"
        exit 1
      fi
    fi
    echo "OK: $tarfile"
  done

  # Extract all tar.xz layers into staging directory
  if [[ ! -d "lambda-rootfs" ]]; then
    mkdir -p lambda-rootfs
    for tarfile in aws-lambda-base-images/x86_64/*.tar.xz; do
      echo "Extracting layer: $tarfile"
      sudo tar -xf "$tarfile" -C lambda-rootfs
    done
  fi

  # Clean up cloned repo and tar files to free space before image creation
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
  wget -O /tmp/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
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

# Firecracker Binary download + verification via SHA256

ARCHIVE="firecracker-${latest_version}-${ARCH}.tgz"
SHA256="${ARCHIVE}.sha256.txt"
folder="release-${latest_version}-${ARCH}"

# Verify required files exist
if [[ ! -f "$ARCHIVE"  && ! -d "$folder" ]]; then
  echo "Error: Archive OR Folder not found: $ARCHIVE OR $folder" >&2
  curl -L ${release_url}/download/${latest_version}/firecracker-${latest_version}-${ARCH}.tgz | tar -xz
  curl -L ${release_url}/download/${latest_version}/firecracker-${latest_version}-${ARCH}.tgz.sha256.txt
  
  if [[ ! -f "$SHA256" ]]; then
  echo "Error: SHA256 file not found: $SHA256" >&2
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
fi
 

if [[ -d "release-${latest_version}-${ARCH}" ]]; then
  echo "Skipping extraction, directory 'release-${latest_version}-${ARCH}' already exists."
else
  # Extract archive
  echo "Extracting $ARCHIVE..."
  tar -xzf "$ARCHIVE"
  echo "Done."
fi

echo
echo "The following files were downloaded and set up:"
KERNEL=$(ls vmlinux-* | tail -1)
[ -f $KERNEL ] && echo "Kernel: $KERNEL" || echo "ERROR: Kernel $KERNEL does not exist"
ROOTFS=$(ls *.ext4 | tail -1)
e2fsck -fn $ROOTFS &>/dev/null && echo "Rootfs: $ROOTFS" || echo "ERROR: $ROOTFS is not a valid ext4 fs"

# Verify Install

FIRECRACKER="${folder}/firecracker-${latest_version}-${ARCH}"
JAILER="${folder}/jailer-${latest_version}-${ARCH}"

if [[ -f "$FIRECRACKER" ]]; then
  echo "Firecracker Found: '$latest_version'"
else
  echo "Error: Firecracker not found in '$folder'." >&2
  exit 1
fi

if [[ -f "$JAILER" ]]; then
  echo "Jailer Found."
else
  echo "Error: Firecracker not found in '$folder'." >&2
  exit 1
fi

# Rename Binaries
# Rename the binary to "firecracker"
if [[ -f "firecracker" ]]; then
  echo "Skipping firecracker binary rename, 'firecracker' already exists."
else
  mv release-${latest_version}-${ARCH}/firecracker-${latest_version}-${ARCH} firecracker
  echo "firecracker binary renamed to 'firecracker'"

fi

# Rename the binary to "jailer"
if [[ -f "jailer" ]]; then
  echo "Skipping jailer binary rename, 'jailer' already exists."
else
  mv release-${latest_version}-${ARCH}/jailer-${latest_version}-${ARCH} jailer
  echo "jailer binary renamed to 'jailer'"
fi

echo 
echo "Firecracker installation verified"
