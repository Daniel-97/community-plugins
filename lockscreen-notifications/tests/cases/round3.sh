#!/usr/bin/env bash
# Round 3 - capacity and ordering.
#
# Eight different senders arrive in order. The widget renders at most
# max_items cards (default 6), newest first, while all eight stay in the
# stored list: cleanup later proves all eight were captured.

run_round() {
  local round=round3 i
  local -a apps=(
    "Alpha Notes" "Bravo Mail" "Charlie Chat" "Delta Music"
    "Echo Photos" "Foxtrot Files" "Golf Games" "Hotel Weather"
  )

  for i in "${!apps[@]}"; do
    local n=$((i + 1))
    if [ "${apps[$i]}" = "Echo Photos" ]; then
      info "sender $n: unknown desktop-entry, falls back through app name"
      send "$round" withdraw "${apps[$i]}" "" "Notification $n" \
        "Sent by ${apps[$i]}" 0 "desktop-entry" "s" "org.example.MissingApp" >/dev/null
    else
      info "sender $n: ${apps[$i]}"
      send "$round" withdraw "${apps[$i]}" "" "Notification $n" \
        "Sent by ${apps[$i]}" 0 >/dev/null
    fi
    wait_commit 0.6
  done
}

checklist() {
  cat <<'EOF'
Round 3 checklist (max_items defaults to 6, newest first):

  Visible:
    1. Hotel Weather - "Notification 8"
    2. Golf Games - "Notification 7"
    3. Foxtrot Files - "Notification 6"
    4. Echo Photos - "Notification 5"      generic glyph (desktop-entry missing)
    5. Delta Music - "Notification 4"
    6. Charlie Chat - "Notification 3"

  Must NOT be visible (beyond max_items, still stored):
    Bravo Mail - "Notification 2"
    Alpha Notes - "Notification 1"

With order = oldest the same six messages appear reversed; with
max_items = 8 all eight appear. Both are settings checks, not test failures.
EOF
}
