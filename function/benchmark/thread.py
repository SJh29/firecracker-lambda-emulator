def thread_sysbench(request, context):
    from .Inspector import Inspector 
    import subprocess
    req_yields = request['yields']
    req_locks = request['locks']
    req_events = request['events']
    inspector = Inspector()
    inspector.inspectAll()
    inspector.addAttribute("sysbench_version", subprocess.run(['sysbench','--version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    # Run Benchmark
    inspector.addAttribute("sysbench_output",
                            subprocess.run(['sysbench', 'threads', '--threads=2',
                                            '--thread-yields='+str(req_yields), '--thread-locks='+str(req_locks),
                                            '--events='+str(req_events),'--time=0','--events=1','run'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    inspector.inspectAllDeltas()
    return inspector.finish()