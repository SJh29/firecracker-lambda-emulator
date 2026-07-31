#!/usr/bin/env python3
"""Drive N Firecracker microVMs concurrently and build SAAF reports.

Replaces SAAF's faas_runner.py, which can only ever call functions[0]
(experiment_orchestrator.py passes callExperiment([func], exp)). Report
generation is not reimplemented: report() and write_file() are imported from
the SAAF checkout, so the CSVs are byte-identical to what faas_runner produces.

One in-flight request per endpoint — the Lambda RIE inside each guest serves a
single invocation at a time, so concurrency comes from the VM count.

Usage:
  saaf_driver.py -f FUNC.json [FUNC.json ...] -e EXPERIMENT.json -o OUTDIR
"""

import argparse
import json
import os
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

# Mirrors faas_runner.py's defaultExperiment. report() indexes these keys
# directly, so every one has to be present.
DEFAULT_EXPERIMENT = {
    'callWithCLI': False,
    'callAsync': False,
    'memorySettings': [],
    'parentPayload': {},
    'payloads': [{}],
    'payloadFolder': '',
    'shufflePayloads': False,
    'runs': 10,
    'threads': 10,
    'iterations': 1,
    'sleepTime': 0,
    'randomSeed': 42,
    'outputGroups': [],
    'outputRawOfGroup': [],
    'showAsList': [],
    'showAsSum': [],
    'ignoreFromAll': [],
    'ignoreFromGroups': [],
    'ignoreByGroup': [],
    'invalidators': {},
    'removeDuplicateContainers': False,
    'overlapFilter': "",
    'openCSV': False,
    'combineSheets': False,
    'warmupBuffer': 0,
    'experimentName': "DEFAULT-EXP",
    'passPayloads': False,
    'transitions': {},
    'simpleOutput': True,
    'httpTimeout': 300,
}


def load_experiment(path):
    exp = dict(DEFAULT_EXPERIMENT)
    exp.update(json.load(open(path)))
    exp['experimentName'] = os.path.basename(path).replace('.json', '')
    exp['sourceFile'] = path
    if exp['payloadFolder']:
        print("WARNING: payloadFolder is not supported; ignoring it.")
    # Same merge order as experiment_orchestrator.prepare_payloads.
    exp['payloads'] = [{**exp['parentPayload'], **p} for p in exp['payloads']]
    return exp


def build_payload_list(exp, total_runs):
    """Duplicate and optionally shuffle payloads, as experiment_caller does."""
    random.seed(exp['randomSeed'])
    payloads = exp['payloads']
    payload_list = list(payloads)
    while len(payload_list) < total_runs:
        payload_list += payloads
    if exp['shufflePayloads']:
        random.shuffle(payload_list)
    return payload_list


def post_process(function, response_text, thread_id, run_id, payload, round_trip):
    """Port of experiment_caller.callPostProcessor.

    Two deliberate differences: json.loads instead of ast.literal_eval, which
    accepts JSON null/true/false; and endpoint is always recorded, where SAAF
    drops it whenever the response carries a platform field.
    """
    d = json.loads(response_text)
    d['2_thread_id'] = thread_id
    d['1_run_id'] = run_id
    d['zAll'] = "Final Results:"
    d['roundTripTime'] = round_trip
    d['payload'] = str(payload)

    if 'runtime' in d:
        d['latency'] = round(round_trip - int(d['runtime']), 2)
    if 'cpuType' in d and 'cpuModel' in d:
        d['cpuType'] = str(d['cpuType']) + " - Model " + str(d['cpuModel'])
    d['endpoint'] = function['endpoint']

    # report() writes unquoted CSV, so separators inside values must go.
    for key in list(d.keys()):
        d[key] = str(d[key]).replace(',', ';').replace('\t', '\\t').replace('\n', '\\n')
    return d


def call_endpoint(function, thread_id, payloads, exp, results, timeout):
    """Sequential runs against one endpoint. Appends to `results`."""
    for run_id, payload in enumerate(payloads):
        body = json.dumps(payload)
        start = time.time()
        try:
            response = requests.post(
                function['endpoint'], data=body,
                headers={'content-type': 'application/json'}, timeout=timeout)
            text = response.text
        except Exception as e:
            print("Run %s.%s failed: %s" % (thread_id, run_id, e))
            continue
        round_trip = round((time.time() - start) * 100000) / 100

        try:
            record = post_process(function, text, thread_id, run_id, body, round_trip)
        except Exception as e:
            print("Run %s.%s unparseable: %s\nResponse: %s" % (thread_id, run_id, e, text))
            continue

        # faas_runner's own gate for a usable response.
        if 'version' not in record:
            print("Run %s.%s dropped: no version field in response." % (thread_id, run_id))
            continue
        results.append(record)
        print("Run %s.%s successful." % (thread_id, run_id))


def run_iteration(functions, exp, runs_per_endpoint, payload_list):
    """One pass over every endpoint, all endpoints in parallel."""
    results = []
    with ThreadPoolExecutor(max_workers=len(functions)) as pool:
        for i, function in enumerate(functions):
            start = i * runs_per_endpoint
            pool.submit(call_endpoint, function, i,
                        payload_list[start:start + runs_per_endpoint],
                        exp, results, exp['httpTimeout'])
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('-f', '--functions', nargs='+', required=True,
                    help='SAAF function JSON files, one per endpoint')
    ap.add_argument('-e', '--experiment', required=True, help='SAAF experiment JSON')
    ap.add_argument('-o', '--out', required=True, help='output directory')
    ap.add_argument('--saaf', required=True, help='path to the SAAF checkout')
    ap.add_argument('--name', default='firecracker', help='report file prefix')
    args = ap.parse_args()

    sys.path.insert(0, os.path.join(args.saaf, 'test', 'tools'))
    from report_generator import report, write_file

    exp = load_experiment(args.experiment)
    functions = [json.load(open(f)) for f in args.functions]
    os.makedirs(args.out, exist_ok=True)

    total_runs = exp['runs']
    endpoints = len(functions)
    if total_runs < endpoints:
        sys.exit("runs (%d) must be >= the number of endpoints (%d)" % (total_runs, endpoints))
    if exp['threads'] != endpoints:
        print("NOTE: experiment sets threads=%d but there are %d endpoints; "
              "using %d concurrent streams." % (exp['threads'], endpoints, endpoints))
    # One stream per endpoint, so the report's header reflects what actually ran.
    exp['threads'] = endpoints
    runs_per_endpoint = total_runs // endpoints
    exp['runs'] = runs_per_endpoint * endpoints

    print("endpoints: %d, %d run(s) each, %d iteration(s)"
          % (endpoints, runs_per_endpoint, exp['iterations']))

    payload_list = build_payload_list(exp, exp['runs'])
    all_iterations = []

    for i in range(exp['iterations']):
        print("\n--- iteration %d ---" % i)
        results = run_iteration(functions, exp, runs_per_endpoint, payload_list)
        all_iterations.append(results)

        if not results:
            print("iteration %d: every request failed" % i)
            continue

        base = os.path.join(args.out, "%s-%s-run%d" % (args.name, exp['experimentName'], i))
        write_file(base, report(results, exp), exp['openCSV'], results)

        if i < exp['iterations'] - 1:
            time.sleep(exp['sleepTime'])

    if exp['combineSheets'] and exp['iterations'] > 1:
        combined = []
        for i, results in enumerate(all_iterations):
            if i < exp['warmupBuffer']:
                continue
            for run in results:
                run['iteration'] = i
                if 'vmID' in run:
                    run['vmID[iteration]'] = run['vmID'] + "[" + str(i) + "]"
            combined.extend(results)
        if combined:
            print("\ncombining %d run(s), dropping iterations < %d"
                  % (len(combined), exp['warmupBuffer']))
            base = os.path.join(args.out, "%s-%s-COMBINED" % (args.name, exp['experimentName']))
            write_file(base, report(combined, exp), exp['openCSV'])
        else:
            print("nothing left to combine after the warmup buffer")

    failed = sum(1 for r in all_iterations if not r)
    sys.exit(1 if failed == exp['iterations'] else 0)


if __name__ == '__main__':
    main()
