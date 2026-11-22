#!/usr/bin/env bash
# Round 1 - core rendering.
#
# Six cards: grouping with a badge, same app with a different summary,
# critical urgency, a PNG sent through image-path, a JPEG sent through the
# icon field, and an unknown sender falling back to the generic glyph.
# Also verifies that transient and empty notifications never reach the list.

run_round() {
  local round=round1 id
  local png="$FIXTURES/avatar.png"
  local jpg="$FIXTURES/photo.jpg"
  [ -r "$png" ] || die "missing $png (run tests/make_fixtures.sh)"
  [ -r "$jpg" ] || die "missing $jpg (run tests/make_fixtures.sh)"

  info "group: three messages with the same app and summary -> one card, badge (3)"
  local body
  for body in "Are we still on for 8?" "I'll bring dessert." "See you later!"; do
    send "$round" withdraw "Signal" "" "John Doe" "$body" 0 \
      "desktop-entry" "s" "org.signal.Signal" >/dev/null
    wait_commit
  done

  info "same app, different summary -> a separate card"
  send "$round" withdraw "Signal" "" "Photo received" "Take a look at this" 0 \
    "desktop-entry" "s" "org.signal.Signal" >/dev/null
  wait_commit

  info "critical urgency (byte 2)"
  send "$round" withdraw "Reminders" "" "Meeting in 5 minutes" "The stand-up starts now" 0 \
    "desktop-entry" "s" "net.thunderbird.Thunderbird" "urgency" "y" 2 >/dev/null
  wait_commit

  info "image-path with a small PNG over a file:// URI"
  send "$round" withdraw "Library" "" "Book cover" "Cover image sent by the app" 0 \
    "image-path" "s" "file://$png" >/dev/null
  wait_commit

  info "raw absolute path in the icon field (large JPEG)"
  send "$round" withdraw "Wallpaper" "$jpg" "Image from app_icon" "The icon field holds a path" 0 >/dev/null
  wait_commit

  info "unknown sender: no hints, no icon -> generic glyph"
  send "$round" withdraw "Unknown Sender" "" "No icon available" "This sender ships nothing" 0 >/dev/null
  wait_commit

  info "transient notification (must be skipped)"
  notify "Transient" "" "Should Not Appear" "Transient notifications are not missed" 0 \
    "desktop-entry" "s" "com.valvesoftware.Steam" "transient" "b" true >/dev/null
  wait_commit

  info "empty notification (must be ignored)"
  notify "" "" "" "" 0 >/dev/null
  wait_commit

  if log_since | grep -q 'transient notification skipped (Should Not Appear)'; then
    pass "transient notification was skipped"
  else
    fail "transient notification was not skipped (or the watcher is not reading)"
  fi
}

checklist() {
  cat <<'EOF'
Round 1 checklist (six cards, newest first):

  1. Unknown Sender - "No icon available"      generic notification glyph
  2. Wallpaper - "Image from app_icon"         the blue JPEG as leading image
  3. Library - "Book cover"                    the orange avatar PNG as leading image
  4. Reminders - "Meeting in 5 minutes"        critical-urgency styling
  5. Signal - "Photo received"                 separate from the group below
  6. Signal - "John Doe" with badge (3)        one card for three messages

Must NOT appear: "Should Not Appear" and an empty card.
EOF
}
