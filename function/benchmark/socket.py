def socket_python(request, context): 
    from .Inspector import Inspector
    # import socket
    import socket
    req_rounds= int(request['rounds'])
    inspector = Inspector()
    inspector.inspectAll()
    for i in range(req_rounds):
        # Create a TCP/IP socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # Close the socket
        sock.close()
    inspector.inspectAllDeltas()

    #inspector.addAttribute("openssl_version", subprocess.run(['openssl','version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    return inspector.finish()