def chacha20_python(request, context):
    import json
    import logging
    from .Inspector import Inspector
    import time
    import os
    import subprocess
    import random

    req_method   = request.get('method', 'chacha20')
    if not req_method.startswith('-'):
        req_method = '-' + req_method
    req_rounds   = str(request.get('rounds', 100000))   # PBKDF2 iterations
    req_password = str(request.get('password', 'benchmarkpass'))

    blocksize = 8192000  # 8 MB cleartext payload
    random.seed(request.get('seed', 42))
    cleartext = random.randbytes(blocksize)
    with open('/tmp/cleartext', 'wb') as f:
        f.write(cleartext)

    # Disable CPU crypto acceleration (AES-NI / ARM crypto extensions)
    os.environ["OPENSSL_armcap"]   = "0"
    os.environ["OPENSSL_ia32cap"]  = "~0x20000000"

    # ── SAAF inspection start ────────────────────────────────────────────────
    inspector = Inspector()
    inspector.inspectAll()

    # Record the OpenSSL version used (affects which cipher implementation runs).
    inspector.addAttribute(
        "openssl_version",
        subprocess.run(['openssl', 'version'], check=True,
                       stdout=subprocess.PIPE).stdout.decode('utf-8').strip())
    inspector.addAttribute("cipher_method", req_method)
    inspector.addAttribute("pbkdf2_rounds", req_rounds)

    # ── Run the cipher benchmark ─────────────────────────────────────────────

    subprocess.run(
        ['openssl', 'enc', req_method, '-salt', '-pbkdf2', '-iter', req_rounds,
         '-in', '/tmp/cleartext', '-out', '/tmp/ciphertext',
         '-pass', 'pass:' + req_password],
        check=True, stdout=subprocess.PIPE)
    if ('name' in request):
        inspector.addAttribute("message", "Hello " + str(request['name']) + "!")
    else:
        inspector.addAttribute("message", "Hello World!")

    inspector.inspectAllDeltas()
    return inspector.finish()
