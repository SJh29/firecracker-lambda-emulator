# Function Setup Scripts

Scripts for launching a Firecracker microVM and invoking a Lambda function inside it. Run these after the install scripts have completed.

Typical order: `setup_tap.sh` → `run_firecracker.sh` (separate terminal) → `build_function.sh` → `invoke.sh`. Use `kill_firecracker.sh` to stop the VM.

---

## [run_firecracker.sh](../run_firecracker.sh)

Starts the Firecracker process bound to the API socket and loads the VM configuration.

**Requires:** `./firecracker` binary, `./vm_config.json`, and the drives referenced inside it (`aws_baseimage.ext4`, `function.ext4`).

Run this in a dedicated terminal — it blocks until the VM is stopped. The TAP interface (`setup_tap.sh`) must be up before launching.

```
sudo ./run_firecracker.sh
```

Internally runs:
```
sudo ./firecracker --api-sock /tmp/firecracker.socket --enable-pci --config-file ./vm_config.json
```

---

## [function_scripts/setup_tap.sh](../function_scripts/setup_tap.sh)

Creates the host TAP device and configures NAT so the guest can reach the internet.

**Requires:** `iproute2` (`ip`), `iptables`, `jq`.

**What it does:**
1. Deletes any stale `tap0` device from a previous run, then recreates it at `172.16.0.1/30`.
2. Enables IPv4 forwarding (`/proc/sys/net/ipv4/ip_forward`).
3. Sets `iptables FORWARD` policy to `ACCEPT`.
4. Adds a `MASQUERADE` NAT rule on the host's default interface so guest traffic is rewritten with the host's public IP.

Run once before `run_firecracker.sh`. Re-running is safe — stale rules are removed first.

---

## [function_scripts/build_function.sh](../function_scripts/build_function.sh)

Packages `function.py` and `Inspector.py` into a small ext4 drive that the guest mounts at `/var/task`.

**Requires:** `e2fsprogs` (`mkfs.ext4`), `./function.py`, `./Inspector.py`.

**Produces:** `function.ext4` (32 MB ext4 image).

**What it does:**
1. Stages `function.py` and `Inspector.py` into a temporary directory mirroring the Lambda task layout.
2. Creates a 32 MB ext4 image from that staging directory.
3. Cleans up the staging directory.

Re-run this whenever `function.py` changes. The previous `function.ext4` is always replaced.

---

## [function_scripts/invoke.sh](../function_scripts/invoke.sh)

Sends a JSON payload to the Lambda Runtime Interface Emulator (RIE) running inside the guest and prints the response.

**Requires:** A running Firecracker VM with the guest network reachable at `172.16.0.2:8080`, `curl`, `jq`.

| Variable | Description | Default |
|---|---|---|
| `PAYLOAD` | JSON body sent to the Lambda invocation endpoint | `{"name": "Sparsh"}` |
| `TIMEOUT` | Maximum wait time in seconds for a response | `300` |

The script POSTs to `http://172.16.0.2:8080/2015-03-31/functions/function/invocations`. It exits non-zero if the response contains an `errorMessage` field or if `curl` times out.

---

## [kill_firecracker.sh](../kill_firecracker.sh)

Cleanly stops a running Firecracker microVM.

If the API socket (`/tmp/firecracker.socket`) is present, sends a `SendCtrlAltDel` action via the Firecracker API to trigger a graceful guest shutdown. Otherwise falls back to `pkill` on the Firecracker process.

```
./kill_firecracker.sh
```
