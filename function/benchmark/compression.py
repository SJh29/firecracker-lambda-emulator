def sebs_311(request, context): 
    from .Inspector import Inspector
    import os
    import shutil
    import uuid
    import gzip
    import numpy as np
    req_size = int(request['size'])
    req_events = int(request['events'])
    # fix the random seed for reproducibility
    np.random.seed(0)
    random_data = np.random.bytes(req_size)
    # Write data to a temporary file
    tmp_file = "/tmp/" + str(uuid.uuid4())
    with open(tmp_file, "wb") as f:
        f.write(random_data)

    inspector = Inspector()
    inspector.inspectAll()
    
    # Compress the file in x times
    compressed_file = tmp_file + ".gz"
    for i in range(req_events):
        with open(tmp_file, "rb") as f_in:
            with gzip.open(compressed_file, "wb") as f_out:
                shutil.copyfileobj(f_in, f_out)

        # Delete the compressed file
        os.remove(compressed_file)

    inspector.inspectAllDeltas()

    return inspector.finish()