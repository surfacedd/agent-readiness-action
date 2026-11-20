#!/usr/bin/env bash
# Runs the action's steps locally, the way the GitHub runner would (an `act`-style emulation without
# Docker): the `run:` blocks are taken from action.yml and executed with bash, with the env each
# step declares, against a fake release (file:// URLs) holding the built binary and the real
# installer, and against the fixture sites shared with the Rust tests.
#
#   integrations/github-action/test/run.sh [path/to/surfacedd-check]
# Default binary: target/release/surfacedd-check (then target/debug).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
action="$(cd "$here/.." && pwd)"
repo="$(cd "$action/../.." && pwd)"
bin="${1:-}"
for b in "$bin" "$repo/target/release/surfacedd-check" "$repo/target/debug/surfacedd-check"; do
  if [ -n "$b" ] && [ -x "$b" ]; then bin="$b"; break; fi
done
[ -x "$bin" ] || { echo "build surfacedd-check first (cargo build -p sd-check --release)"; exit 1; }

work="$(mktemp -d)"
pids=()
cleanup() { for p in "${pids[@]:-}"; do { kill "$p" && wait "$p"; } 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }

# --- A fake release with this machine's asset ----------------------------------------------------
case "$(uname -s)/$(uname -m)" in
  Darwin/*) asset=surfacedd-check-macos-universal ;;
  Linux/x86_64) asset=surfacedd-check-linux-x64 ;;
  Linux/aarch64) asset=surfacedd-check-linux-arm64 ;;
  *) asset=surfacedd-check-windows-x64.exe ;;
esac
rel="$work/release"
mkdir -p "$rel"
cp "$bin" "$rel/$asset"
cp "$repo/scripts/install-check.sh" "$rel/install-check.sh"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
echo "$(sha "$rel/$asset")  $asset" > "$rel/surfacedd-check-SHA256SUMS"

# --- The action's steps --------------------------------------------------------------------------
# Extract the `run: |` block of step N (1-based) from action.yml.
step_script() {
  awk -v want="$1" '
    /^    - name:/ { n++ }
    n == want && /^      run: \|/ { on = 1; next }
    on && /^        / { sub(/^        /, ""); print; next }
    on && !/^        / && NF { on = 0 }
  ' "$action/action.yml"
}
for n in 1 2; do
  s="$(step_script $n)"
  [ -n "$s" ] || { echo "no run block for step $n"; exit 1; }
  if grep -q '\${{' <<<"$s"; then echo "step $n uses \${{ }} inside run: (must go through env)"; exit 1; fi
done

serve() { # site → $origin (not in a subshell, so the server is stopped on exit)
  local out="$work/serve-$1"
  python3 "$here/serve_fixture.py" "$repo/crates/sd-check/tests/fixtures/sites/$1" > "$out" &
  pids+=($!)
  for _ in $(seq 50); do [ -s "$out" ] && break; sleep 0.1; done
  origin="$(head -1 "$out")"
}

# run_action <name> <url> <fail-under> → sets $code; files in $job/
run_action() {
  job="$work/job-$1"
  mkdir -p "$job/tmp"
  : > "$job/summary.md"; : > "$job/output"; : > "$job/path"
  local common=(
    GITHUB_ACTION_PATH="$action" RUNNER_TEMP="$job/tmp" GITHUB_STEP_SUMMARY="$job/summary.md"
    GITHUB_OUTPUT="$job/output" GITHUB_PATH="$job/path" SURFACEDD_CHECK_BASE_URL="file://$rel" PATH="$PATH"
    HOME="$job"
  )
  set +e
  env -i "${common[@]}" VERSION=latest DIR="$job/tmp/surfacedd-check" \
    bash -e -c "$(step_script 1)" > "$job/install.log" 2>&1
  code=$?
  if [ $code -eq 0 ]; then
    env -i "${common[@]}" URL="$2" FAIL_UNDER="$3" MAX_PAGES=20 ALLOW_PRIVATE=true SUMMARY=true \
      BIN="$job/tmp/surfacedd-check/surfacedd-check" \
      bash -e -c "$(step_script 2)" > "$job/check.log" 2>&1
    code=$?
  fi
  set -e
}
out() { grep "^$1=" "$job/output" | tail -1 | cut -d= -f2-; }

echo "Action test (binary: $bin)"

serve shop; shop="$origin"
run_action shop "$shop/" 90
[ "$code" = 5 ] && ok "shop under 90 fails the step with exit 5" || bad "shop: exit $code (want 5); $(cat "$job/check.log")"
[ "$(out passed)" = false ] && ok "outputs.passed=false" || bad "passed=$(out passed)"
score="$(out score)"
[[ "$score" =~ ^[0-9]+$ ]] && [ "$score" -lt 90 ] && ok "outputs.score=$score" || bad "score=$score"
grep -q "^## Agent readiness: $score/100 · failed (under 90)$" "$job/summary.md" && ok "summary headline" || bad "summary headline: $(head -1 "$job/summary.md")"
grep -q '^| Weight | Area | Rule | Finding |$' "$job/summary.md" && ok "summary table of problems" || bad "no problem table"
grep -q '`act.form-labels`' "$job/summary.md" && ok "summary lists act.form-labels" || bad "act.form-labels missing"
grep -q '<details><summary><code>act.no-captcha</code>: how to fix</summary>' "$job/summary.md" && ok "fix details" || bad "no fix details"
grep -q '^::error title=Agent readiness under 90::' "$job/check.log" && ok "error annotation in the log" || bad "no annotation"
[ "$(cat "$job/path")" = "$job/tmp/surfacedd-check" ] && ok "binary dir added to GITHUB_PATH" || bad "GITHUB_PATH: $(cat "$job/path")"
grep -q "^Checksum OK " "$job/install.log" && ok "installer verified the checksum" || bad "install log: $(cat "$job/install.log")"

serve clean; clean="$origin"
run_action clean "$clean/" 90
[ "$code" = 0 ] && ok "clean site passes" || bad "clean: exit $code; $(cat "$job/check.log")"
[ "$(out passed)" = true ] && [ "$(out score)" = 100 ] && ok "outputs passed=true score=100" || bad "outputs: $(cat "$job/output")"
grep -q "^## Agent readiness: 100/100 · passed (90 or more)$" "$job/summary.md" && ok "passing headline" || bad "headline: $(head -1 "$job/summary.md")"
grep -q "^No problems found.$" "$job/summary.md" && ok "no problems" || bad "problems listed"

run_action noscore "$clean/" ""
[ "$code" = 0 ] && grep -q "^## Agent readiness: 100/100$" "$job/summary.md" && ok "no fail-under: never fails" || bad "no threshold: exit $code"

# Private address without allow-private: the error is reported, the step fails with exit 1.
job="$work/job-private"; mkdir -p "$job/tmp"; : > "$job/summary.md"; : > "$job/output"; : > "$job/path"
set +e
env -i GITHUB_ACTION_PATH="$action" RUNNER_TEMP="$job/tmp" GITHUB_STEP_SUMMARY="$job/summary.md" \
  GITHUB_OUTPUT="$job/output" GITHUB_PATH="$job/path" PATH="$PATH" URL="$clean/" FAIL_UNDER=50 MAX_PAGES=5 \
  ALLOW_PRIVATE=false SUMMARY=true BIN="$bin" bash -e -c "$(step_script 2)" > "$job/check.log" 2>&1
code=$?
set -e
[ "$code" = 1 ] && grep -q "^## Agent readiness check failed" "$job/summary.md" && ok "private address refused without allow-private" || bad "private: exit $code"

# Tampered binary: the install step fails and nothing runs.
printf 'x' >> "$rel/$asset"
run_action tampered "$clean/" 50
[ "$code" != 0 ] && grep -q "checksum mismatch" "$job/install.log" && ok "tampered download refused" || bad "tampered: exit $code; $(cat "$job/install.log")"
[ ! -e "$job/tmp/surfacedd-check/surfacedd-check" ] && ok "nothing installed" || bad "tampered binary installed"

if [ "$fails" = 0 ]; then echo "All action checks passed."; else echo "$fails action check(s) failed."; exit 1; fi
