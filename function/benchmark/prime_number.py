def cpu_prime_sysbench(request, context):
    from .Inspector import Inspector 
    import subprocess
    req_threads = request.get('threads') # number of threads
    req_maxprime = request.get('maxprime') # max prime number
    inspector = Inspector()
    inspector.inspectAll()
    inspector.addAttribute("sysbench_version", subprocess.run(['sysbench','--version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    # Run Benchmark
    inspector.addAttribute("sysbench_output", subprocess.run(['sysbench','cpu','--threads='+req_threads,'--cpu-max-prime='+req_maxprime,
                                                              '--time=0','--events=1','run'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    inspector.inspectAllDeltas()
    return inspector.finish()