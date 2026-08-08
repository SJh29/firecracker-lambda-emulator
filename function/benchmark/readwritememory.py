def malloc_python(request, context): 
    from .Inspector import Inspector
    req_rounds= int(request['rounds'])
    req_buffer_size= int(request['buffer_size'])
    inspector = Inspector()
    inspector.inspectAll()
    for i in range(req_rounds):
        # Allocate a buffer
        buffer = bytearray(req_buffer_size)
        # Fill the buffer with data
        for i in range(req_buffer_size):
            buffer[i] = 0x42
        # Free the buffer
        del buffer

    inspector.inspectAllDeltas()

    #inspector.addAttribute("openssl_version", subprocess.run(['openssl','version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    return inspector.finish()