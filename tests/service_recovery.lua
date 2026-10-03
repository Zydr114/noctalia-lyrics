-- Exercise the actual service with a deterministic clock and asynchronous host.
local path = arg[1] or "lyrics_service.luau"

local function host(config)
  local values, watches, files, pending, json, logs = {}, {}, {}, {}, {}, {}
  local now, serial = 0, 0
  local env = setmetatable({}, { __index = _G })
  env.os = { clock = function() return now / 1000 end }
  local api = {
    getConfig = function(key) return config[key] end,
    setUpdateInterval = function() end,
    pluginDir = function() return "/plugin" end,
    pluginDataDir = function() return "/data" end,
    mkdirAll = function() return true end,
    listDir = function() return {} end,
    removeFile = function(name) files[name] = nil end,
    writeFile = function(name, value) files[name] = value; return true end,
    fileExists = function(name) return files[name] ~= nil end,
    readFile = function(name) return files[name] end,
    log = function(value) logs[#logs + 1] = value end,
    string = { urlEncode = function(value) return value end },
    json = {
      encode = function(value) serial = serial + 1; local key = "json-" .. serial; json[key] = value; return key end,
      decode = function(value) return json[value] end,
    },
  }
  api.state = {
    get = function(key) return values[key] end,
    set = function(key, value) values[key] = value; if watches[key] then watches[key](value) end end,
    watch = function(key, callback) watches[key] = callback end,
  }
  api.runAsync = function(command, callback)
    if config.reject and command:find(config.reject, 1, true) then return false end
    pending[#pending + 1] = { command = command, callback = callback }
    return true
  end
  env.noctalia = api
  assert(loadfile(path, "t", env))()
  local result = { values = values, files = files, config = config, pending = pending, logs = logs }
  function result.take(pattern)
    for i, request in ipairs(pending) do
      if request.command:find(pattern, 1, true) then table.remove(pending, i); return request end
    end
    error("missing request: " .. pattern)
  end
  function result.has(pattern)
    for _, request in ipairs(pending) do if request.command:find(pattern, 1, true) then return true end end
    return false
  end
  function result.advance(ms)
    for _ = 1, math.ceil(ms / 100) do
      now = now + 100
      env.update()
      if result.metadata then
        while result.has("playerctl") do result.take("playerctl").callback({ exitCode = 0, stdout = result.metadata }) end
      end
    end
  end
  function result.poll(title)
    local fields = { "player", "player", "playing", title, "Artist", "Album", "1000000", "200000000", "", title, "", "" }
    result.metadata = table.concat(fields, string.char(31)) .. string.char(30)
    if not result.has("playerctl") then result.advance(500) end
    while result.has("playerctl") do
      result.take("playerctl").callback({ exitCode = 0, stdout = result.metadata })
    end
  end
  function result.source()
    result.take("chmod").callback({ exitCode = 0 })
    return result.take("python3")
  end
  function result.reply(request, label, source, candidates)
    local payload = { type = "lyrics", source = source or "netease", lines = {{ time = 1000, text = label }},
      candidates = candidates, selected_candidate_id = "1" }
    request.callback({ exitCode = 0, stdout = api.json.encode(payload) })
  end
  function result.change() env.onConfigChanged() end
  function result.push(event, payload) env.onIpc(event, payload) end
  result.api = api
  return result
end

local tests = {}

function tests.retry_after_failure_without_changing_track()
  local h = host({ lyrics_source = "netease" })
  h.poll("A")
  h.source().callback({ exitCode = 1 })
  assert(h.values.lyrics_fetch_state.status == "error")
  h.advance(2100)
  h.reply(h.source(), "recovered")
  assert(h.values.lyrics[1].text == "recovered")
  assert(h.values.lyrics_fetch_state.status == "ready")
end

function tests.lost_callback_falls_back_and_late_result_is_ignored()
  local h = host({ lyrics_source = "auto", lyrics_sources = { "netease", "qqmusic" } })
  h.poll("A")
  local old = h.source()
  h.advance(35100)
  local next_request = h.source()
  local request_path = next_request.command:match("'([^']+%.json)'$")
  assert(h.files[request_path])
  h.reply(old, "stale")
  assert(h.files[request_path], "late callback deleted the next source request")
  h.reply(next_request, "QQ", "qqmusic")
  assert(h.values.lyrics[1].text == "QQ")
end

function tests.late_old_track_cannot_replace_new_track()
  local h = host({ lyrics_source = "netease" })
  h.poll("A")
  local old = h.source()
  h.poll("B")
  h.reply(h.source(), "B")
  h.reply(old, "A")
  assert(h.values.lyrics[1].text == "B")
end

function tests.rejected_process_falls_back()
  local h = host({ lyrics_source = "auto", lyrics_sources = { "netease", "mpris" }, reject = "python3" })
  h.poll("A")
  h.take("chmod").callback({ exitCode = 0 })
  assert(h.values.lyrics_fetch_state.status == "error")
  h.config.reject = nil
  h.advance(2100)
  h.reply(h.source(), "recovered")
  assert(h.values.lyrics[1].text == "recovered")
end

function tests.lost_metadata_callback_does_not_lock_polling()
  local h = host({ lyrics_source = "netease" })
  local old = h.take("playerctl")
  h.advance(6500)
  assert(h.has("playerctl"))
  h.poll("B")
  old.callback({ exitCode = 1 })
  assert(h.values.track.title == "B")
end

function tests.corrupt_response_does_not_lock_source_chain()
  local h = host({ lyrics_source = "auto", lyrics_sources = { "netease", "qqmusic" } })
  h.poll("A")
  h.source().callback({ exitCode = 0, stdout = "invalid json" })
  h.reply(h.source(), "QQ", "qqmusic")
  assert(h.values.lyrics[1].text == "QQ")
end

function tests.config_change_cancels_pending_request()
  local h = host({ lyrics_source = "netease" })
  h.poll("A")
  local old = h.source()
  h.config.lyrics_source = "qqmusic"
  h.change()
  h.reply(h.source(), "QQ", "qqmusic")
  h.reply(old, "stale")
  assert(h.values.lyrics[1].text == "QQ")
end

function tests.external_push_cancels_pending_result()
  local h = host({ lyrics_source = "netease" })
  h.poll("A")
  local old = h.source()
  h.push("push-lrc", "[00:01]external")
  h.reply(old, "stale")
  assert(h.values.lyrics[1].text == "external")
end

function tests.manual_selection_failure_preserves_lyrics()
  local h = host({ lyrics_source = "lrclib" })
  h.poll("A")
  h.reply(h.source(), "original", "lrclib", {{ id = "1" }, { id = "2" }})
  h.api.state.set("lyrics_candidate_request", { request_id = "test", candidate_id = "2", track_key = h.values.lyrics_candidate_state.track_key })
  h.source().callback({ exitCode = 1 })
  assert(h.values.lyrics[1].text == "original")
  assert(h.values.lyrics_candidate_state.error == "selection_failed")
end

function tests.long_session_keeps_working_after_failures_and_track_changes()
  local h = host({ lyrics_source = "netease" })
  for i = 1, 120 do
    h.poll("Track " .. i)
    local request = h.source()
    if i % 4 == 0 then
      request.callback({ exitCode = 124 })
      h.advance(2100)
      request = h.source()
    end
    h.reply(request, "Line " .. i)
    assert(h.values.lyrics[1].text == "Line " .. i)
    h.advance(30000)
  end
end

local count = 0
for name, test in pairs(tests) do
  test()
  count = count + 1
  print("ok: " .. name)
end
print(count .. " service recovery scenarios passed")
