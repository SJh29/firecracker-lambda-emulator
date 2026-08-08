def sqlite_python(request, context): 
    from .Inspector import Inspector
    import sqlite3
    import random
    import string
    req_rounds= int(request['rounds'])
    inspector = Inspector()
    #Generate a Sqlite DB on TMP
    db_name = '/tmp/'+''.join(random.choices(string.ascii_uppercase + string.digits, k = 10))+'.db'
    conn = sqlite3.connect(db_name)
    c = conn.cursor()



    inspector.inspectAll()
    # Create table with 10 columns
    c.execute('''CREATE TABLE benchmark
                    (id integer, col1 text, col2 text, col3 text, col4 text, col5 text, col6 text, col7 text, col8 text, col9 text)''')
    # Insert 10000 rows with random data
    for i in range(10000):
        #data = (i, ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)), ''.join(random.choices(string.ascii_uppercase + string.digits, k = 10)))
        data = (i, 'tsdadsadadasdsadext1'+str(i), 'texasdfasfasdfadsfasdfasft2'+str(i), 'textasfdasdfasdfasdfasdf3'+str(i), 'texasdfsadfasdfasdfasdt4'+str(i), 'texasfdsadfsdafsadfasdt5'+str(i), 'teasdfdsafasdfdsadfasdfasxt6'+str(i), 'tasdfasdfasdfsadfsadext7'+str(i), 'tefsadfadsfasdfasdfasdfaswxt8'+str(i), 'tsadfasdfasdfsdafsafsadfasfdsafsadext9'+str(i))
        c.execute("INSERT INTO benchmark VALUES (?,?,?,?,?,?,?,?,?,?)", data)
    # Commit the changes
    conn.commit()

    # Query the DB
    for i in range(req_rounds):
        #c.execute("SELECT * FROM benchmark WHERE id = ?", (random.randint(0, 1000),))
        c.execute("SELECT * FROM benchmark WHERE id = ?", (5000,))
        result = c.fetchone()
        #print(result)
    # Close the connection
    conn.close()


    inspector.inspectAllDeltas()

    #inspector.addAttribute("openssl_version", subprocess.run(['openssl','version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    return inspector.finish()