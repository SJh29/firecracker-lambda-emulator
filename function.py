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

    # Add custom message and finish the function

    def burn_cpu(iterations=5_000_000):
        x = b"seed"
        for _ in range(iterations):
            x = hashlib.sha256(x).digest()
        return x
    burn_cpu()
    with open('/proc/stat', 'r') as f:
        result = ''.join(f.readlines())
    if ('name' in request):
        inspector.addAttribute("message", "Hello " + str(request['name']) + "!" + " proc: "+ result)
    else:
        inspector.addAttribute("message", "Hello World!")
    

    inspector.inspectAllDeltas()
    return inspector.finish()