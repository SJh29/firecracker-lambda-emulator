def csv_python(request, context): 
    from .Inspector import Inspector
    import random
    import numpy as np
    import pandas as pd
    size = 2000
    loops = int(request['rounds'])
    calcs = 1000
    inspector = Inspector()
    inspector.inspectAll()
    for x in range(loops):
        # Generate a list of size random numbers
        l1 = [random.randint(10, 1000) for i in range(size)]
        l2 = [random.randint(10, 1000) for i in range(size)]
        l3 = [random.randint(10, 1000) for i in range(size)]
        l4 = [random.randint(10, 1000) for i in range(size)]
        l5 = [random.randint(10, 1000) for i in range(size)]
        
        # Create a pandas dataframe
        df = pd.DataFrame(list(zip(l1, l2, l3, l4, l5)), 
               columns =['A', 'B', 'C', 'D', 'E'])
        
        for y in range(calcs):
            # Do some calculations
            df['E'] = df['A'] + df['B']
            df['E'] = df['C'] - df['D']
            df['E'] = df['A'] * df['B']
            df['E'] = df['C'] / 5
            df['E'] = df['D'] % 9
            
            df['E'] = np.sum(df['A'])
            df['E'] = np.mean(df['B'])
            df['E'] = np.sqrt(df['C'])
            df['E'] = np.min(df['A'])
            df['E'] = np.max(df['B'])


    inspector.inspectAllDeltas()

    #inspector.addAttribute("openssl_version", subprocess.run(['openssl','version'], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8'))
    return inspector.finish()