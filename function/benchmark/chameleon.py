def chameleon_python(request, context): 
    from .Inspector import Inspector
    # import socket
    from chameleon import PageTemplate
    import six

    BIGTABLE_ZPT = """\
    <table xmlns="http://www.w3.org/1999/xhtml"
    xmlns:tal="http://xml.zope.org/namespaces/tal">
    <tr tal:repeat="row python: options['table']">
    <td tal:repeat="c python: row.values()">
    <span tal:define="d python: c + 1"
    tal:attributes="class python: 'column-' + %s(d)"
    tal:content="python: d" />
    </td>
    </tr>
    </table>""" % six.text_type.__name__
    req_rounds= int(request['rounds'])
    n=100
    inspector = Inspector()
    inspector.inspectAll()
    for i in range (req_rounds):
        tmpl = PageTemplate(BIGTABLE_ZPT)

        data = {}
        for j in range(n):
            data[str(j)] = j

        table = [data for x in range(n)]
        options = {'table': table}

        data = tmpl.render(options=options)

    inspector.inspectAllDeltas()

    return inspector.finish()