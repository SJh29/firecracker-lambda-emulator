def disk_io_loader_fio(request, context):
    from .Inspector import Inspector 
    import subprocess
    req_rw = request.get('rw') # read, write, randread, randwrite, randrw (read and write)
    req_bs = request.get('bs') # block size
    req_size = request.get('size') # total size
    req_numjobs = request.get('numjobs') # number of jobs
    req_ioengine = request.get('ioengine') # ioengine: sync, libaio, posixaio, vsync, io_uring
    req_iodepth = request.get('iodepth') # iodepth
    req_rounds = request.get('rounds')
    inspector = Inspector()
    inspector.inspectAll()
    # Fio Version
    inspector.addAttribute("fio_version", subprocess.run(['fio','--version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    # Run Benchmark
    for i in range(int(req_rounds)):
        subprocess.run(['fio','--name=benchmark','-filename=/tmp/fiobench','--rw='+req_rw,'--bs='+req_bs,'--size='+req_size,
                        '--numjobs='+req_numjobs,'--ioengine='+req_ioengine,'--iodepth='+req_iodepth,'-group_reporting'], check=True, stdout=subprocess.PIPE)
    inspector.inspectAllDeltas()
    return inspector.finish()