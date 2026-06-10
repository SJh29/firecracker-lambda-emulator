#cloud_function(platforms=[Platform.AWS], memory=512, config=config)
def handler(request, context):
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