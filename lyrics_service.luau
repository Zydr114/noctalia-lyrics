--!nonstrict
-- Lyrics — headless service.
-- Polls MPRIS metadata and publishes lyrics from bounded source requests.

local updateIntervalMs = 100
noctalia.setUpdateInterval(updateIntervalMs)

local cache = {}
local coverCache = {}
local sourceCoverCache = {}
local candidateCache = {}
local selectedCandidateCache = {}
local lastTrackKey = ""
local inFlight = nil
local fetchGeneration = 0
local requestSerial = 0
local sourceWatchdog = nil
local retryAt = nil
local retryFailures = 0
local pollInFlight = false
local pollGeneration = 0
local pollStartedAt = 0
local pollFailures = 0
local coverInFlight = nil
local coverFetchGeneration = 0
local maxCoverFiles = 80
local pluginDir = noctalia.pluginDir() or "/tmp"
local dataDir = type(noctalia.pluginDataDir) == "function" and noctalia.pluginDataDir() or pluginDir
local cacheDir = (dataDir or pluginDir) .. "/.cache"
noctalia.mkdirAll(cacheDir)
local requestDir = cacheDir .. "/requests"
noctalia.mkdirAll(requestDir)
local lyricsSource = noctalia.getConfig("lyrics_source") or "auto"
local lyricsSources = noctalia.getConfig("lyrics_sources") or {
  "lrclib", "netease", "splayer", "qqmusic", "kugou", "qishui", "apple_music", "spotify", "musixmatch"
}
local customUrl = noctalia.getConfig("custom_url") or ""
local customJsonField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
local pollIntervalMs = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
local lyricsOffsetMs = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
local displayMode = noctalia.getConfig("display_mode") or "toggle"
local credentialSignature = ""
local currentTrack = nil
local currentEmbeddedLyrics = ""
local currentPlayerInstance = ""
local currentArtUrl = ""
local currentCoverUrl = ""
local pendingSourceCoverUrl = ""
local mprisCoverFailed = false
local maybeApplyCover

for _, name in ipairs(noctalia.listDir(requestDir) or {}) do
  if name:match("^source_request_.*%.json$") then noctalia.removeFile(requestDir .. "/" .. name) end
end

local pruneCoverCache

local function normalizePatterns(value)
  if type(value) ~= "table" then return {} end
  local patterns = {}
  for _, pattern in ipairs(value) do
    pattern = tostring(pattern):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if pattern ~= "" then patterns[#patterns + 1] = pattern end
  end
  table.sort(patterns)
  return patterns
end

local playerAllowlist = normalizePatterns(noctalia.getConfig("player_allowlist"))
local playerBlocklist = normalizePatterns(noctalia.getConfig("player_blocklist"))

local function trackKey(track)
  local durationSeconds = math.floor((tonumber(track.duration) or 0) / 1000000)
  return (track.playerInstance or "") .. "|" .. (track.trackId or "") .. "|"
    .. (track.title or "") .. "|" .. (track.artist or "") .. "|" .. (track.album or "")
    .. "|" .. tostring(durationSeconds)
end

local function publishCandidates(tk, loading, selectionError, pendingCandidateId)
  noctalia.state.set("lyrics_candidate_state", {
    track_key = tk or "",
    candidates = candidateCache[tk] or {},
    selected_id = selectedCandidateCache[tk],
    loading = loading == true,
    error = selectionError,
    pending_id = pendingCandidateId,
  })
end

local function patternMatches(value, pattern)
  local luaPattern = "^" .. pattern:gsub("([%%%^%$%(%)%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*") .. "$"
  return value:lower():match(luaPattern) ~= nil
end

local function matchesAny(player, patterns)
  for _, pattern in ipairs(patterns) do
    if patternMatches(player.name, pattern) or patternMatches(player.instance, pattern) then return true end
  end
  return false
end

local function playerAllowed(player)
  if #playerAllowlist > 0 and not matchesAny(player, playerAllowlist) then return false end
  return not matchesAny(player, playerBlocklist)
end

local function selectPlayer(players)
  local best = nil
  local bestRank = -1
  for _, player in ipairs(players) do
    if playerAllowed(player) then
      local rank = player.status == "playing" and 2 or (player.status == "paused" and 1 or 0)
      if rank > bestRank or (rank == bestRank and player.instance == currentPlayerInstance) then
        best = player
        bestRank = rank
      end
    end
  end
  return best
end

local function clearSourceWatchdog()
  if sourceWatchdog and sourceWatchdog.request_path then noctalia.removeFile(sourceWatchdog.request_path) end
  sourceWatchdog = nil
end

local function clearPlayerState()
  fetchGeneration = fetchGeneration + 1
  coverFetchGeneration = coverFetchGeneration + 1
  currentPlayerInstance = ""
  currentTrack = nil
  currentEmbeddedLyrics = ""
  currentArtUrl = ""
  currentCoverUrl = ""
  pendingSourceCoverUrl = ""
  mprisCoverFailed = false
  lastTrackKey = ""
  inFlight = nil
  clearSourceWatchdog()
  retryAt = nil
  retryFailures = 0
  coverInFlight = nil
  noctalia.state.set("player_instance", nil)
  noctalia.state.set("player_name", nil)
  noctalia.state.set("track", nil)
  noctalia.state.set("lyrics", nil)
  noctalia.state.set("lyrics_source_used", nil)
  noctalia.state.set("lyrics_fetch_state", { status = "idle" })
  publishCandidates("")
  noctalia.state.set("cover", nil)
  noctalia.state.set("playing", false)
end

local function stableHash(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 4294967296 end
  return string.format("%08x", hash)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function coverStem(track, artUrl)
  return "cover_" .. stableHash(trackKey(track) .. "|" .. (artUrl or ""))
end

local function coverExtensionFromUrl(artUrl)
  local path = tostring(artUrl or ""):match("^[^?#]+") or ""
  local ext = path:match("%.([A-Za-z0-9]+)$")
  if not ext then return "" end
  ext = ext:lower()
  if ext == "jpeg" then return "jpg" end
  if ext == "jpg" or ext == "png" or ext == "webp" or ext == "gif" or ext == "bmp" then return ext end
  return ""
end

local function coverExtensionFromFile(path)
  local contents = noctalia.readFile(path)
  local header = contents and contents:sub(1, 16) or ""
  if header:sub(1, 3) == "\255\216\255" then return "jpg" end
  if header:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
  if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then return "webp" end
  if header:sub(1, 6) == "GIF87a" or header:sub(1, 6) == "GIF89a" then return "gif" end
  if header:sub(1, 2) == "BM" then return "bmp" end
  return ""
end

local function findCachedCover(track, artUrl)
  local stem = coverStem(track, artUrl)
  local function correctedPath(path)
    if not noctalia.fileExists(path) then return nil end
    local actualExtension = coverExtensionFromFile(path)
    local storedExtension = path:match("%.([^.]+)$")
    if actualExtension == "" or actualExtension == storedExtension then return path end
    local corrected = path:gsub("%.[^.]+$", "." .. actualExtension)
    if noctalia.fileExists(corrected) then
      noctalia.removeFile(path)
      return corrected
    end
    local renamed = noctalia.renameFile(path, corrected)
    return renamed and corrected or path
  end
  local preferred = coverExtensionFromUrl(artUrl)
  if preferred ~= "" then
    local path = cacheDir .. "/" .. stem .. "." .. preferred
    local corrected = correctedPath(path)
    if corrected then return corrected end
  end
  for _, ext in ipairs({ "jpg", "png", "webp", "gif", "bmp" }) do
    local path = cacheDir .. "/" .. stem .. "." .. ext
    local corrected = correctedPath(path)
    if corrected then return corrected end
  end
  return nil
end

local function coverPathFor(track, artUrl, ext)
  local extension = ext or coverExtensionFromUrl(artUrl)
  if extension == "" then extension = "jpg" end
  return cacheDir .. "/" .. coverStem(track, artUrl) .. "." .. extension
end

pruneCoverCache = function()
  local names = noctalia.listDir(cacheDir) or {}
  local files = {}
  for _, name in ipairs(names) do
    if name:match("^cover_.+%.%w+$") then
      local path = cacheDir .. "/" .. name
      local info = noctalia.fileInfo(path)
      files[#files + 1] = { path = path, mtime = info and info.mtime or 0 }
    end
  end
  if #files > maxCoverFiles then
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for index = 1, #files - maxCoverFiles do
      noctalia.removeFile(files[index].path)
      files[index].removed = true
    end
  end
  local keep = {}
  for key, path in pairs(coverCache) do
    if type(path) == "string" and noctalia.fileExists(path) then
      keep[key] = path
    end
  end
  coverCache = keep
end

pruneCoverCache()

local function parseLRC(lrcText)
  local lines = {}
  for line in lrcText:gmatch("[^\n]+") do
    local mins, secs = line:match("%[(%d+):(%d+%.?%d*)%]")
    if mins and secs then
      local ms = math.floor(tonumber(mins) * 60000 + tonumber(secs) * 1000)
      local text = line:gsub("%[%d+:%d+%.?%d*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        local isMeta = ms < 5000 and (text:find(":") or text:find("："))
        if not isMeta then
          lines[#lines + 1] = { time = ms, text = text }
        end
      end
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local function parsePlain(text)
  local lines = {}
  local seenLyric = false
  for line in text:gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      if seenLyric then
        lines[#lines + 1] = { time = -1, text = trimmed }
      elseif trimmed:find(":") or trimmed:find("：") then
        -- skip metadata header line
      else
        seenLyric = true
        lines[#lines + 1] = { time = -1, text = trimmed }
      end
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local function credentialsFor(source)
  if source == "spotify" then
    return {
      spotify_sp_dc = noctalia.getConfig("spotify_sp_dc") or "",
      spotify_access_token = noctalia.getConfig("spotify_access_token") or "",
    }
  elseif source == "apple_music" then
    return {
      apple_developer_token = noctalia.getConfig("apple_developer_token") or "",
      apple_user_token = noctalia.getConfig("apple_user_token") or "",
      apple_storefront = noctalia.getConfig("apple_storefront") or "us",
    }
  elseif source == "musixmatch" then
    return { musixmatch_token = noctalia.getConfig("musixmatch_token") or "" }
  elseif source == "qishui" then
    return {
      qishui_token = noctalia.getConfig("qishui_token") or "",
      qishui_api_url = noctalia.getConfig("qishui_api_url") or "",
    }
  elseif source == "splayer" then
    return { splayer_api_url = noctalia.getConfig("splayer_api_url") or "http://127.0.0.1:25884" }
  end
  return {}
end

local function normalizedSources()
  if lyricsSource ~= "auto" then return { lyricsSource } end
  local result = {}
  local seen = {}
  if type(lyricsSources) == "table" then
    for _, source in ipairs(lyricsSources) do
      source = tostring(source):lower():gsub("^%s+", ""):gsub("%s+$", "")
      if source ~= "" and not seen[source] then
        result[#result + 1] = source
        seen[source] = true
      end
    end
  end
  if #result == 0 then result = { "lrclib", "netease" } end
  return result
end

local function evictCache()
  local keys = {}
  for k, _ in pairs(cache) do keys[#keys + 1] = k end
  if #keys > 30 then
    table.sort(keys)
    for i = 1, #keys - 30 do
      cache[keys[i]] = nil
      sourceCoverCache[keys[i]] = nil
      candidateCache[keys[i]] = nil
      selectedCandidateCache[keys[i]] = nil
    end
  end
end

local function nowMs()
  return os.clock() * 1000
end

local function fetchLyrics(track, embeddedLyrics, requestedCandidateId)
  if displayMode == "track" then return end
  local tk = trackKey(track)
  requestedCandidateId = tostring(requestedCandidateId or "")
  local manualSelection = requestedCandidateId ~= ""
  fetchGeneration = fetchGeneration + 1
  local flight = tk .. "|" .. tostring(fetchGeneration)
  local deadline = nowMs() + 90000
  local sources = manualSelection and { "lrclib" } or normalizedSources()
  local attempt = 0
  inFlight = flight
  retryAt = nil
  clearSourceWatchdog()
  publishCandidates(tk, manualSelection, nil, manualSelection and requestedCandidateId or nil)

  local function valid(token)
    return inFlight == flight and lastTrackKey == tk and (not token or attempt == token)
  end

  local function finishFailure()
    if not valid() then return end
    inFlight = nil
    clearSourceWatchdog()
    if manualSelection then
      publishCandidates(tk, false, "selection_failed")
    else
      retryFailures = retryFailures + 1
      retryAt = nowMs() + math.min(60000, 2000 * 2 ^ math.min(retryFailures - 1, 5))
      noctalia.state.set("lyrics", nil)
      noctalia.state.set("lyrics_source_used", nil)
      candidateCache[tk] = nil
      selectedCandidateCache[tk] = nil
      publishCandidates(tk)
    end
    noctalia.state.set("lyrics_fetch_state", { track_key = tk, status = "error", retry_at_ms = retryAt })
  end

  local function apply(lines, source, parsed)
    if not valid() or type(lines) ~= "table" or #lines == 0 or #lines > 2000 then return false end
    parsed = parsed or {}
    cache[tk] = lines
    candidateCache[tk] = source == "lrclib" and parsed.candidates or nil
    selectedCandidateCache[tk] = source == "lrclib" and tostring(parsed.selected_candidate_id or "") or nil
    evictCache()
    inFlight = nil
    clearSourceWatchdog()
    retryAt = nil
    retryFailures = 0
    noctalia.state.set("lyrics", lines)
    noctalia.state.set("lyrics_source_used", source)
    noctalia.state.set("lyrics_fetch_state", { track_key = tk, status = "ready", source = source })
    publishCandidates(tk)
    if type(parsed.cover) == "string" and parsed.cover ~= "" then
      sourceCoverCache[tk] = parsed.cover
      maybeApplyCover(track, parsed.cover)
    end
    return true
  end

  local trySource
  trySource = function(index)
    if not valid() then return end
    local source = sources[index]
    if not source or nowMs() >= deadline then finishFailure(); return end
    if source == "external" then
      inFlight = nil
      clearSourceWatchdog()
      return
    end
    requestSerial = requestSerial + 1
    attempt = requestSerial
    local token = attempt
    local requestPath = requestDir .. "/source_request_" .. tostring(fetchGeneration) .. "_" .. tostring(token) .. ".json"
    local done = false
    local function fail(reason)
      if done or not valid(token) then return end
      done = true
      noctalia.removeFile(requestPath)
      clearSourceWatchdog()
      noctalia.log("lyrics source " .. source .. ": " .. reason)
      trySource(index + 1)
    end
    local function guarded(callback)
      return function(result)
        if done or not valid(token) then return end
        local ok = pcall(callback, result)
        if not ok then fail("callback failed") end
      end
    end
    sourceWatchdog = { expires = math.min(deadline, nowMs() + 35000), fail = fail, request_path = requestPath }
    noctalia.state.set("lyrics_fetch_state", { track_key = tk, status = "loading", source = source })

    if source == "mpris" then
      if not apply(parseLRC(embeddedLyrics or "") or parsePlain(embeddedLyrics or ""), source) then fail("empty lyrics") end
      return
    elseif source == "custom" then
      if customUrl == "" then fail("endpoint missing"); return end
      local values = { title = track.title, artist = track.artist, album = track.album,
        duration = tostring(math.floor((track.duration or 0) / 1000000)) }
      local url = customUrl:gsub("{([%w_]+)}", function(key) return noctalia.string.urlEncode(values[key] or "") end)
      local started = noctalia.http({ url = url, headers = { "Accept: application/json, text/plain" } }, guarded(function(response)
        local text = response.ok and response.body or ""
        if #text > 2000000 then fail("response too large"); return end
        if customJsonField ~= "" then
          local decoded = noctalia.json.decode(text)
          for part in customJsonField:gmatch("[^.]+") do decoded = type(decoded) == "table" and decoded[part] or nil end
          if type(decoded) == "table" then
            if not apply(decoded, source) then fail("invalid lyrics") end
            return
          end
          text = type(decoded) == "string" and decoded or ""
        end
        if not apply(parseLRC(text) or parsePlain(text), source) then fail("empty lyrics") end
      end))
      if not started then fail("request rejected") end
      return
    end

    local encoded = noctalia.json.encode({ source = source, track = track, credentials = credentialsFor(source),
      options = { translation_language = noctalia.getConfig("translation_language") or "zh-Hans",
        lyrics_candidate_id = manualSelection and requestedCandidateId or nil } })
    if not encoded then fail("request encoding failed"); return end
    local secured = noctalia.runAsync("chmod 700 " .. shellQuote(requestDir), guarded(function(chmodResult)
      if chmodResult.exitCode ~= 0 or not noctalia.writeFile(requestPath, encoded) then
        fail("request file unavailable"); return
      end
      local command = "timeout 28s python3 " .. shellQuote(pluginDir .. "/lyric_sources.py") .. " " .. shellQuote(requestPath)
      local started = noctalia.runAsync(command, guarded(function(result)
        noctalia.removeFile(requestPath)
        if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then fail("process failed or timed out"); return end
        if #(result.stdout or "") > 524288 then fail("response too large"); return end
        local parsed = noctalia.json.decode(result.stdout or "")
        if type(parsed) ~= "table" or parsed.type ~= "lyrics" or not apply(parsed.lines, parsed.source or source, parsed) then
          fail("lyrics unavailable")
        end
      end))
      if not started then fail("process rejected") end
    end))
    if not secured then fail("request setup rejected") end
  end
  trySource(1)
end

local function needsEmbeddedLyrics()
  for _, source in ipairs(normalizedSources()) do
    if source == "mpris" then return true end
  end
  return false
end

local function splitMetadata(value, separator)
  local parts = {}
  local start = 1
  while true do
    local finish = value:find(separator, start, true)
    if not finish then parts[#parts + 1] = value:sub(start); break end
    parts[#parts + 1] = value:sub(start, finish - 1)
    start = finish + #separator
  end
  return parts
end

local function finalizeCoverFile(tempPath, track, artUrl)
  if not tempPath or tempPath == "" or not noctalia.fileExists(tempPath) then return nil end
  local ext = coverExtensionFromFile(tempPath)
  if ext == "" then
    noctalia.removeFile(tempPath)
    return nil
  end
  local dest = coverPathFor(track, artUrl, ext)
  if tempPath == dest then return dest end
  noctalia.removeFile(dest)
  local ok = noctalia.renameFile(tempPath, dest)
  if ok or noctalia.fileExists(dest) then return dest end
  if noctalia.fileExists(tempPath) then return tempPath end
  return nil
end

local function fetchCover(track, artUrl)
  local tk = trackKey(track)
  local url = tostring(artUrl or "")
  if url == "" then return end
  local ck = tk .. "|" .. url
  if coverInFlight == ck then return end
  if coverCache[ck] and noctalia.fileExists(coverCache[ck]) then
    if tk == lastTrackKey then
      currentCoverUrl = url
      noctalia.state.set("cover", coverCache[ck])
    end
    return
  end
  local cached = findCachedCover(track, url)
  if cached then
    coverCache[ck] = cached
    if tk == lastTrackKey then
      currentCoverUrl = url
      noctalia.state.set("cover", cached)
    end
    return
  end

  coverFetchGeneration = coverFetchGeneration + 1
  local generation = coverFetchGeneration
  coverInFlight = ck

  local apply = function(path)
    if coverInFlight ~= ck or generation ~= coverFetchGeneration then return end
    coverInFlight = nil
    if tk ~= lastTrackKey then return end
    if path then
      coverCache[ck] = path
      currentCoverUrl = url
      if url == currentArtUrl then
        mprisCoverFailed = false
        pendingSourceCoverUrl = ""
      end
      noctalia.state.set("cover", path)
      pruneCoverCache()
    elseif url == currentArtUrl then
      mprisCoverFailed = true
      local fallbackUrl = pendingSourceCoverUrl
      pendingSourceCoverUrl = ""
      if fallbackUrl ~= "" then fetchCover(track, fallbackUrl) end
    end
  end

  if url:sub(1, 7) == "file://" then
    local source = noctalia.string.urlDecode(url:sub(8))
    if not noctalia.fileExists(source) then
      apply(nil)
      return
    end
    local ext = coverExtensionFromUrl(source)
    if ext == "" then ext = coverExtensionFromFile(source) end
    local dest = coverPathFor(track, url, ext ~= "" and ext or "img")
    noctalia.runAsync("cp -- " .. shellQuote(source) .. " " .. shellQuote(dest), function(result)
      if generation ~= coverFetchGeneration then return end
      if result.exitCode == 0 then
        apply(finalizeCoverFile(dest, track, url) or dest)
      else
        apply(source)
      end
    end)
    return
  end

  local downloadUrl = url
  local fallbackUrl = nil
  if url:find("music%.126%.net", 1) then
    downloadUrl = url:gsub("https?://p%d+%.music%.126%.net", "https://p1.music.126.net")
    if downloadUrl:find("[?&]param=%d+y%d+") then
      downloadUrl = downloadUrl:gsub("param=%d+y%d+", "param=400y400")
    else
      downloadUrl = downloadUrl .. (downloadUrl:find("?", 1, true) and "&" or "?") .. "param=400y400"
    end
    fallbackUrl = downloadUrl:gsub("https://p1%.music%.126%.net", "https://p3.music.126.net")
  end

  local tempDest = coverPathFor(track, url, coverExtensionFromUrl(url) ~= "" and coverExtensionFromUrl(url) or "img")
  noctalia.download(downloadUrl, tempDest, function(ok)
    if generation ~= coverFetchGeneration then return end
    if ok then
      apply(finalizeCoverFile(tempDest, track, url))
    elseif fallbackUrl then
      noctalia.download(fallbackUrl, tempDest, function(fallbackOk)
        if generation ~= coverFetchGeneration then return end
        if fallbackOk then apply(finalizeCoverFile(tempDest, track, url)) else apply(nil) end
      end)
    else
      apply(nil)
    end
  end)
end

maybeApplyCover = function(track, artUrl)
  if not track or not artUrl or artUrl == "" then return end
  if currentCoverUrl ~= "" and currentCoverUrl == artUrl then return end
  if currentArtUrl ~= "" and not mprisCoverFailed then
    pendingSourceCoverUrl = artUrl
    return
  end
  fetchCover(track, artUrl)
end

local function poll()
  if pollInFlight then return end
  pollInFlight = true
  pollGeneration = pollGeneration + 1
  local generation = pollGeneration
  pollStartedAt = nowMs()
  local embeddedFormat = needsEmbeddedLyrics() and "{{xesam:asText}}" or ""
  local cmd = [[timeout 3s playerctl --all-players metadata --format "$(printf '{{playerInstance}}\037{{playerName}}\037{{lc(status)}}\037{{title}}\037{{artist}}\037{{album}}\037{{position}}\037{{mpris:length}}\037{{mpris:artUrl}}\037{{mpris:trackid}}\037{{xesam:url}}\037]]
    .. embeddedFormat .. [[\036')" 2>/dev/null]]

  local started = noctalia.runAsync(cmd, function(r)
    if generation ~= pollGeneration then return end
    pollInFlight = false
    if r.exitCode ~= 0 or not r.stdout or r.stdout == "" or #r.stdout > 131072 then
      pollFailures = pollFailures + 1
      if pollFailures >= 3 then clearPlayerState() end
      return
    end
    pollFailures = 0

    local players = {}
    local fieldSeparator = string.char(31)
    local recordSeparator = string.char(30)
    for _, record in ipairs(splitMetadata(r.stdout, recordSeparator)) do
      if record ~= "" then
        local parts = splitMetadata(record, fieldSeparator)
        for index, field in ipairs(parts) do
          parts[index] = #field <= 16384 and field:gsub("^%s+", ""):gsub("%s+$", "") or ""
        end
        local player = {
          instance = parts[1] or "",
          name = parts[2] or "",
          status = parts[3] or "stopped",
          title = parts[4] or "",
          artist = parts[5] or "",
          album = parts[6] or "",
          position = tonumber(parts[7]) or 0,
          duration = tonumber(parts[8]) or 0,
          artUrl = parts[9] or "",
          trackId = parts[10] or "",
          mediaUrl = parts[11] or "",
          embeddedLyrics = parts[12] or "",
        }
        if player.instance ~= "" or player.name ~= "" then players[#players + 1] = player end
      end
    end

    local selected = selectPlayer(players)
    if not selected then
      clearPlayerState()
      return
    end

    currentPlayerInstance = selected.instance
    noctalia.state.set("player_instance", selected.instance)
    noctalia.state.set("player_name", selected.name)

    if selected.title == "" and selected.artist == "" then
      fetchGeneration = fetchGeneration + 1
      inFlight = nil
      clearSourceWatchdog()
      retryAt = nil
      currentTrack = nil
      currentEmbeddedLyrics = ""
      lastTrackKey = ""
      noctalia.state.set("track", nil)
      noctalia.state.set("lyrics", nil)
      noctalia.state.set("lyrics_source_used", nil)
      publishCandidates("")
      noctalia.state.set("playing", selected.status == "playing")
      return
    end

    local playing = selected.status == "playing"
    local t = {
      title = selected.title,
      artist = selected.artist,
      album = selected.album,
      status = selected.status,
      position = selected.position,
      duration = selected.duration,
      playerInstance = selected.instance,
      trackId = selected.trackId,
      mediaUrl = selected.mediaUrl,
    }
    local tk = trackKey(t)
    currentTrack = t
    currentEmbeddedLyrics = selected.embeddedLyrics
    local previousArtUrl = currentArtUrl
    currentArtUrl = selected.artUrl

    noctalia.state.set("position", t.position + lyricsOffsetMs * 1000)

    if tk ~= lastTrackKey then
      retryAt = nil
      retryFailures = 0
      clearSourceWatchdog()
      inFlight = nil
      lastTrackKey = tk
      currentCoverUrl = ""
      pendingSourceCoverUrl = ""
      mprisCoverFailed = false
      coverFetchGeneration = coverFetchGeneration + 1
      coverInFlight = nil
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)

      local cached = cache[tk]
      if displayMode == "track" then
        noctalia.state.set("lyrics", nil)
        noctalia.state.set("lyrics_source_used", nil)
        publishCandidates(tk)
      elseif cached then
        noctalia.state.set("lyrics", cached)
        noctalia.state.set("lyrics_source_used", "cache")
        noctalia.state.set("lyrics_fetch_state", { track_key = tk, status = "ready", source = "cache" })
        publishCandidates(tk)
      else
        noctalia.state.set("lyrics", nil)
        noctalia.state.set("lyrics_source_used", nil)
        publishCandidates(tk)
        fetchLyrics(t, selected.embeddedLyrics)
      end

      noctalia.state.set("cover", nil)
      if selected.artUrl ~= "" then
        pendingSourceCoverUrl = sourceCoverCache[tk] or ""
        fetchCover(t, selected.artUrl)
      elseif sourceCoverCache[tk] then
        maybeApplyCover(t, sourceCoverCache[tk])
      end
    else
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)
      if selected.artUrl ~= previousArtUrl and selected.artUrl ~= "" then
        mprisCoverFailed = false
        fetchCover(t, selected.artUrl)
      end
    end
  end)
  if not started then pollInFlight = false end
end

local pollElapsedMs = pollIntervalMs

function update()
  if lyricsSource == "external" then return end
  local now = nowMs()
  if sourceWatchdog and now >= sourceWatchdog.expires then sourceWatchdog.fail("callback deadline reached") end
  if pollInFlight and now - pollStartedAt >= 6000 then
    pollGeneration = pollGeneration + 1
    pollInFlight = false
    pollFailures = pollFailures + 1
    if pollFailures >= 3 then clearPlayerState() end
  end
  if retryAt and now >= retryAt and not inFlight and currentTrack and displayMode ~= "track" then
    fetchLyrics(currentTrack, currentEmbeddedLyrics)
  end
  pollElapsedMs = pollElapsedMs + updateIntervalMs
  if pollElapsedMs >= pollIntervalMs then
    pollElapsedMs = 0
    poll()
  end

end

function onConfigChanged()
  local nextSource = noctalia.getConfig("lyrics_source") or "auto"
  local nextUrl = noctalia.getConfig("custom_url") or ""
  local nextField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
  local nextSources = noctalia.getConfig("lyrics_sources") or lyricsSources
  local nextPollInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
  local nextOffset = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
  local nextDisplayMode = noctalia.getConfig("display_mode") or "toggle"
  local nextCredentialSignature = table.concat({
    noctalia.getConfig("spotify_sp_dc") or "",
    noctalia.getConfig("spotify_access_token") or "",
    noctalia.getConfig("apple_developer_token") or "",
    noctalia.getConfig("apple_user_token") or "",
    noctalia.getConfig("apple_storefront") or "us",
    noctalia.getConfig("musixmatch_token") or "",
    noctalia.getConfig("qishui_token") or "",
    noctalia.getConfig("qishui_api_url") or "",
    noctalia.getConfig("splayer_api_url") or "http://127.0.0.1:25884",
    noctalia.getConfig("translation_language") or "zh-Hans",
  }, "\0")
  local nextAllowlist = normalizePatterns(noctalia.getConfig("player_allowlist"))
  local nextBlocklist = normalizePatterns(noctalia.getConfig("player_blocklist"))
  local sourceChanged = nextSource ~= lyricsSource or nextUrl ~= customUrl or nextField ~= customJsonField
    or table.concat(nextSources, "\n") ~= table.concat(lyricsSources, "\n")
    or nextCredentialSignature ~= credentialSignature
    or nextDisplayMode ~= displayMode
  local playersChanged = table.concat(nextAllowlist, "\n") ~= table.concat(playerAllowlist, "\n")
    or table.concat(nextBlocklist, "\n") ~= table.concat(playerBlocklist, "\n")
  lyricsSource = nextSource
  customUrl = nextUrl
  customJsonField = nextField
  lyricsSources = nextSources
  pollIntervalMs = math.max(100, nextPollInterval)
  lyricsOffsetMs = nextOffset
  displayMode = nextDisplayMode
  credentialSignature = nextCredentialSignature
  playerAllowlist = nextAllowlist
  playerBlocklist = nextBlocklist
  if sourceChanged or playersChanged then
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
    clearSourceWatchdog()
    retryAt = nil
    retryFailures = 0
    cache = {}
    sourceCoverCache = {}
    candidateCache = {}
    selectedCandidateCache = {}
    noctalia.state.set("lyrics", nil)
    publishCandidates(currentTrack and trackKey(currentTrack) or "")
  end
  if sourceChanged and lyricsSource == "external" then
    pollGeneration = pollGeneration + 1
    pollInFlight = false
  end
  if playersChanged then
    pollGeneration = pollGeneration + 1
    pollInFlight = false
    currentPlayerInstance = ""
    lastTrackKey = ""
    if lyricsSource ~= "external" then poll() end
  elseif sourceChanged and currentTrack and lyricsSource ~= "external" then
    fetchLyrics(currentTrack, currentEmbeddedLyrics)
  end
end

local lastCandidateRequest = ""
noctalia.state.watch("lyrics_candidate_request", function(request)
  if type(request) ~= "table" or not currentTrack then return end
  local requestId = tostring(request.request_id or "")
  if requestId == "" or requestId == lastCandidateRequest then return end
  lastCandidateRequest = requestId
  local candidateId = tostring(request.candidate_id or "")
  if candidateId == "" then return end
  local tk = trackKey(currentTrack)
  if tostring(request.track_key or "") ~= tk then return end
  local known = false
  for _, candidate in ipairs(candidateCache[tk] or {}) do
    if tostring(candidate.id or "") == candidateId then
      known = true
      break
    end
  end
  if not known or candidateId == tostring(selectedCandidateCache[tk] or "") then return end
  inFlight = nil
  fetchLyrics(currentTrack, currentEmbeddedLyrics, candidateId)
end)

local function applyPushedLyrics(payload)
  local decoded = noctalia.json.decode(payload or "")
  if type(decoded) == "table" then
    if decoded.track then
      currentTrack = decoded.track
      lastTrackKey = trackKey(decoded.track)
      noctalia.state.set("track", decoded.track)
    end
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    publishCandidates(tk)
    if decoded.lines then noctalia.state.set("lyrics", decoded.lines) end
    if decoded.lyrics then
      local parsed = parseLRC(decoded.lyrics) or parsePlain(decoded.lyrics)
      noctalia.state.set("lyrics", parsed)
    end
    if decoded.position ~= nil then noctalia.state.set("position", decoded.position + lyricsOffsetMs * 1000) end
    if decoded.playing ~= nil then noctalia.state.set("playing", decoded.playing == true) end
    if type(decoded.cover) == "string" and decoded.cover ~= "" then
      if decoded.cover:sub(1, 1) == "/" or decoded.cover:sub(1, 7) == "file://" then
        currentCoverUrl = decoded.cover
        noctalia.state.set("cover", decoded.cover:gsub("^file://", ""))
      else
        maybeApplyCover(currentTrack, decoded.cover)
      end
    end
    return true
  end
  return false
end

function onIpc(event, payload)
  if event == "push-lrc" or event == "push-json" or event == "push-state" or event == "clear" then
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
    clearSourceWatchdog()
    retryAt = nil
  end
  if event == "push-lrc" then
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    publishCandidates(tk)
    noctalia.state.set("lyrics", parseLRC(payload or "") or parsePlain(payload or ""))
  elseif event == "push-json" or event == "push-state" then
    applyPushedLyrics(payload)
  elseif event == "clear" then
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    publishCandidates(tk)
    noctalia.state.set("lyrics", nil)
  end
end

if lyricsSource ~= "external" then poll() end
