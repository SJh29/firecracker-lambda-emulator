def internet_check(event, context):
    import urllib.request, socket, time
    from .Inspector import Inspector
    inspector = Inspector()
    inspector.inspectAll()
    t0 = time.time()
    ip = socket.gethostbyname("example.com")          # tests DNS
    body = urllib.request.urlopen("https://example.com", timeout=10).read()
    inspector.addAttribute("dns", ip)
    inspector.addAttribute("bytes", len(body))
    inspector.addAttribute("ms", round((time.time()-t0)*1000))
    inspector.addAttribute("body", "".join(body.decode().splitlines()[:10]))
    inspector.inspectAllDeltas()
    return inspector.finish()
