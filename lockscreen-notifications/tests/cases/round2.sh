#!/usr/bin/env bash
# Round 2 - text edge cases and combined hints.
#
# Six cards: unicode and D-Bus escapes, a long summary, a notification with
# no summary, three hints at once, and two cards from the same app with
# different summaries. A seventh notification is withdrawn immediately:
# it must leave the list, proving reason-3 handling.

run_round() {
  local round=round2 png="$FIXTURES/avatar.png"
  [ -r "$png" ] || die "missing $png (run tests/make_fixtures.sh)"

  info "unicode, accents and escaped quotes/backslashes"
  send "$round" withdraw "Café Corner" "" "Crème brûlée ☕ — 5€" \
    'He said "hi" \\ and left' 0 >/dev/null
  wait_commit

  info "very long summary (character limit applies)"
  send "$round" withdraw "News Digest" "" \
    "This is a deliberately very long summary line that keeps going far beyond the width of the card, so it must be truncated by the title-length setting before it reaches the edge" \
    "Short body" 0 >/dev/null
  wait_commit

  info "empty summary, body only"
  send "$round" withdraw "Only Body" "" "" "This notification has no summary at all" 0 >/dev/null
  wait_commit

  info "desktop-entry + urgency + image-path together"
  send "$round" withdraw "Signal" "" "Combined Hints" "All three hints on one notification" 0 \
    "desktop-entry" "s" "org.signal.Signal" \
    "urgency" "y" 2 \
    "image-path" "s" "file://$png" >/dev/null
  wait_commit

  info "same app, two different summaries -> two cards"
  send "$round" withdraw "Signal" "" "Photo received" "One message" 0 \
    "desktop-entry" "s" "org.signal.Signal" >/dev/null
  wait_commit
  send "$round" withdraw "Signal" "" "Voice message" "Another message" 0 \
    "desktop-entry" "s" "org.signal.Signal" >/dev/null
  wait_commit

  info "withdrawn by its app right after arrival (reason 3)"
  local gone
  gone=$(send "$round" withdraw "Signal" "" "Vanishing Message" "Gone in a moment" 0 \
    "desktop-entry" "s" "org.signal.Signal")
  wait_commit
  close_notify "$gone"
  flush_runtime
  if wait_for_withdrawal "$gone"; then
    pass "immediately withdrawn notification left the list"
    forget "$round" "$gone"
  else
    fail "withdrawn notification $gone was not removed"
  fi
}

checklist() {
  cat <<'EOF'
Round 2 checklist (six cards, newest first):

  1. Signal - "Voice message"                  separate from "Photo received"
  2. Signal - "Photo received"                 same app, different summary
  3. Signal - "Combined Hints"                 critical style + avatar PNG + Signal icon
  4. Only Body - "This notification has no..."  empty summary: check the header
  5. News Digest - "This is a deliberately..."  truncated with an ellipsis
  6. Café Corner - "Crème brûlée ☕ — 5€"       accents and symbols intact

Must NOT appear: "Vanishing Message" (withdrawn by its app).
EOF
}
