# Test battery

Integration tests for the Lockscreen Notification Widget. They run against
the real notification daemon and a running Noctalia instance, because the
bug class this plugin has hit (messaging order, nested variants, icon and
image hints) only shows up on the live D-Bus stream.

## Requirements

- Noctalia running, with this plugin enabled and a lockscreen widget placed.
- `dbus-monitor`, `pgrep`, `busctl`, `gdbus` on `PATH`.
- ImageMagick once, to build the image fixtures.

## Layout

```
tests/
  run.sh            entry point (see usage below)
  lib.sh            send/close helpers and log assertions
  make_fixtures.sh  builds fixtures/avatar.png and fixtures/photo.jpg
  cases/            one file per round (run_round + checklist)
  .state/           ids of notifications to withdraw (generated)
```

## Usage

```sh
tests/make_fixtures.sh    # once, or after removing fixtures/
tests/run.sh round1       # send, assert, keep cards for visual inspection
tests/run.sh cleanup      # withdraw every recorded test notification
```

`round1`, `round2`, `round3` and `expiry` can be run independently. `all`
runs the first three with a pause between rounds: press Enter after checking
the lockscreen, and that round is withdrawn before the next one starts.

Not every claim can be asserted from a log, so each round prints a checklist
of what the lockscreen must show. The automatic part covers:

- every notification was captured and correlated to its daemon id: cleanup
  closes each id and requires a matching `notification <id> withdrawn` line;
- transient notifications are skipped;
- reason-3 withdrawals remove the entry;
- reason-1 expiry does **not** remove it;
- no Luau load or runtime errors appear in the log during the round.

Test notifications use a never-expire timeout so their ids stay live until
cleanup can close them. To keep their toasts off the desktop, the battery
enables Do Not Disturb before sending and leaves it on while the cards are
inspected. `cleanup` restores the previous DND state only after every
withdrawal assertion has run: because changing DND is a settings change,
that restore also restarts the plugin service and clears the memory-only
list, leaving a clean slate.

Noctalia drains a plugin's stream only while one of its widgets is being
rendered. With the screen unlocked the battery therefore opens and closes
the lockscreen widget editor around its assertions (`lockscreen-widgets-
edit`/`exit`), which forces a render without locking the session. Expect a
brief editor overlay at each checkpoint; it is closed automatically.
Everything else (icons, images, urgency colour, grouping badge, truncation,
ordering, empty headers) is on the printed checklist.

## Test data

All names and messages are invented (John Doe, Café Corner, and so on).
Nothing is read from real notifications. The list is memory-only, so test
cards never touch disk and disappear when the plugin service restarts.

## Settings matrix

The default run uses the plugin defaults. To exercise the settings, change
one, then run the rounds again:

| Setting        | What to check                                                        |
|----------------|----------------------------------------------------------------------|
| `max_items`    | round 3 with 8: all eight appear, or exactly the configured number   |
| `group_notifications` | off: round 1 gives four Signal cards instead of one group      |
| `show_icons` / `show_age` | off: cards keep the same height, icon/age disappear       |
| `card_background` | round 1: subtle / solid / liquid glass / none changes the card fill |
| `summary_length` | round 2: the long title truncates at 40, 60 or 90 characters      |
| `preview_when_empty` | with an empty list, `max_items` sample cards appear and the header says Preview |
| `order`        | `oldest` reverses round 3's visible cards                            |
| `show_body`    | round 2: bodies appear under each summary                            |
| `age_format`   | `absolute` shows a clock time, `both` shows time and relative age    |
| `language`     | `it` translates the settings UI only; cards keep app text            |

## Not covered

`image-data` (inline pixels, sent by Signal for avatars) is not decodable in
the plugin sandbox; the replay of a real Signal message is a manual check.
Notifications are stored in memory only, so restart and crash behaviour is
also manual.
