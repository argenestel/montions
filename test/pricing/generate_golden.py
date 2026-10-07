#!/usr/bin/env python3
"""Reproduce the pricing reference using Python's math.erf (no dependencies).

Run from the repository root. --measured-max-error-wad records the maximum
absolute error reported by the Foundry golden tests, in probability WAD units.
"""
import argparse
import json
import math
import random
from pathlib import Path

WAD = 10**18
YEAR = 365 * 24 * 60 * 60


def cdf(x):
    return (1 + math.erf(x / math.sqrt(2))) / 2


def generate():
    xs = [i * 10**16 for i in range(-1000, 1001)]
    # Exercise the rational / continued-fraction boundary and saturation closely.
    xs += [sign * (base + offset) for sign in (-1, 1)
           for base in (7071067811865470000, 9 * WAD)
           for offset in (-10**12, -1, 0, 1, 10**12)]
    rows = []
    for spot in (10**16, WAD, 180 * WAD):
        for ratio in (0.01, 0.5, 0.9, 0.99, 1, 1.01, 1.1, 2, 100):
            for vol in (1, 10**12, 10**17, 8 * 10**17, 4 * WAD):
                for secs in (0, 1, 60, 3600, 86400, YEAR):
                    rows.append((spot, int(spot * ratio), vol, secs))
    rng = random.Random(20261007)
    for _ in range(1000):
        spot = int(10 ** rng.uniform(12, 25))
        strike = int(spot * math.exp(rng.uniform(-5, 5)))
        rows.append((spot, strike, int(10 ** rng.uniform(12, 19)), rng.randrange(1, 10 * YEAR)))
    rows += [(0, WAD, WAD, YEAR), (WAD, 0, WAD, YEAR), (0, 0, 0, 0),
             (WAD, WAD, 0, YEAR), (2 * WAD, WAD, 0, YEAR),
             (1, 10**36, WAD, YEAR), (10**36, 1, WAD, YEAR)]
    probs = []
    for spot, strike, vol, secs in rows:
        if strike == 0:
            p = 1
        elif spot == 0:
            p = 0
        elif vol == 0 or secs == 0:
            p = int(spot >= strike)
        else:
            tv = vol / WAD * math.sqrt(secs / YEAR)
            p = cdf((math.log(spot / strike) - tv * tv / 2) / tv)
        probs.append(round(p * WAD))
    return dict(cdfX=xs, cdfExpected=[round(cdf(x / WAD) * WAD) for x in xs],
                spot=[r[0] for r in rows], strike=[r[1] for r in rows],
                vol=[r[2] for r in rows], seconds=[r[3] for r in rows], expected=probs)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--measured-max-error-wad', type=int)
    args = parser.parse_args()
    data = generate()
    data['metadata'] = dict(reference='Python math.erf; deterministic seed 20261007',
                            yearSeconds=YEAR, absoluteErrorLimitWad=10**14,
                            measuredMaxErrorWad=args.measured_max_error_wad)
    Path(__file__).with_name('golden.json').write_text(json.dumps(data, indent=2) + '\n')
