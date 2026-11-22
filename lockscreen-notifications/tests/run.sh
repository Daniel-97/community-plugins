#!/usr/bin/env bash
# Integration test battery for the Lockscreen Notification Widget.
#
#   tests/run.sh round1     send round 1, assert, keep the cards on screen
#   tests/run.sh round2     text edge cases
#   tests/run.sh round3     capacity and ordering
#   tests/run.sh expiry     expiry is not dismissal (leaves one card)
#   tests/run.sh cleanup    withdraw everything this battery sent
#   tests/run.sh all        rounds 1-3, waiting for Enter between them
#   tests/run.sh check      environment and log health only
#
# Exit code 0 means every automatic assertion passed. Rendering is checked
# visually from the checklist printed at the end of each round.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

usage() {
  cat <<'EOF'
usage: tests/run.sh [round1|round2|round3|expiry|cleanup|all|check]

  round1   grouping, urgency, image-path, app_icon path, unknown sender
  round2   unicode, long summary, empty summary, combined hints, withdrawal
  round3   eight senders against max_items and order
  expiry   short expire timeout stays in the list
  cleanup  withdraw every recorded test notification
  all      rounds 1-3 with a pause between them
  check    environment and log health only
EOF
}

run_case() {
  # shellcheck source=/dev/null
  source "$HERE/cases/$1.sh"
  run_round
}

report() {
  printf '\n%s\n' "$(checklist)"
}

cmd=${1:-all}

case "$cmd" in
  round1|round2|round3)
    require_running
    cleanup_round "$cmd" silent
    log_mark
    dnd_enable
    trap 'dnd_restore; exit 130' INT TERM
    run_case "$cmd"
    flush_runtime
    assert_no_luau_errors
    report
    printf '\nDND stays on while these cards are on screen.\nRun: tests/run.sh cleanup   (withdraws them and restores DND)\n'
    ;;
  expiry)
    require_running
    cleanup_round expiry silent
    log_mark
    dnd_enable
    trap 'dnd_restore; exit 130' INT TERM
    run_case expiry
    flush_runtime
    assert_no_luau_errors
    report
    printf '\nDND stays on until: tests/run.sh cleanup   (restores it and clears the card)\n'
    ;;
  cleanup)
    require_running
    cleanup_all
    dnd_restore
    sleep 1.5 # let the settings-triggered service restart settle
    ;;
  check)
    require_running
    log_mark
    assert_no_luau_errors
    pass "environment looks healthy"
    ;;
  all)
    require_running
    for round in round1 round2 round3; do
      cleanup_round "$round" silent
      printf '\n=== %s ===\n' "$round"
      log_mark
      dnd_enable
      trap 'dnd_restore; exit 130' INT TERM
      run_case "$round"
      flush_runtime
      assert_no_luau_errors
      report
      read -r -p $'\nCheck the lockscreen, then press Enter to withdraw and continue... ' _
      cleanup_round "$round"
      dnd_restore
    done
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
