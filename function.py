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

    # The big one — what HZ is /proc/stat actually using?
    clk_tck = os.sysconf('SC_CLK_TCK')
    inspector.addAttribute("CLK_TCK", clk_tck)

    # Number of CPUs the guest sees
    nproc = os.sysconf('SC_NPROCESSORS_ONLN')
    inspector.addAttribute("nproc", nproc)

    # Current clocksource
    try:
        with open('/sys/devices/system/clocksource/clocksource0/current_clocksource') as f:
            inspector.addAttribute("clocksource", f.read().strip())
    except Exception as e:
        inspector.addAttribute("clocksource", e)
    # Kernel version
    with open('/proc/version') as f:
        inspector.addAttribute("kernel", f.read().strip())

    # Kernel config (if exposed)
    import gzip
    try:
        kconf = ''
        with gzip.open('/proc/config.gz', 'rt') as f:
            config = f.read()
        for line in config.splitlines():
            if any(k in line for k in ['CONFIG_HZ', 'CONFIG_NO_HZ', 'CONFIG_VIRT_CPU_ACCOUNTING', 'CONFIG_IRQ_TIME']):
                kconf.join(line)
        inspector.addAttribute("kconf", kconf)
    except FileNotFoundError:
        inspector.addAttribute("kconf","no /proc/config.gz")
    
    def get_procstat():
        with open('/proc/stat', 'r') as f:
            result = ''.join(f.readlines())
        return result
    
    def get_uptime_delta():
        with open('/before_time', 'r') as f:
            before = ''.join(f.readlines())
        with open('/after_time','r') as f:
            after = ''.join(f.readlines())
        return (before, after)
    # get kernel config stored by bootstrap wrapper on boot
    def get_kernel_config():
        with open('/kernelconfig') as f:
            conf = ''.join(f.readlines())
        return conf

    def burn_cpu(iterations=5_000_000):
        x = b"seed"
        for _ in range(iterations):
            x = hashlib.sha256(x).digest()
        return x
    with open('/proc/cpuinfo', 'r') as f:
        lscpuinfo = ''.join(f.readlines())
    inspector.addAttribute("lscpu", lscpuinfo)
    inspector.addAttribute("proc_before", get_procstat())
    burn_cpu()
    inspector.addAttribute("proc_after", get_procstat())
    inspector.addAttribute("kernel_conf_combined", get_kernel_config())
    uptime_Delta = get_uptime_delta()
    inspector.addAttribute("uptime_before", uptime_Delta[0])
    inspector.addAttribute("uptime_after", uptime_Delta[1])

    if ('name' in request):
        inspector.addAttribute("message", "Hello " + str(request['name']) + "!")
    else:
        inspector.addAttribute("message", "Hello World!")
    

    inspector.inspectAllDeltas()
    return inspector.finish()