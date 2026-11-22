#!/usr/bin/env bash
# Round 5 (standalone) - expiry is not dismissal.
#
# A notification with a short expire timeout disappears from the daemon,
# but a missed notification must stay in the list: only reason 3 (closed by
# the app) withdraws an entry. The card therefore stays on screen until the
# service restarts, which is by design and documented in the checklist.

run_round() {
  local round=expiry id
  info "notification with a 2.5 s timeout"
  id=$(send "$round" expire "Shop" "" "Limited Offer" "This notification expires in a moment" 2500)
  sleep 4

  if log_since | grep -q "notification $id withdrawn"; then
    fail "expired notification $id was removed (reason 1 must not withdraw)"
  else
    pass "expired notification was kept in the list (reason 1 ignored)"
  fi
}

checklist() {
  cat <<'EOF'
Expiry checklist:

  The "Shop - Limited Offer" card must still be in the list even though
  the daemon dropped the live notification seconds ago.

  This card stays until the battery restores Do Not Disturb in cleanup:
  that settings change restarts the plugin service, and the memory-only
  list is cleared with it. Run: tests/run.sh cleanup
EOF
}
