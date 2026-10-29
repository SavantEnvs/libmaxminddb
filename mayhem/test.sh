#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs upstream's libtap (TAP) C tests directly — NOT through ctest, whose exit-code-only verdict
# survives the sabotage shim. Each test prints "ok N"/"not ok N" lines and a "1..N" plan; a
# neutered/empty run has no plan and is counted as a failure.
T="$SRC/build/tests"
[ -d "$T/t" ] || { echo "missing $T/t — mayhem/build.sh must build the test suite first" >&2; exit 1; }

passed=0; failed=0; skipped=0; nbin=0
cd "$SRC/t"   # upstream's ctest WORKING_DIRECTORY; tests open ./maxmind-db/test-data/...
for exe in "$T"/t/*_t "$T"/t/*-t; do
  [ -x "$exe" ] && [ -f "$exe" ] || continue
  nbin=$((nbin+1))
  out="$("$exe" 2>&1)"; rc=$?
  if printf '%s\n' "$out" | grep -q '^1\.\.0 *# *[sS][kK][iI][pP]'; then
    echo "SKIP $(basename "$exe"): $(printf '%s\n' "$out" | head -1)" >&2; skipped=$((skipped+1)); continue
  fi
  plan="$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | head -1)"
  ok="$(printf '%s\n' "$out" | grep -c '^ok ' || true)"
  notok="$(printf '%s\n' "$out" | grep -c '^not ok ' || true)"
  skip="$(printf '%s\n' "$out" | grep -c '^ok .*# [sS][kK][iI][pP]' || true)"
  if [ -z "$plan" ] || [ "$plan" -eq 0 ] || [ "$ok" -ne "$plan" ] || [ "$notok" -ne 0 ] || [ "$rc" -ne 0 ]; then
    echo "FAIL $(basename "$exe"): plan=${plan:-none} ok=$ok not_ok=$notok exit=$rc" >&2
    printf '%s\n' "$out" | grep -v '^ok ' | head -20 >&2
    failed=$((failed + notok + 1))
    passed=$((passed + ok - skip))
  else
    passed=$((passed + ok - skip)); skipped=$((skipped + skip))
  fi
done
if [ "$nbin" -lt 20 ]; then echo "only $nbin test binaries found under $T/t (expected >= 20)" >&2; failed=$((failed+1)); fi

# Known-answer probes through the real CLI (a dynamically linked, non-system binary): fixed database +
# fixed IP -> exact expected field values from MaxMind's own test fixtures.
LOOKUP="$T/bin/mmdblookup"
DB="$SRC/t/maxmind-db/test-data"
kat() {  # kat <description> <expected-substring-regex> <cmd...>
  local desc="$1" want="$2"; shift 2
  local got; got="$("$@" 2>&1)"
  if printf '%s' "$got" | grep -Eq -- "$want"; then passed=$((passed+1))
  else echo "FAIL KAT $desc: expected /$want/, got: $got" >&2; failed=$((failed+1)); fi
}
kat "City: 81.2.69.160 country"  '"GB" <utf8_string>'  "$LOOKUP" --file "$DB/GeoIP2-City-Test.mmdb" --ip 81.2.69.160 country iso_code
kat "City: 81.2.69.160 city"     '"London" <utf8_string>' "$LOOKUP" --file "$DB/GeoIP2-City-Test.mmdb" --ip 81.2.69.160 city names en
kat "City: IPv6 country"         '"DE" <utf8_string>'  "$LOOKUP" --file "$DB/GeoIP2-City-Test.mmdb" --ip 2a02:ff80::1 country iso_code
kat "Country: 89.160.20.128"     '"Sweden" <utf8_string>' "$LOOKUP" --file "$DB/GeoIP2-Country-Test.mmdb" --ip 89.160.20.128 country names en
kat "ASN: 1.128.0.0 number"      '1221 <uint32>'       "$LOOKUP" --file "$DB/GeoLite2-ASN-Test.mmdb" --ip 1.128.0.0 autonomous_system_number
kat "ASN: 1.128.0.0 org"         '"Telstra Pty Ltd"'   "$LOOKUP" --file "$DB/GeoLite2-ASN-Test.mmdb" --ip 1.128.0.0 autonomous_system_organization

emit_ctrf "libtap-c-tests" "$passed" "$failed" "$skipped"
