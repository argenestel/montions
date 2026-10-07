Pricing reference and verification
==================================

From the repository root:

```sh
python3 test/pricing/generate_golden.py --measured-max-error-wad 275139136
forge build
FOUNDRY_CONFIG=test/pricing/foundry.toml forge test -vv
```

The owned test configuration preserves the root Foundry settings and adds
read-only permission for `test/pricing/golden.json`. The root configuration only
allows access to `deployments`, and is outside this implementer's ownership.
When integrating, grant `{ access = "read", path = "./test/pricing" }` in the
main Foundry configuration to allow an ordinary `forge test` invocation.
Use the environment variable above rather than `--config-path`, which changes
Foundry's project root to the configuration file's directory.

The dependency-free generator uses Python `math.erf`, a fixed random seed, 365-day
years, 2,021 CDF samples (including branch/clamp boundaries), and 1,817 digital
samples. The Foundry tests load all reference rows with `vm.readFile` /
`vm.parseJson`, compare each row, and fuzz reference-row selection and properties.

Measured maximum absolute probability errors:

- CDF: 159 WAD units = 1.59e-16.
- Digital: 275,139,136 WAD units = 2.75139136e-10.

Both are below the SPEC's 1e-4 tolerance. Measurements are against this finite
reference table, not a formal proof for every possible input. A separate 100,000
run adjacent-input CDF monotonicity fuzz check also passed.

Warm external harness calls consumed 5,974 gas for CDF and 8,732 gas for digital
pricing in the final implementation; tests impose limits of 30,000 and 50,000 gas.
This includes external-call overhead and is not an isolated internal-library
benchmark.

Positive time and volatility can underflow the WAD total volatility; ATM then
uses its continuous limiting probability of 0.5. Actual zero time/volatility
uses the resolver's deterministic `spot >= strike` / `spot < strike` convention.
Prices, annual volatility, and maturity are bounded as documented in PricingLib;
those extreme-input caps prioritize safe execution outside realistic quoting
ranges.
