def memory_loader_sysbench(request, context):
    from .Inspector import Inspector 
    import subprocess
    req_threads = request.get('threads') # number of threads
    req_blocksize = request.get('blocksize') # block size
    req_totalsize = request.get('totalsize') # total size
    req_operation = request.get('operation') # operation: read, write, randread, randwrite, seqrd, seqwr, seqrewr
    req_accessmode = request.get('accessmode') # access mode: seq, rnd
    inspector = Inspector()
    inspector.inspectAll()
    inspector.addAttribute("sysbench_version", subprocess.run(['sysbench','--version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    # Run Benchmark
    inspector.addAttribute("sysbench_output", subprocess.run(['sysbench','memory','--threads='+req_threads,'--memory-block-size='+req_blocksize,'--memory-total-size='+req_totalsize,
                    '--memory-oper='+req_operation,'--memory-access-mode='+req_accessmode,'--time=0','--events=1','run'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))


    inspector.inspectAllDeltas()
    return inspector.finish()
