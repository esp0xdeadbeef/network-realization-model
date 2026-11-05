# AGENTS.md: network-realization-model

Instructions for AI agents working in this repository.

## CI: check the last GitHub Actions run, then fix what it reports

GitHub Actions is the source of truth for whether this repository is healthy.
The workflows live in `.github/workflows/`.

`ci.yml` runs on every push to `main`, on every pull request, and on demand.
It has one job:

- `flake-check` runs `nix flake check`, which builds this repository's `checks`
  outputs. Those checks *are* the test suite here.

### Before you start, and before you call a task done

```bash
gh run list --limit 5                # newest runs first
gh run view <run-id>                 # per-job pass/fail
gh run view <run-id> --log-failed    # only the failing step's output
```

Do not report work as complete while the newest run on `main` is red. Quote the
run id and its conclusion in your summary.

### Reproducing a failure

```bash
nix flake check -L --show-trace
```

### Fixing rules

1. Fix the root cause. A red job is a defect in this repository — never
   "pre-existing", "environmental", "a flake", or "not mine".
2. Never make a check pass by deleting it, weakening an assertion, or adding a
   skip. A check that passes because it stopped asserting is still a failure.
3. If the documentation a check asserts is stale, update the documentation *and*
   the check to the current contract.
