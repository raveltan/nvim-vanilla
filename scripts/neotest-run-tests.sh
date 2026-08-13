#!/usr/bin/env bash
# Wrapper for fl-gaf neotest integration.
#
# Delegates to bin/run-tests so that Docker infrastructure namespacing
# (GAF_TEST_WORKER_ID), setup, and teardown are handled by the upstream
# tool — we don't reimplement any of it here.
#
# Three transformations:
# 1. --filter is normalised to the one-arg "--filter=VALUE" form. neotest-phpunit
#    emits the two-arg form ("--filter" "VALUE"), but bin/run-tests' top-level
#    flag loop only collects args matching --*, so a bare value gets dropped and
#    phpunit ends up with `--filter <test_path>` — no test matches, no junit XML.
# 2. --filter values have spaces re-encoded to \s. bin/run-tests word-splits
#    flags via `read -r -a flag_args <<< "$1"`, which would otherwise shred the
#    value (neotest-phpunit emits filters like "::testName( with data set .*)?$").
#    PHPUnit's --filter is PCRE so \s matches the same characters.
# 3. --log-junit is redirected to a project-local temp file (Docker only
#    mounts the project dir), then copied to the path neotest expects.
#
# Always runs with SETUP=false. Infrastructure must be brought up explicitly
# via <leader>tx (which calls `bin/run-tests setup`). bin/run-tests recovers
# the worker ID from .cache/gaf_session_* and reuses the namespaced silo.
# If no session exists, bin/run-tests bails with "Services are not running".

set -eo pipefail

find_project_root() {
    local dir="$1"
    while [[ "$dir" != "/" && -n "$dir" ]]; do
        if [[ -x "$dir/bin/run-tests" ]]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

TEST_PATH=""
PASSTHROUGH=()
ORIGINAL_JUNIT=""
NEXT_IS_FILTER=0

for arg in "$@"; do
    if [[ $NEXT_IS_FILTER -eq 1 ]]; then
        # Merge two-arg "--filter VALUE" into one-arg "--filter=VALUE" form.
        # bin/run-tests' top-level loop only collects args matching --*, so a bare
        # value would be dropped, leaving phpunit with --filter <next-arg> and no
        # test match. Spaces also re-encoded to \s so the later read -r -a split
        # keeps the value intact.
        PASSTHROUGH+=("--filter=${arg// /\\s}")
        NEXT_IS_FILTER=0
    elif [[ "$arg" == --filter=* ]]; then
        value="${arg#--filter=}"
        PASSTHROUGH+=("--filter=${value// /\\s}")
    elif [[ "$arg" == "--filter" ]]; then
        NEXT_IS_FILTER=1
    elif [[ "$arg" == --log-junit=* ]]; then
        ORIGINAL_JUNIT="${arg#--log-junit=}"
    elif [[ -z "$TEST_PATH" && "$arg" != --* ]]; then
        TEST_PATH="$arg"
    else
        PASSTHROUGH+=("$arg")
    fi
done

if [[ -z "$TEST_PATH" ]]; then
    echo "Error: No test path provided" >&2
    exit 1
fi

# Canonicalize TEST_PATH (resolve symlinks + relative segments) so prefix
# stripping works whether neotest gave us an absolute or relative path,
# and whether the project root was reached via a symlink (e.g. worktree).
if [[ ! -e "$TEST_PATH" ]]; then
    echo "Error: Test path does not exist: $TEST_PATH" >&2
    exit 1
fi
TEST_PATH=$(realpath "$TEST_PATH")

PROJECT_ROOT=$(find_project_root "$TEST_PATH")
if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT=$(find_project_root "$(pwd)")
fi
if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: Could not find project root (no bin/run-tests found)" >&2
    exit 1
fi
PROJECT_ROOT=$(realpath "$PROJECT_ROOT")

cd "$PROJECT_ROOT"

# bin/run-tests requires a relative path matching ^test/{functional,unit}, etc.
# Strip project root prefix.
if [[ "$TEST_PATH" != "$PROJECT_ROOT/"* ]]; then
    echo "Error: Test path '$TEST_PATH' is outside project root '$PROJECT_ROOT'" >&2
    exit 1
fi
TEST_PATH="${TEST_PATH#$PROJECT_ROOT/}"

# Redirect --log-junit to a path inside the Docker bind-mount.
LOCAL_JUNIT=""
if [[ -n "$ORIGINAL_JUNIT" ]]; then
    mkdir -p "${PROJECT_ROOT}/.cache"
    LOCAL_JUNIT="${PROJECT_ROOT}/.cache/neotest-junit-$$.xml"
    PASSTHROUGH+=("--log-junit=${LOCAL_JUNIT}")
fi

# Coverage opt-in: set NEOTEST_COVERAGE=1 in the environment. The cobertura flag
# is injected here rather than via neotest extra_args because neotest-phpunit's
# build_spec drops args.extra_args entirely. bin/gaf-php auto-enables xdebug
# coverage mode whenever any --coverage-* flag is present.
if [[ "${NEOTEST_COVERAGE:-}" == "1" ]]; then
    mkdir -p "${PROJECT_ROOT}/coverage"
    PASSTHROUGH+=("--coverage-cobertura=coverage/cobertura.xml")
fi

# Debug opt-in: <leader>tD toggles GAF_DEBUG=1. bin/run-tests --debug enables
# xdebug in the test container, which connects to a host listener on :9003 —
# this config ships no DAP, so start that listener from the full config (`gv`).
if [[ "${GAF_DEBUG:-}" == "1" ]]; then
    PASSTHROUGH+=("--debug")
fi

# Profile opt-in: set NEOTEST_PROFILE=1 in the environment. bin/run-tests
# --profile enables xdebug profile mode for the test container; cachegrind.out.*
# snapshots land on the remote /tmp and are pulled with the full config's
# :GafXdebugProfile* commands (`gv`), which this config does not ship.
if [[ "${NEOTEST_PROFILE:-}" == "1" ]]; then
    PASSTHROUGH+=("--profile")
fi

EXIT_CODE=0
SETUP=false ./bin/run-tests "$TEST_PATH" "${PASSTHROUGH[@]}" || EXIT_CODE=$?

if [[ -n "$LOCAL_JUNIT" && -f "$LOCAL_JUNIT" && -n "$ORIGINAL_JUNIT" ]]; then
    mkdir -p "$(dirname "$ORIGINAL_JUNIT")"
    cp "$LOCAL_JUNIT" "$ORIGINAL_JUNIT"
    rm -f "$LOCAL_JUNIT"
fi

exit $EXIT_CODE
