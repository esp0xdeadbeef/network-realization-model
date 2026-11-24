#!/usr/bin/env bash
# Test entrypoint: run every discovered entrypoint, serially, and report.
#
# This repository's primary test surface is `nix flake check` (the `tests/*.nix`
# checks). A few checks are shell scripts -- a source scan, a cross-repository
# contract comparison -- because they need to read files or another checkout, which
# a Nix check cannot do in the sandbox. Those live under `tests/test-*.sh` and are
# discovered through the shared `scripts/lib/discover-tests.sh` contract, so a new
# `test-*.sh` is picked up without editing this file.
#
# Serial on purpose: the shell checks here are file scans that finish in under a
# second each, and a serial runner keeps the output readable and the exit status
# unambiguous.
#
# Environment:
#   TEST_TIMEOUT_SECONDS   per-test timeout (default 600)
#
# Exit: 0 when every test passed or skipped, 1 when any failed, 2 on misuse.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="${repo_root}/tests"

if [[ ! -f "${repo_root}/scripts/lib/discover-tests.sh" ]]; then
  echo "error: scripts/lib/discover-tests.sh missing (the discovery contract is required)" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "${repo_root}/scripts/lib/discover-tests.sh"

timeout_seconds="${TEST_TIMEOUT_SECONDS:-600}"
mapfile -t names < <(discover_tests "${repo_root}")

if ((${#names[@]} == 0)); then
  echo "PASS $(basename "${repo_root}"): no shell test entrypoints (the nix checks are the surface)"
  exit 0
fi

passed=0
skipped=0
failed=0
failed_names=()

for name in "${names[@]}"; do
  log="$(mktemp)"
  status=0
  # The trace id is the file name, matching run-all-tests.sh in the sibling
  # repositories, so a case that takes `$1` sees the same value everywhere.
  # The file path has to be captured before `set --` replaces the positional
  # parameters with the trace id. Getting this wrong sources the trace id as a
  # path, which fails, and a swallowed failure makes every test PASS -- measured,
  # the first version reported 2/2 green while running nothing.
  timeout "${timeout_seconds}" bash -c '
    _file="$1"
    _trace="$(basename "${_file}" .sh)"
    set -- "${_trace}"
    source "${_file}"
  ' _ "${test_dir}/${name}" >"${log}" 2>&1 || status=$?

  if ((status == 0)) && grep -q '^SKIP ' "${log}"; then
    printf 'SKIP %s\n' "${name}"
    grep '^SKIP ' "${log}" >&2 || true
    skipped=$((skipped + 1))
  elif ((status == 0)); then
    printf 'PASS %s\n' "${name}"
    passed=$((passed + 1))
  else
    printf 'FAIL %s (exit %s)\n' "${name}" "${status}" >&2
    awk -v prefix="[${name}] " '{ print prefix $0 }' "${log}" >&2
    failed=$((failed + 1))
    failed_names+=("${name}")
  fi
  rm -f "${log}"
done

total=$((passed + skipped + failed))
printf '\n%s passed, %s skipped, %s failed of %s tests\n' "${passed}" "${skipped}" "${failed}" "${total}"

if ((failed > 0)); then
  printf 'FAIL %s: %s test(s) failed: %s\n' "$(basename "${repo_root}")" "${failed}" "${failed_names[*]}" >&2
  exit 1
fi

printf 'PASS %s: all %s shell test(s) passed or skipped\n' "$(basename "${repo_root}")" "${total}"
