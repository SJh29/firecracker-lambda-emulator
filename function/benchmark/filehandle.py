def fopen_python(request, context): 
    from .Inspector import Inspector
    # import socket
    import socket
    req_rounds= int(request['rounds'])
    f = open("/tmp/demofile.txt", "w")
    f.write("DEMOTEXT")
    f.close()
    inspector = Inspector()
    inspector.inspectAll()
    for i in range(req_rounds):
        # Create a TCP/IP socket
        f = open("/tmp/demofile.txt", "r")
        # Close the socket
        f.close()
    inspector.inspectAllDeltas()

    #inspector.addAttribute("openssl_version", subprocess.run(['openssl','version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    return inspector.finish()