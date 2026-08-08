def json_dumps_loads_python(request, context): 
    from .Inspector import Inspector
    # import socket
    from urllib.request import urlopen
    import json
    req_rounds= int(request['rounds'])
    req_link= request['link']
    f = urlopen(req_link)
    data = f.read().decode("utf-8")
    inspector = Inspector()
    inspector.inspectAll()
    for i in range(req_rounds):
        json_data = json.loads(data)
        str_json = json.dumps(json_data, indent=4)
    inspector.inspectAllDeltas()

    return inspector.finish()