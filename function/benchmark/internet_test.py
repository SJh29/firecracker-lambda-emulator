def internet_check(event, context):
    import urllib.request, socket, time
    t0 = time.time()
    ip = socket.gethostbyname("example.com")          # tests DNS
    body = urllib.request.urlopen("https://example.com", timeout=10).read()
    return {"dns": ip, "bytes": len(body), "ms": round((time.time()-t0)*1000)}
