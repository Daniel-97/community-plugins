--!nonstrict
-- Lockscreen Notifications watcher — headless [[service]] entry.
--
-- Keeps a plugin-side list of "unread" notifications:
--   * eavesdrops every org.freedesktop.Notifications.Notify call with
--     dbus-monitor, so app name, summary and body are captured no matter
--     the session state (locked or not);
--   * when grouping is enabled, notifications with the same app and
--     summary update one entry instead of piling up;
--   * the list is cleared when the control center is opened, the closest
--     observable event to Noctalia's own "read" marker;
--   * notifications withdrawn by their sending app (read in the app
--     itself) leave the list: the daemon's assigned ids are correlated
--     through the captured method returns, and either a successful
--     CloseNotification reply or a NotificationClosed signal with reason 3
--     queues removal after a short grace period, unless a newer message in
--     the same app/title thread identifies it as a replacement;
--   * apps that replace a notification by closing the old id and posting a
--     new one keep the earlier card; ids already expired or dismissed are
--     still removed when the app later confirms they were read;
--   * the list is memory-only by design: notification content (bodies,
--     contact names) never touches the disk, so service restarts start
--     from an empty list. Privacy over continuity.
--
-- Noctalia v5 keeps its own notification history encrypted and offers no
-- public unread API, so this is an eavesdrop-based approximation: "received
-- since the list was last cleared" rather than the shell's exact unread
-- model. Dismissed toasts still count as unread in Noctalia too, which
-- keeps the two models close.

local MAX_STORED = 30
local REPLACE_WINDOW = 5
local CLOSE_GRACE = 1

local items = {}
local reconciling = false
local reconcileAt = nil

local function log(msg)
  noctalia.log("[lockscreen-notifications] " .. msg)
end

-- Temporary diagnostics for the close/correlation investigation; set to
-- false before publishing.
local DIAG = false
local function diag(msg)
  if DIAG then
    log(msg)
  end
end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

-- ------------------------------------------------------------------
-- The list lives in memory only, by design: notification content
-- (bodies, contact names) never touches the disk. The price is that
-- service restarts — plugin reloads, settings changes, shell restarts
-- — start from an empty list, which is the privacy trade-off this
-- plugin deliberately makes.
-- ------------------------------------------------------------------

local function publish()
  -- Keep correlation and withdrawal bookkeeping private to the service;
  -- the widget only needs the display projection.
  local published = {}
  for _, item in ipairs(items) do
    table.insert(published, {
      app = item.app,
      summary = item.summary,
      body = item.body,
      icon = item.icon,
      desktop = item.desktop,
      urgent = item.urgent,
      image = item.image,
      receivedAt = item.receivedAt,
      count = item.count,
    })
  end
  noctalia.state.set("notifications", {
    items = published,
    count = #items,
  })
end

local function clearList(reason)
  if #items == 0 then
    return
  end
  items = {}
  log("list cleared (" .. reason .. ")")
  publish()
end

-- ------------------------------------------------------------------
-- Notification eavesdropping (dbus-monitor)
-- ------------------------------------------------------------------
-- Three kinds of captured messages matter:
--   * Notify method calls — app name, icon, summary, body, the call
--     serial, and the hints that follow the body (desktop-entry,
--     urgency, transient). The entry is only committed at the
--     message's last line (its expire timeout), when every field is
--     known — transient notifications are skipped there, honoring the
--     app's own "do not persist me" declaration:
--       method call ... serial=9 ...; member=Notify
--          string "app_name"  (first four string lines)
--   * the daemon's method returns — the assigned notification id,
--     correlated through the caller's unique name plus the call serial
--     (serials are unique only per connection, so the caller must be
--     part of the key — fresh clients and sandbox proxies reuse the
--     same small numbers):
--       method return ... -> destination=:1.99 ... reply_serial=9
--          uint32 410
--   * NotificationClosed signals — reason 3 means the sending app
--     withdrew the notification (read in the app itself), so the entry
--     leaves the list. Other reasons (expired, user-dismissed) keep the
--     entry, matching Noctalia's own unread model:
--       signal ...; member=NotificationClosed
--          uint32 410
--          uint32 3

local msgKind = nil -- "notify" | "return" | "closed"
local nStrings = {}
local plainStringBuf = nil
local closedValues = {}
local hintKey = nil
local hintDesktop = nil
local hintUrgent = false
local hintTransient = false
local hintImagePath = nil
local notifyReplacesId = nil
local pendingSerial = nil
local pendingSender = nil
local pendingReplyKey = nil
local pendingCloseKey = nil

-- Caller unique name + call serial -> item awaiting the daemon-assigned
-- id (bounded FIFO). Serials are unique only per connection, so the key
-- pairs the serial with the caller's unique name: fresh clients
-- (notify-send, gdbus, busctl) and sandbox proxies all reuse the same
-- small serial numbers.
local pendingBySerial = {}
local serialQueue = {}
local pendingCloseBySerial = {}
local closeSerialQueue = {}
local expectedReplacementIds = {}
local replacementExpireAt = {}
local replacementQueue = {}
local replacementQueued = {}
local inactiveIds = {}
local inactiveQueue = {}
local inactiveQueued = {}

local function rememberSerial(serial, item)
  local key = (pendingSender or "") .. "/" .. tostring(serial)
  pendingBySerial[key] = item
  table.insert(serialQueue, key)
  while #serialQueue > 200 do
    local old = table.remove(serialQueue, 1)
    pendingBySerial[old] = nil
  end
end

-- A CloseNotification call is only a request: the daemon may reject it
-- when the toast already expired. Remember the requested id until the
-- matching method return confirms success; Chromium, for example, cleans
-- up old ids when posting a new notification and those failed requests
-- must not withdraw the older card.
local function rememberClose(key, id)
  pendingCloseBySerial[key] = id
  table.insert(closeSerialQueue, key)
  while #closeSerialQueue > 200 do
    local old = table.remove(closeSerialQueue, 1)
    pendingCloseBySerial[old] = nil
  end
end

-- An atomic Notify replacement reuses the same daemon id. The daemon may
-- emit NotificationClosed for the old occurrence before returning that id
-- for the new one; remember that this particular reason-3 close belongs to
-- the replacement and must not delete the new card.
local function removeQueuedId(queue, id)
  for i = #queue, 1, -1 do
    if queue[i] == id then
      table.remove(queue, i)
      return
    end
  end
end

local function forgetReplacement(id)
  expectedReplacementIds[id] = nil
  replacementExpireAt[id] = nil
  replacementQueued[id] = nil
  removeQueuedId(replacementQueue, id)
end

local function rememberReplacement(id)
  if not id or id == 0 then
    return
  end
  if not replacementQueued[id] then
    replacementQueued[id] = true
    table.insert(replacementQueue, id)
  end
  expectedReplacementIds[id] = (expectedReplacementIds[id] or 0) + 1
  replacementExpireAt[id] = os.time() + CLOSE_GRACE
  while #replacementQueue > 200 do
    local old = table.remove(replacementQueue, 1)
    replacementQueued[old] = nil
    expectedReplacementIds[old] = nil
    replacementExpireAt[old] = nil
  end
end

local function expireReplacementMarkers()
  local now = os.time()
  for id, due in pairs(replacementExpireAt) do
    if now >= due then
      forgetReplacement(id)
    end
  end
end

local function forgetInactive(id)
  inactiveIds[id] = nil
  inactiveQueued[id] = nil
  removeQueuedId(inactiveQueue, id)
end

local function rememberInactive(id)
  if not inactiveQueued[id] then
    inactiveQueued[id] = true
    table.insert(inactiveQueue, id)
  end
  inactiveIds[id] = true
  while #inactiveQueue > 200 do
    local old = table.remove(inactiveQueue, 1)
    inactiveQueued[old] = nil
    inactiveIds[old] = nil
  end
end

local function consumeReplacement(id)
  local expected = expectedReplacementIds[id]
  if not expected then
    return false
  end
  if expected <= 1 then
    forgetReplacement(id)
  else
    expectedReplacementIds[id] = expected - 1
  end
  return true
end

local function itemHasId(item, id)
  local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
  if ids then
    for _, existing in ipairs(ids) do
      if existing == id then
        return true
      end
    end
  end
  return false
end

local function sameThread(a, b)
  local aSummary = tostring(a.summary or "")
  local bSummary = tostring(b.summary or "")
  if aSummary == "" or aSummary ~= bSummary then
    return false
  end
  local aApp = tostring(a.app or "")
  local bApp = tostring(b.app or "")
  if aApp ~= "" and aApp == bApp then
    return true
  end
  local aDesktop = tostring(a.desktop or "")
  local bDesktop = tostring(b.desktop or "")
  return aDesktop ~= "" and aDesktop == bDesktop
end

local function hasRecentSameThread(item, now)
  local itemIndex = nil
  for i, entry in ipairs(items) do
    if entry == item then
      itemIndex = i
      break
    end
  end
  if not itemIndex then
    return false
  end
  for i = itemIndex + 1, #items do
    local other = items[i]
    if sameThread(item, other) then
      local pending = other.pendingWithdrawals
      if not pending or next(pending) == nil then
        local received = tonumber(other.receivedAt) or 0
        if math.abs(now - received) <= REPLACE_WINDOW then
          return true
        end
      end
    end
  end
  return false
end

local function removeIdOccurrences(item, id)
  local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
  local removed = 0
  if ids then
    for i = #ids, 1, -1 do
      if ids[i] == id then
        table.remove(ids, i)
        removed = removed + 1
      end
    end
  end
  return removed
end

local function linkDaemonId(item, id)
  local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
  if ids and itemHasId(item, id) and #ids >= (tonumber(item.count) or 1) then
    return
  end
  forgetInactive(id)
  -- A reused id belongs to the newest notification now. Detach it from
  -- older separate cards so a later genuine close removes only the latest
  -- occurrence while the earlier unread message remains in the list.
  for _, other in ipairs(items) do
    if other ~= item then
      removeIdOccurrences(other, id)
      if other.pendingWithdrawals then
        other.pendingWithdrawals[id] = nil
        if next(other.pendingWithdrawals) == nil then
          other.pendingWithdrawals = nil
        end
      end
    end
  end
  item.daemonIds = item.daemonIds or {}
  table.insert(item.daemonIds, id)
end

local function unescapeDbus(s)
  return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

-- Notification bodies may contain the XML escaping required by the
-- freedesktop markup subset. The widget renders plain text, so decode the
-- standard entities first. Ampersand is decoded last so double-encoded
-- text such as "&amp;lt;" remains literal instead of turning into markup.
local function decodeEntities(s)
  if not s then
    return ""
  end
  if not s:find("&", 1, true) then
    return s
  end
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&apos;", "'")
  s = s:gsub("&#(%d+);", function(digits)
    local ok, char = pcall(utf8.char, tonumber(digits))
    return ok and char or ("&#" .. digits .. ";")
  end)
  s = s:gsub("&#[xX](%x+);", function(hex)
    local ok, char = pcall(utf8.char, tonumber(hex, 16))
    return ok and char or ("&#x" .. hex .. ";")
  end)
  s = s:gsub("&amp;", "&")
  return s
end

-- A reason-3 close usually means "read", but several apps implement a
-- replacement by closing the old notification and immediately posting a
-- new one in the same app/title thread with replaces_id=0. Keep the old
-- card when a newer notification in that thread arrives in the replacement
-- window; otherwise apply the withdrawal after a short grace period.
local function handleClosed(id, reason)
  if reason ~= 3 then
    rememberInactive(id)
    forgetReplacement(id)
    return
  end
  if consumeReplacement(id) then
    diag("close id=" .. tostring(id) .. " ignored (atomic replacement)")
    return
  end
  local now = os.time()
  -- Once the daemon reported this id inactive, a later reason-3 close is
  -- an acknowledgement (for example, read on another device). A new message
  -- arriving at the same time must not turn that read back into a replacement.
  local force = inactiveIds[id] == true
  for _, item in ipairs(items) do
    if itemHasId(item, id) then
      if item.pendingWithdrawals and item.pendingWithdrawals[id] then
        return
      end
      if not force and hasRecentSameThread(item, now) then
        diag("close id=" .. tostring(id) .. " ignored (newer notification in same thread)")
        return
      end
      item.pendingWithdrawals = item.pendingWithdrawals or {}
      item.pendingWithdrawals[id] = { due = now + CLOSE_GRACE, force = force }
      diag("close id=" .. tostring(id) .. " queued for withdrawal" .. (force and " (was inactive)" or ""))
      return
    end
  end
  diag("close id=" .. tostring(id) .. " had no matching entry")
end

local function finishPendingWithdrawals()
  local now = os.time()
  local changed = false
  for i = #items, 1, -1 do
    local item = items[i]
    local pending = item.pendingWithdrawals
    if pending then
      local itemChanged = false
      for id, withdrawal in pairs(pending) do
        if now >= withdrawal.due then
          pending[id] = nil
          if not withdrawal.force and hasRecentSameThread(item, now) then
            diag("close id=" .. tostring(id) .. " kept (replacement notification arrived)")
          else
            local withdrawn = removeIdOccurrences(item, id)
            if withdrawn > 0 then
              item.count = math.max(0, (tonumber(item.count) or 1) - withdrawn)
              log("notification " .. tostring(id) .. " withdrawn by its app (" .. withdrawn .. " occurrence(s))")
              itemChanged = true
            end
          end
        end
      end
      if next(pending) == nil then
        item.pendingWithdrawals = nil
      end
      if (tonumber(item.count) or 1) <= 0 then
        table.remove(items, i)
        itemChanged = true
      end
      if itemChanged then
        changed = true
      end
    end
  end
  if changed then
    publish()
  end
end

-- The line parser normally links each notification to the daemon id via
-- the Notify method return. That path is occasionally lost (a dbus-monitor
-- line split, an interleaved message, a multi-line body). When it is, the
-- entry stays in the list without an id and a later CloseNotification
-- cannot find it. Ask the daemon for its active notifications and match
-- the anonymous entries by summary/body: the id is recovered from the
-- daemon itself instead of the stream.
local function idInUse(id)
  for _, item in ipairs(items) do
    local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
    if ids then
      for _, existing in ipairs(ids) do
        if existing == id then
          return true
        end
      end
    end
  end
  return false
end

local function matchesActive(item, active)
  return tostring(item.summary or "") == active.summary
    and tostring(item.body or "") == active.body
end

local function reconcileDaemonIds()
  if reconciling or #items == 0 then
    return
  end
  if not noctalia.commandExists("busctl") then
    return
  end
  reconciling = true
  noctalia.runAsync(
    "busctl --user --json=short call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetNotifications",
    function(result)
      reconciling = false
      if result.exitCode ~= 0 or type(result.stdout) ~= "string" then
        return
      end
      -- Inline image-data can make this reply hundreds of kilobytes. Decoding
      -- that payload inside the short async callback can exhaust its CPU
      -- budget; id recovery is best-effort, so skip oversized replies.
      if #result.stdout > 65536 then
        diag("GetNotifications reply too large to reconcile ids")
        return
      end
      local ok, decoded = pcall(function()
        return noctalia.json.decode(result.stdout)
      end)
      if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
        return
      end
      local active = {}
      for _, arr in ipairs(decoded.data) do
        if type(arr) == "table" then
          for _, n in ipairs(arr) do
            if type(n) == "table" and type(n.id) == "table" then
              local id = tonumber(n.id.data)
              if id then
                table.insert(active, {
                  id = id,
                  summary = decodeEntities(type(n.summary) == "table" and tostring(n.summary.data or "") or ""),
                  body = decodeEntities(type(n.body) == "table" and tostring(n.body.data or "") or ""),
                })
              end
            end
          end
        end
      end
      local assigned = 0
      for _, entry in ipairs(active) do
        -- Prefer the newest anonymous match so separate cards with the
        -- same text get one id each. If every match already has an id,
        -- use the newest one for grouped/replaced notifications.
        local target = nil
        for i = #items, 1, -1 do
          local item = items[i]
          local ids = type(item.daemonIds) == "table" and item.daemonIds or nil
          if matchesActive(item, entry) and (not ids or #ids == 0) then
            target = item
            break
          end
        end
        if not target then
          for i = #items, 1, -1 do
            local item = items[i]
            if matchesActive(item, entry) then
              target = item
              break
            end
          end
        end
        local reused = target and target.replacesId == entry.id
        if target and not itemHasId(target, entry.id) and (not idInUse(entry.id) or reused) then
          linkDaemonId(target, entry.id)
          diag("daemon id " .. tostring(entry.id) .. " linked by query")
          assigned = assigned + 1
        end
      end
      if assigned > 0 then
        publish()
      end
    end)
end

-- Fields are applied inside onNotification so the state snapshot it
-- publishes is complete: setting the desktop hint after the internal
-- publish used to leave the widget's copy one publish behind (no app
-- name, no icon until some later event).
local function onNotification(app, icon, summary, body, desktop, urgent, image)
  if summary == "" and body == "" then
    return nil
  end
  -- A close immediately followed by a new notification in the same thread
  -- is a replacement, not an acknowledgement. Cancel any non-forced
  -- withdrawal still in its grace period before adding the new card.
  local sender = { app = app, summary = summary, desktop = desktop }
  for _, entry in ipairs(items) do
    if entry.pendingWithdrawals and sameThread(sender, entry) then
      for id, withdrawal in pairs(entry.pendingWithdrawals) do
        if not withdrawal.force then
          entry.pendingWithdrawals[id] = nil
        end
      end
      if next(entry.pendingWithdrawals) == nil then
        entry.pendingWithdrawals = nil
      end
      diag("replacement notification reviewed pending withdrawals")
    end
  end
  -- Group with a previous entry with the same app and summary, wherever
  -- it sits in the list (a different notification in between must not
  -- split the group). The grouped entry keeps the latest body, counts
  -- the occurrences, and is renewed at the end of the list.
  if cfg("group_notifications", true) == true then
    for i = #items, 1, -1 do
      local item = items[i]
      if item.app == app and item.summary == summary then
        table.remove(items, i)
        item.body = body
        item.icon = icon
        item.receivedAt = os.time()
        item.count = (item.count or 1) + 1
        if desktop then
          item.desktop = desktop
        end
        if image then
          item.image = image
        end
        item.urgent = urgent
        table.insert(items, item)
        publish()
        return item
      end
    end
  end
  local item = {
    app = app,
    summary = summary,
    body = body,
    icon = icon,
    desktop = desktop,
    urgent = urgent,
    image = image,
    receivedAt = os.time(),
    count = 1,
  }
  table.insert(items, item)
  while #items > MAX_STORED do
    table.remove(items, 1)
  end
  publish()
  return item
end

-- The Notify message ends with its expire timeout (int32), after every
-- hint is known: the entry is committed once there — atomic, with the
-- desktop-entry, urgency and transient declarations already collected.
local function flushNotify()
  if msgKind ~= "notify" or #nStrings < 4 then
    if msgKind == "notify" then
      diag("flush incomplete strings=" .. tostring(#nStrings) .. " serial=" .. tostring(pendingSerial))
    end
    return
  end
  msgKind = nil
  if hintTransient then
    log("transient notification skipped")
    return
  end
  diag("flush replaces_id=" .. tostring(notifyReplacesId) .. " serial=" .. tostring(pendingSerial))
  local item = onNotification(
    nStrings[1] or "", nStrings[2] or "",
    decodeEntities(nStrings[3] or ""), decodeEntities(nStrings[4] or ""),
    hintDesktop, hintUrgent, hintImagePath)
  if item and notifyReplacesId and notifyReplacesId > 0 then
    item.replacesId = notifyReplacesId
    rememberReplacement(notifyReplacesId)
  end
  if item and pendingSerial then
    diag("remember serial=" .. tostring(pendingSerial) .. " sender=" .. tostring(pendingSender))
    rememberSerial(pendingSerial, item)
  else
    diag("flush no item/serial item=" .. tostring(item ~= nil) .. " serial=" .. tostring(pendingSerial))
  end
  if item then
    -- Give the method return a moment to arrive, then recover any id the
    -- line parser missed from the daemon's active notification list.
    reconcileAt = os.time() + 1
  end
end

local function resetMsg()
  -- A new message started: commit the fully-collected notification
  -- first. This is the ONLY commit point: hint values and container
  -- shapes differ wildly between apps (Signal embeds avatars as
  -- image-data structs with their own int32 lines), so the message
  -- boundary is the one deterministic place where everything is known.
  flushNotify()
  msgKind = nil
  nStrings = {}
  plainStringBuf = nil
  closedValues = {}
  hintKey = nil
  hintDesktop = nil
  hintUrgent = false
  hintTransient = false
  hintImagePath = nil
  notifyReplacesId = nil
  pendingSerial = nil
  pendingSender = nil
  pendingReplyKey = nil
  pendingCloseKey = nil
end

-- Known hint keys we care about, in the hints dict after the body.
local function hintKeyFor(line)
  if line:find('^%s*string%s+"desktop%-entry"%s*$') then
    return "desktop-entry"
  end
  if line:find('^%s*string%s+"urgency"%s*$') then
    return "urgency"
  end
  if line:find('^%s*string%s+"transient"%s*$') then
    return "transient"
  end
  if line:find('^%s*string%s+"image%-path"%s*$') then
    return "image-path"
  end
  return nil
end

-- A real dbus-monitor message header always includes "time=". Requiring it
-- keeps continuation lines of multi-line strings (which start at column 1
-- and may begin with words like "signal" or "error") from being mistaken
-- for new messages and aborting the Notify before its id is correlated.
local function isHeader(line)
  return line:find("^method call time=") or line:find("^method return time=")
    or line:find("^signal time=") or line:find("^error time=")
end

local function handleNotifyLine(line)
  -- dbus-monitor prints hint byte arrays (image-data, Signal avatars) as
  -- one enormous line. Running the parser patterns on it can exhaust the
  -- stream callback's CPU budget and kill the watcher. The plugin does
  -- not use inline image-data, so drop oversized lines before parsing.
  if #line > 8192 then
    if plainStringBuf ~= nil then
      diag("oversized string dropped len=" .. tostring(#plainStringBuf + #line))
      plainStringBuf = nil
      resetMsg()
    else
      diag("oversized line skipped len=" .. tostring(#line))
    end
    return
  end

  -- A string value containing newlines is printed across several physical
  -- lines by dbus-monitor. Keep consuming until the closing quote: without
  -- this, the body is dropped and the next action id ("default") is taken
  -- as the fourth string field.
  if plainStringBuf ~= nil then
    -- A new message header (or an absurdly long string) means the
    -- previous string was malformed or truncated. Drop it instead of
    -- swallowing every following message, including close signals.
    if isHeader(line) or #plainStringBuf > 1048576 then
      diag("string buffer dropped len=" .. tostring(#plainStringBuf))
      plainStringBuf = nil
      resetMsg()
    else
      local prefix = line:match('^(.*)"%s*$')
      if prefix ~= nil then
        plainStringBuf = plainStringBuf .. "\n" .. prefix
        local value = plainStringBuf
        plainStringBuf = nil
        if msgKind == "notify" and #nStrings < 4 then
          table.insert(nStrings, unescapeDbus(value))
        end
      else
        plainStringBuf = plainStringBuf .. "\n" .. line
      end
      return
    end
  end

  -- Header classification (order matters: specific members first).
  if line:find("^method call time=") and line:find("member=Notify", 1, true) then
    resetMsg()
    msgKind = "notify"
    pendingSerial = tonumber(line:match("serial=(%d+)"))
    pendingSender = line:match("sender=([^ ]+)") or ""
    diag("Notify serial=" .. tostring(pendingSerial) .. " sender=" .. tostring(pendingSender))
    return
  end
  if line:find("^method call time=") and line:find("member=CloseNotification", 1, true) then
    resetMsg()
    msgKind = "closecall"
    pendingCloseKey = (line:match("sender=([^ ]+)") or "") .. "/" .. tostring(tonumber(line:match("serial=(%d+)")))
    diag("CloseNotification method call")
    return
  end
  if line:find("^signal time=") and line:find("member=NotificationClosed", 1, true) then
    resetMsg()
    msgKind = "closed"
    diag("NotificationClosed signal")
    return
  end
  if line:find("^error time=") then
    local rs = tonumber(line:match("reply_serial=(%d+)"))
    local dest = line:match("destination=([^ ]+)") or ""
    local key = dest .. "/" .. tostring(rs)
    local closeId = pendingCloseBySerial[key]
    resetMsg()
    if closeId ~= nil then
      pendingCloseBySerial[key] = nil
      diag("CloseNotification id=" .. tostring(closeId) .. " rejected")
    end
    return
  end
  if line:find("^method return time=") then
    local rs = tonumber(line:match("reply_serial=(%d+)"))
    local dest = line:match("destination=([^ ]+)") or ""
    resetMsg()
    -- Only returns answering a captured Notify call matter; the daemon
    -- also returns server-information and introspection noise. The
    -- return names the original caller as its destination, which pairs
    -- with the call's sender to key the pending map.
    local key = dest .. "/" .. tostring(rs)
    local closeId = pendingCloseBySerial[key]
    diag("return key=" .. key .. " pending=" .. tostring(pendingBySerial[key] ~= nil))
    if closeId ~= nil then
      pendingCloseBySerial[key] = nil
      diag("CloseNotification id=" .. tostring(closeId) .. " confirmed")
      handleClosed(closeId, 3)
      return
    end
    local pending = pendingBySerial[key]
    if rs and pending then
      msgKind = "return"
      pendingReplyKey = key
    end
    return
  end
  if isHeader(line) then
    resetMsg()
    return
  end

  -- Body lines, per message kind.
  if msgKind == "return" then
    local v = line:match("^%s*uint32%s+(%d+)%s*$")
    if v then
      local item = pendingBySerial[pendingReplyKey]
      pendingBySerial[pendingReplyKey] = nil
      msgKind = nil
      if item then
        linkDaemonId(item, tonumber(v))
        diag("daemon id " .. tostring(v) .. " linked")
      else
        diag("daemon id " .. tostring(v) .. " had no pending notification")
      end
    end
    return
  end
  if msgKind == "closecall" then
    local v = line:match("^%s*uint32%s+(%d+)%s*$")
    if v then
      msgKind = nil
      diag("CloseNotification id=" .. tostring(v) .. " awaiting daemon reply")
      rememberClose(pendingCloseKey, tonumber(v))
    end
    return
  end
  if msgKind == "closed" then
    local v = line:match("^%s*uint32%s+(%d+)%s*$")
    if v then
      table.insert(closedValues, tonumber(v))
      if #closedValues == 2 then
        msgKind = nil
        diag("NotificationClosed id=" .. tostring(closedValues[1]) .. " reason=" .. tostring(closedValues[2]))
        handleClosed(closedValues[1], closedValues[2])
      end
    end
    return
  end
  if msgKind ~= "notify" then
    return
  end

  -- The first uint32 after app_name is Notify's replaces_id. It lets us
  -- distinguish an atomic replacement (same daemon id) from apps that
  -- implement replacement by closing the old id and posting a new one.
  if notifyReplacesId == nil and #nStrings >= 1 then
    local replaces = line:match("^%s*uint32%s+(%d+)%s*$")
    if replaces then
      notifyReplacesId = tonumber(replaces)
      return
    end
  end

  -- Inside the hints dict: a known key is followed by its variant value.
  -- Keys can arrive in any order, so a new dict key re-runs the lookup.
  -- Values are only collected here; the entry is committed at the end
  -- of the message, with everything known.
  if hintKey ~= nil then
    if hintKey == "urgency" then
      local v = line:match("^%s*variant%s+byte%s+(%d+)%s*$")
      if v then
        -- Urgency byte: 0 low, 1 normal, 2 critical.
        hintUrgent = tonumber(v) == 2
        hintKey = nil
      end
    elseif hintKey == "transient" then
      -- The spec has transient as a boolean, but some toolkits send a
      -- bare 1 instead — accept both.
      local v = line:match("^%s*variant%s+boolean%s+true%s*$")
        or line:match("^%s*variant%s+byte%s+1%s*$")
        or line:match("^%s*variant%s+int32%s+1%s*$")
        or line:match("^%s*variant%s+uint32%s+1%s*$")
      if v then
        hintTransient = true
        hintKey = nil
      end
    elseif hintKey == "image-path" then
      local v = line:match('^%s*variant%s+string%s+"(.*)"%s*$')
      if v then
        -- Apps send a plain path or a file:// URI; the widget renders
        -- it as the leading image in place of the app icon.
        hintImagePath = (unescapeDbus(v):gsub("^file://", ""))
        hintKey = nil
      end
    else
      -- desktop-entry: a plain string id such as org.telegram.desktop.
      local v = line:match('^%s*variant%s+string%s+"(.*)"%s*$')
      if v then
        hintDesktop = unescapeDbus(v)
        hintKey = nil
      end
    end
    if hintKey ~= nil and line:match('^%s*string%s+"') then
      hintKey = hintKeyFor(line) -- a different dict key: not our value
    end
    return
  end
  -- Plain string fields: app name, icon, summary, body (first four only;
  -- action strings and dict keys later in the message must not be mixed in).
  if #nStrings < 4 then
    local s = line:match('^%s*string%s+"(.*)"%s*$')
    if s then
      table.insert(nStrings, unescapeDbus(s))
      return
    end
    local start = line:match('^%s*string%s+"(.*)$')
    if start then
      plainStringBuf = start
      return
    end
  end
  -- Hints come after the body: look for known dict keys.
  hintKey = hintKeyFor(line)
end

-- Set once when dbus-monitor is missing, so the error toast is shown only
-- once even though the watchdog retries every 30 s.
local watcherErrorNotified = false

local function startNotifyWatch()
  if not noctalia.commandExists("dbus-monitor") then
    log("dbus-monitor not found on PATH")
    -- Once only: the watchdog retries every 30 s, and re-toasting the
    -- same missing dependency would spam the desktop forever. A
    -- module-level flag is required because Lua functions cannot hold
    -- fields.
    if not watcherErrorNotified then
      watcherErrorNotified = true
      noctalia.notifyError("Lockscreen Notifications", noctalia.tr("notify.error"))
    end
    return
  end
  -- Watch client CloseNotification calls as well, but only withdraw after
  -- the daemon's method return confirms success. A failed cleanup request
  -- for an expired id must leave the older card in the list. The
  -- NotificationClosed signal remains an independent withdrawal path.
  noctalia.runStream(
    'dbus-monitor --session --monitor "type=\'method_call\',interface=\'org.freedesktop.Notifications\',member=\'Notify\'" "type=\'method_call\',interface=\'org.freedesktop.Notifications\',member=\'CloseNotification\'" "type=\'method_return\',sender=\'org.freedesktop.Notifications\'" "type=\'error\',sender=\'org.freedesktop.Notifications\'" "type=\'signal\',interface=\'org.freedesktop.Notifications\',member=\'NotificationClosed\'"',
    function(line)
      handleNotifyLine(line)
    end
  )
end

-- ------------------------------------------------------------------
-- Watchdog: if the dbus-monitor process dies silently, respawn it.
-- Checked from update() at most once every 30 s. The pgrep pattern uses
-- a character class ("Notif[y]") so the checking shell itself — whose
-- command line contains the pattern literal — never matches.
-- ------------------------------------------------------------------
local lastWatchdogCheck = 0

local function watchdogCheck()
  local now = os.time()
  if now - lastWatchdogCheck < 30 then
    return
  end
  lastWatchdogCheck = now
  if not noctalia.commandExists("pgrep") then
    return
  end
  noctalia.runAsync(
    'pgrep -f "dbus-monitor.*Notif[y]" > /dev/null 2>&1',
    function(result)
      if result.exitCode ~= 0 then
        log("notification watcher not running: respawning dbus-monitor")
        startNotifyWatch()
      end
    end)
end

-- ------------------------------------------------------------------
-- "Viewed" detection: the control center opening is the closest
-- externally observable event to Noctalia's own "notifications tab
-- opened" read marker. The tab itself is not distinguishable over IPC.
-- ------------------------------------------------------------------
local function centerOpenPoll()
  noctalia.runAsync(
    "noctalia msg status",
    function(result)
      if result.exitCode == 0 and type(result.stdout) == "string"
        and result.stdout:find('"activePanelId"%s*:%s*"control%-center"') then
        clearList("control center opened")
      end
    end)
end

local lastCenterPoll = 0

function update()
  noctalia.setUpdateInterval(500)
  expireReplacementMarkers()
  finishPendingWithdrawals()
  local now = os.time()
  -- The control center poll spawns a short-lived `noctalia msg status`
  -- process; skip it while there is nothing to clear and run it at most
  -- once every two seconds.
  if #items > 0 and now - lastCenterPoll >= 2 then
    lastCenterPoll = now
    centerOpenPoll()
  end
  if reconcileAt and now >= reconcileAt then
    reconcileAt = nil
    reconcileDaemonIds()
  end
  watchdogCheck()
end

publish()
startNotifyWatch()
