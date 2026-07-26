#cloud_function(platforms=[Platform.AWS], memory=512, config=config)
def handler(request, context):
    # Dispatch between two benchmarks based on the request. The chacha20 cipher
    # benchmark runs when method=chacha20 is present; anything else runs the
    # SeBS 502.graph-mst (Barabasi graph + spanning tree) benchmark.
    #
    # "present" here means the selected cipher method is chacha20 — the invoke
    # tooling sends {"method": "chacha20", ...}. To flip the default, change the
    # condition below.
    method = str(request.get('method', '')).lstrip('-').lower()
    if method == 'chacha20':
        return chacha20_benchmark(request, context)
    return sebs_502(request, context)


def chacha20_benchmark(request, context):
    import json
    import logging
    from Inspector import Inspector
    import time
    import os
    import subprocess
    import random

    # ── Benchmark parameters (from request, with safe defaults) ──────────────
    # Mirrors KiritoMiao/ARM-Performance-Predection-model-artifacts chacha20.py:
    # an OpenSSL symmetric-cipher benchmark over a fixed-size random payload,
    # with hardware crypto acceleration disabled so the work stays on the
    # general CPU pipeline (clean cross-architecture comparison).
    #
    # NOTE: in OpenSSL 3.x the cipher must be given as a FLAG (e.g. "-chacha20"),
    # not as a bare positional arg ("chacha20") as in the original reference,
    # which errors on modern OpenSSL. We normalize to the flag form below.
    req_method   = request.get('method', 'chacha20')
    if not req_method.startswith('-'):
        req_method = '-' + req_method
    req_rounds   = str(request.get('rounds', 100000))   # PBKDF2 iterations
    req_password = str(request.get('password', 'benchmarkpass'))

    blocksize = 8192000  # 8 MB cleartext payload
    # Deterministic payload: seeding the RNG makes every invocation (and every
    # environment) encrypt byte-identical cleartext, which is required for a
    # fair cross-environment fidelity comparison. random.randbytes is used
    # instead of random.choices because it is ~35x faster, so the measured time
    # reflects the CIPHER work rather than Python RNG overhead — while remaining
    # fully deterministic under a fixed seed. (random.randbytes needs Py3.9+.)
    random.seed(request.get('seed', 42))
    cleartext = random.randbytes(blocksize)
    with open('/tmp/cleartext', 'wb') as f:
        f.write(cleartext)

    # Disable CPU crypto acceleration (AES-NI / ARM crypto extensions) so the
    # cipher runs on the general-purpose pipeline — the basis for the
    # cross-architecture fidelity comparison.
    os.environ["OPENSSL_armcap"]   = "0"
    os.environ["OPENSSL_ia32cap"]  = "~0x20000000"

    # ── SAAF inspection start ────────────────────────────────────────────────
    inspector = Inspector()
    inspector.inspectAll()

    def get_procstat():
        with open('/proc/stat', 'r') as f:
            return ''.join(f.readlines())

    # Record the OpenSSL version used (affects which cipher implementation runs).
    inspector.addAttribute(
        "openssl_version",
        subprocess.run(['openssl', 'version'], check=True,
                       stdout=subprocess.PIPE).stdout.decode('utf-8').strip())
    inspector.addAttribute("cipher_method", req_method)
    inspector.addAttribute("pbkdf2_rounds", req_rounds)

    # ── Run the cipher benchmark ─────────────────────────────────────────────
    inspector.addAttribute("proc_before", get_procstat())
    subprocess.run(
        ['openssl', 'enc', req_method, '-salt', '-pbkdf2', '-iter', req_rounds,
         '-in', '/tmp/cleartext', '-out', '/tmp/ciphertext',
         '-pass', 'pass:' + req_password],
        check=True, stdout=subprocess.PIPE)
    inspector.addAttribute("proc_after", get_procstat())

    if ('name' in request):
        inspector.addAttribute("message", "Hello " + str(request['name']) + "!")
    else:
        inspector.addAttribute("message", "Hello World!")

    inspector.inspectAllDeltas()
    return inspector.finish()


def sebs_502(request, context):
    # SeBS 502.graph-mst: build a Barabasi–Albert graph of `size` vertices and
    # compute a spanning tree. `size` is required in the request.
    #
    # NOTE: this repo bundles Inspector.py directly at /var/task, so it's
    # imported as `from Inspector import Inspector` rather than the SeBS/SAAF
    # `from SAAF import Inspector`. `igraph` is vendored into the guest rootfs by
    # install_build.sh (see guest-requirements.txt), so it's importable here
    # after the rootfs is (re)built.
    from Inspector import Inspector
    import datetime, igraph
    req_size = int(request['size'])
    inspector = Inspector()
    inspector.inspectAll()
    graph_generating_begin = datetime.datetime.now()
    graph = igraph.Graph.Barabasi(req_size, 10)
    graph_generating_end = datetime.datetime.now()

    process_begin = datetime.datetime.now()
    result = graph.spanning_tree(None, False)
    process_end = datetime.datetime.now()
    inspector.addAttribute("graph_generating_time", (graph_generating_end - graph_generating_begin).total_seconds())
    inspector.addAttribute("process_time", (process_end - process_begin).total_seconds())
    inspector.inspectAllDeltas()

    return inspector.finish()
