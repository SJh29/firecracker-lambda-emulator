#cloud_function(platforms=[Platform.AWS], memory=512, config=config)
from benchmark import *

# Dispatch table: request['method'] -> benchmark function. Keys mirror the
# benchmark module names under function/benchmark/.
BENCHMARKS = {
    'chacha20': chacha20_python,
    'chameleon': chameleon_python,
    'compression': sebs_311,
    'csv': csv_python,
    'filehandle': fopen_python,
    'float': float_operation,
    'graph-bfs': sebs503,
    'graph-mst': sebs502,
    'graph-pagerank': sebs_501,
    'json_dump': json_dumps_loads_python,
    'prime-number': cpu_prime_sysbench,
    'readdisk': disk_io_loader_fio,
    'readmemory': memory_loader_sysbench,
    'readwritememory': malloc_python,
    'socket': socket_python,
    'sqlite': sqlite_python,
    'thread': thread_sysbench,
    'video-processing': sebs_220_gif,
}


def handler(request, context):
    method = str(request.get('method', '')).lstrip('-').lower()
    if method not in BENCHMARKS:
        return {
            'errorMessage': f"Unrecognized method '{method}'. Valid methods: "
                             f"{', '.join(sorted(BENCHMARKS))}"
        }
    return BENCHMARKS[method](request, context)
