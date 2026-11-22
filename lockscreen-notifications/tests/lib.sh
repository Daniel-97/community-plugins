#!/usr/bin/env bash
# Shared helpers for the notification battery.
#
# The battery is an integration test: it talks to the real notification
# daemon, so the running Noctalia instance, the plugin and its dbus-monitor
# watcher must all be live. Everything that can be asserted from the log is
# asserted here; rendering (icons, images, colours, truncation) is checked
# visually from the checklist each round prints.

DEST=org.freedesktop.Notifications
OBJ=/org/freedesktop/Notifications
IFACE=org.freedesktop.Notifications

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(dirname "$TESTS_DIR")
FIXTURES="$TESTS_DIR/fixtures"
LOG_FILE=${NOCTALIA_LOG:-$HOME/.cache/noctalia/noctalia.log}
STATE_DIR="$TESTS_DIR/.state"

PASSES=0
FAILURES=0
MARK=0

pass() { PASSES=$((PASSES + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$1"; }
info() { printf '  ..   %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; dnd_restore 2>/dev/null || true; exit 2; }

log_mark() { MARK=$(wc -l < "$LOG_FILE"); }
log_since() { tail -n +$((MARK + 1)) "$LOG_FILE"; }

wait_commit() { sleep "${1:-0.8}"; }

# Noctalia dispatches a plugin's queued stream lines while one of its widgets
# is rendered; with the screen unlocked and the lockscreen hidden, events sit
# in the pipe. Opening the lockscreen widget editor forces a render without
# locking the session, so the runtime drains the queue and assertions see
# the real state.
flush_runtime() {
  noctalia msg lockscreen-widgets-edit >/dev/null 2>&1 || true
  sleep 1.5
  noctalia msg lockscreen-widgets-exit >/dev/null 2>&1 || true
  sleep 0.3
}

# notify <app> <icon> <summary> <body> <timeout> [hint-key hint-type hint-value]...
# Prints the notification id assigned by the daemon.
notify() {
  local app=$1 icon=$2 summary=$3 body=$4 timeout=$5
  shift 5
  local hints=$(( $# / 3 ))
  busctl --user call "$DEST" "$OBJ" "$IFACE" Notify susssasa{sv}i \
    "$app" 0 "$icon" "$summary" "$body" 0 "$hints" "$@" "$timeout" | awk '{print $2}'
}

# send <round> <withdraw|expire> <app> <icon> <summary> <body> <timeout> [hints...]
# Sends and records the id so cleanup can withdraw it later.
send() {
  local round=$1 mode=$2
  shift 2
  local id
  id=$(notify "$@") || true
  if [ -z "${id:-}" ]; then
    # Fatal: a broken bus would make every later assertion misleading.
    die "Notify failed for summary: $3"
  fi
  mkdir -p "$STATE_DIR"
  printf '%s %s %s\n' "$round" "$mode" "$id" >> "$STATE_DIR/$round.ids"
  printf '%s\n' "$id"
}

close_notify() {
  gdbus call --session --dest "$DEST" --object-path "$OBJ" \
    --method "$IFACE.CloseNotification" "$1" >/dev/null 2>&1 || true
}

# forget <round> <id>
# Drops an id from the round state when the test already closed it and
# asserted the withdrawal itself.
forget() {
  local file="$STATE_DIR/$1.ids"
  [ -f "$file" ] || return 0
  grep -v " $2\$" "$file" > "$file.tmp" || true
  mv "$file.tmp" "$file"
}

require_running() {
  pgrep -x noctalia >/dev/null || die "Noctalia is not running."
  # Capture first: grep -q closes the pipe early and pipefail would turn the
  # resulting SIGPIPE in noctalia into a false failure.
  local plugins
  plugins=$(noctalia msg plugins list 2>/dev/null) || true
  grep -q '^daniel-97/lockscreen-notifications .*enabled' <<<"$plugins" \
    || die "The lockscreen-notifications plugin is not enabled."
  pgrep -f 'dbus-monitor.*org\.freedesktop\.Notifications' >/dev/null \
    || die "The plugin watcher (dbus-monitor) is not running."
  [ -r "$LOG_FILE" ] || die "Log is not readable: $LOG_FILE"
}

# Notifications are sent with a never-expire timeout so the ids stay live
# until cleanup can correlate them. Do Not Disturb keeps their toasts off
# the desktop without touching the D-Bus stream the plugin reads.
#
# Important: changing DND is a settings change, and Noctalia restarts plugin
# services after one. Since the list is memory-only, restoring DND right
# after sending would wipe the cards. So DND stays on while the cards are
# inspected and is restored by cleanup, after the withdrawal assertions.
DND_FILE="$STATE_DIR/dnd"

dnd_current() {
  noctalia msg notification-dnd-status 2>/dev/null | tr -d '[:space:]'
}

dnd_enable() {
  mkdir -p "$STATE_DIR"
  local current
  current=$(dnd_current)
  if [ ! -f "$DND_FILE" ]; then
    # Remember what the user had before the battery touched anything.
    printf '%s\n' "${current:-off}" > "$DND_FILE"
  fi
  if [ "$current" != "on" ]; then
    noctalia msg notification-dnd-set on >/dev/null 2>&1 || true
    sleep 1.5 # let the plugin service come back after the settings change
  fi
}

dnd_restore() {
  [ -f "$DND_FILE" ] || return 0
  local original
  original=$(cat "$DND_FILE")
  rm -f "$DND_FILE"
  [ "$original" = "on" ] || noctalia msg notification-dnd-set off >/dev/null 2>&1 || true
}

assert_no_luau_errors() {
  local out
  out=$(log_since)
  if grep -qE '\[luau\].*(failed|error)' <<<"$out"; then
    fail "Luau errors during this round:"
    grep -E '\[luau\].*(failed|error)' <<<"$out" | tail -3 | sed 's/^/       /'
  else
    pass "no Luau errors during this round"
  fi
}

# wait_for_withdrawal <id> [timeout-seconds]
# The service reads its dbus-monitor stream with a short latency, so a
# withdrawal line can land up to a second or more after CloseNotification.
wait_for_withdrawal() {
  local id=$1 limit=${2:-12} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    if log_since | grep -q "notification $id withdrawn"; then
      return 0
    fi
    sleep 0.4
  done
  return 1
}

# cleanup_round <round> [silent]
# Withdraws every recorded notification of the round and verifies, from the
# log, that each id was correlated to an entry before being removed.
cleanup_round() {
  local round=$1 silent=${2:-}
  local file="$STATE_DIR/$round.ids"
  if [ ! -f "$file" ]; then
    [ -z "$silent" ] && info "nothing recorded for $round"
    return 0
  fi

  local mark withdrew=0
  mark=$(wc -l < "$LOG_FILE")
  local -a expected=()
  while read -r _round mode id; do
    if [ "$mode" = "withdraw" ]; then
      close_notify "$id"
      expected+=("$id")
      withdrew=$((withdrew + 1))
    fi
  done < "$file"

  if [ -n "$silent" ]; then
    rm -f "$file"
    return 0
  fi

  # Drain anything the runtime queued while no widget was rendered.
  flush_runtime

  # Poll until every withdrawal has been logged (or the deadline passes).
  local start=$SECONDS missing out
  while :; do
    out=$(tail -n +$((mark + 1)) "$LOG_FILE")
    missing=0
    local id
    for id in "${expected[@]}"; do
      grep -q "notification $id withdrawn" <<<"$out" || missing=$((missing + 1))
    done
    [ "$missing" -eq 0 ] && break
    [ $((SECONDS - start)) -ge 15 ] && break
    sleep 0.5
  done

  for id in "${expected[@]}"; do
    if ! grep -q "notification $id withdrawn" <<<"$out"; then
      fail "id $id never reached the list (no withdrawal logged)"
    fi
  done

  if [ "$withdrew" -gt 0 ] && [ "$missing" -eq 0 ]; then
    pass "$withdrew notification(s) captured, correlated and withdrawn"
  fi
  rm -f "$file"
}

cleanup_all() {
  local file found=0
  for file in "$STATE_DIR"/*.ids; do
    [ -e "$file" ] || continue
    found=1
    cleanup_round "$(basename "$file" .ids)"
  done
  [ "$found" -eq 0 ] && info "no test notifications recorded"
}
