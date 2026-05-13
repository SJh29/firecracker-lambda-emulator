#cloud_function(platforms=[Platform.AWS], memory=512, config=config)
def handler(request, context):
    import json
    import logging
    from Inspector import Inspector
    import time
    import hashlib
    # Import the module and collect data 
    inspector = Inspector()
    inspector.inspectAll()
    import os

    # Current clocksource
    try:
        with open('/sys/devices/system/clocksource/clocksource0/current_clocksource') as f:
            inspector.addAttribute("clocksource", f.read().strip())
        with open('/sys/devices/system/clocksource/clocksource0/available_clocksource') as f:
            inspector.addAttribute("available_clocksource", f.read().strip())
    except Exception as e:
        inspector.addAttribute("clocksource", e)
    # Kernel version
    with open('/proc/version') as f:
        inspector.addAttribute("kernel", f.read().strip())

    def get_procstat():
        with open('/proc/stat', 'r') as f:
            result = ''.join(f.readlines())
        return result
    
    def burn_cpu(iterations=15_000_000):
        x = b"seed"
        for _ in range(iterations):
            x = hashlib.sha256(x).digest()
        return x
    def burn_memory(mem_size=120):
        data = bytearray(mem_size * 1024 * 1024)
        import mmap
        PAGE = mmap.PAGESIZE
        for i in range(0, len(data), PAGE):
            data[i] = 1

    inspector.addAttribute("proc_before", get_procstat())
    burn_cpu()
    burn_memory()
    for _ in range(1_000_000): os.getpid()
    inspector.addAttribute("proc_after", get_procstat())

    if ('name' in request):
        inspector.addAttribute("message", "Hello " + str(request['name']) + "!")
    else:
        inspector.addAttribute("message", "Hello World!")
    

    inspector.inspectAllDeltas()
    return inspector.finish()