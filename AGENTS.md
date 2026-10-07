# Working agreement for build agents

Read `docs/SPEC.md` first. The interfaces in `src/interfaces/` are frozen.

## Sandbox workflow (avoids Foundry cache collisions between parallel agents)
1. Make a private copy: `mkdir -p ../montions-wt && rsync -a --delete --exclude .git --exclude 'out*' --exclude 'cache*' --exclude node_modules ./ ../montions-wt/<your-name>/` (run from the repo root), then `cd ../montions-wt/<your-name>` and work/test there (`forge build`, `forge test`).
2. Only create/edit the paths you own (SPEC §2). Put tests under your own `test/<area>/`.
3. When your tests pass, copy ONLY your owned files back into the main repo at the same relative paths
   (`/home/arg/projects/hack/metropolis/montions/...`). Never edit another owner's files, never edit `src/interfaces/*`.
4. If you need a dependency that another agent owns and it is not in the main repo yet, write a minimal local stub in your sandbox only (do not copy it back).
5. NEVER run `git add/commit/push` or touch `.git`. The main agent commits.
6. Report: files delivered, test results (paste the `forge test` summary), deviations from SPEC, open risks.
