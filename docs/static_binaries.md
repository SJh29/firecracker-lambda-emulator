# Static Binaries ([static_build/](../static_build/))

Prebuilt, fully statically-linked x86_64 Linux binaries checked into
`static_build/` and vendored into the guest rootfs by
[`install_build.sh`](../install_build.sh) (see `STATIC_BUILD_DIR` in
[`config.sh`](../config.sh)). They exist because the AWS Lambda base image
ships none of `openssl`, `sysbench`, or `fio`, and none of the three projects
publish an official static binary release -- so they're built from source
once, here, instead of on every `install_build.sh` run (each takes a few
minutes to compile).

| Binary | Version | Used by |
|---|---|---|
| `openssl` | 3.5.7 | `function/benchmark/chacha20.py` |
| `sysbench` | 1.0.20 | `function/benchmark/prime_number.py`, `function/benchmark/thread.py` |
| `fio` | 3.39 | `function/benchmark/readdisk.py` |

All three are `ELF 64-bit x86_64, statically linked` (verify with `file`) --
no shared library dependencies, so they run on any x86_64 Linux kernel
regardless of the guest's glibc version. They were **not** built with
`-march=native`: the build host's CPU is whatever compiled them, which is not
guaranteed to match the deployment target (an Intel Xeon 8529CL in this
project's case), and a `-march=native` binary can `SIGILL` on a CPU lacking
the build host's instruction extensions. All three build with a generic
x86-64 baseline instead.

---

## Rebuilding

Built via `wsl -d Ubuntu` (Ubuntu 24.04 at the time of writing) as root
(`wsl -d Ubuntu -u root`, no sudo password needed under WSL). Any x86_64
Linux build host works -- static linking removes the runtime glibc-version
dependency, so the build host's distro/version doesn't need to match the
guest's.

```bash
apt-get install -y build-essential libaio-dev zlib1g-dev liburing-dev \
  pkg-config libtool-bin m4 ca-certificates curl git
```

### openssl 3.5.7

```bash
curl -fL -o openssl-3.5.7.tar.gz \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz
mkdir openssl-src && tar xzf openssl-3.5.7.tar.gz -C openssl-src --strip-components=1
cd openssl-src
./Configure no-shared no-dso -static linux-x86_64
make -j"$(nproc)"
# binary: apps/openssl
```

The `getaddrinfo`/`gethostbyname` static-linking warnings during the link are
expected and harmless -- the chacha20 benchmark never does DNS lookups.

### sysbench 1.0.20

```bash
git clone --depth 1 --branch 1.0.20 https://github.com/akopytov/sysbench.git
cd sysbench
./autogen.sh
# --without-mysql/--without-pgsql drop DB client deps this project doesn't use;
# --disable-aio drops libaio (irrelevant to the cpu/memory/threads subcommands
# actually used). Deliberately NOT passing CFLAGS/LDFLAGS=-static here: the
# bundled Concurrency Kit (third_party/concurrency_kit) always builds a
# libck.so target too, and a globally-forced -static breaks that
# (`-static -shared` is a hard link error). Link statically only at the very
# end, against the already-built static archives.
./configure --without-mysql --without-pgsql --disable-aio
make -j"$(nproc)"
# The libtool-driven link above is dynamic (produces a PIE). Relink statically
# by hand using the exact object/archive list `make` printed for the final
# `libtool --mode=link` step (`src/sysbench.o ... -lm`), adding -static:
cd src
gcc -O2 -funroll-loops -static -o sysbench_static \
  sysbench.o sb_timer.o sb_options.o sb_logger.o db_driver.o sb_histogram.o \
  sb_rand.o sb_thread.o sb_barrier.o sb_lua.o sb_util.o sb_counter.o \
  tests/fileio/libsbfileio.a tests/threads/libsbthreads.a \
  tests/memory/libsbmemory.a tests/cpu/libsbcpu.a tests/mutex/libsbmutex.a \
  ../third_party/luajit/lib/libluajit-5.1.a -ldl \
  ../third_party/concurrency_kit/lib/libck.a -lm
# binary: src/sysbench_static
```

The `dlopen` static-linking warning (from bundled LuaJIT's FFI clib loader)
is expected and harmless -- none of the benchmarks load Lua scripts that
`require` a C extension.

### fio 3.39

```bash
git clone --depth 1 --branch fio-3.39 https://github.com/axboe/fio.git
cd fio
# --disable-native is the important one: fio's configure auto-detects
# `-march=native` from the build host and bakes it in by default (see "Build
# march=native" in configure output) -- must be turned off explicitly, see
# the CPU-mismatch note above. The --disable-* flags drop optional storage
# backends (rados/rbd/nfs/http) this project has no use for and that would
# otherwise need extra dev libraries.
./configure --build-static --disable-native --disable-shm --disable-numa \
  --disable-rdma --disable-rados --disable-rbd --disable-http --disable-libnfs
make -j"$(nproc)"
# binary: fio
```

### Finishing up

```bash
strip openssl-src/apps/openssl sysbench/src/sysbench_static fio/fio
cp openssl-src/apps/openssl     static_build/openssl
cp sysbench/src/sysbench_static static_build/sysbench
cp fio/fio                      static_build/fio
```

Sanity-check after stripping (stripping only removes symbols, but confirm the
binaries still run):

```bash
./static_build/openssl version
./static_build/sysbench --version
./static_build/fio --version
```
