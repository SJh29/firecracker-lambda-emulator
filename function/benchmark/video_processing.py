def sebs_220_gif(request, context): 
    from .Inspector import Inspector
    import requests
    from PIL import Image

    url = 'https://img.trumpdns.com/2023/08/17/ImkP3qf6.jpg'
    r = requests.get(url, allow_redirects=True)
    open('/tmp/data.jpg', 'wb').write(r.content)

    req_size = int(request['size'])

    inspector = Inspector()
    inspector.inspectAll()
    # Convert to Gif
    for i in range(req_size):
        im = Image.open('/tmp/data.jpg')
        im.save('/tmp/data'+str(i)+'.gif')



    inspector.inspectAllDeltas()

    return inspector.finish()