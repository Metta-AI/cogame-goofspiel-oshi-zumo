## Goofspiel / Oshi-Zumo game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the game block of the renderer
##   GET /client/chrome_common.js    - the inherited cogame-babel chrome
##   GET /client/chrome.css
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (gozu.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every round, redacted to the
##                   seat's own resources until the round resolves
##                   {"type":"final","scores":[...],"points":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"match"|...}
##
## Bids are SEALED server-side: `broadcastLocked` for round r only ever runs
## after `applyBids(r)`, so no socket can see one seat's bid before every
## seat's bid is in.

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  ## Keep answering /healthz and /global for this long after the artifacts
  ## land: the certifier pings /global AFTER the player pods start, and a
  ## short episode can otherwise already be gone (lantern 0.1.3 -> 0.1.4).
  ShutdownGraceSeconds = 20

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"goofspiel-oshi-zumo"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Redacted to the seat's own resources until the round resolves. The past
  ## is public in this game, but the CURRENT round's bids are not in the
  ## frame before the reveal, and decisions are server-side anyway.
  var hand = newJArray()
  if gs.sim.config.mode == mGoofspiel:
    for card in gs.sim.hands[slot]:
      hand.add(%card)
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "round": gs.sim.round,
    "maxRounds": gs.config.maxRounds,
    "roundsPlayed": gs.sim.roundsPlayed,
    "mode": $gs.sim.config.mode,
    "seat": {
      "score": gs.sim.score(slot),
      "points": (if gs.sim.config.mode == mGoofspiel: gs.sim.points[slot]
                 else: gs.sim.outcome[slot]),
      "spent": gs.sim.spent[slot],
      "hand": hand,
      "coins": gs.sim.coins[slot]
    },
    "position": gs.sim.position,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason,
    "ending": gs.sim.ending
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## The bytes the wasm viewer reads. Built by the SIM, so the server and
  ## the tests cannot disagree about what a replay carries.
  var policyNames: seq[string]
  for player in gs.config.players:
    policyNames.add(player.name)
  $gs.sim.replayPayloadJson(policyNames, results)

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "points": results["points"],
      "names": aliasNames,
      "rounds": results["rounds"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "gozu: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## The artifacts have landed; keep the HTTP surface alive for a bounded
  ## grace so a late /healthz or /global probe still answers, then exit.
  echo "gozu: artifacts written; ", ShutdownGraceSeconds,
    "s shutdown grace before exit"
  sleep(ShutdownGraceSeconds * 1000)
  echo "gozu: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc roundReserveSeconds(config: GameConfig): float =
  ## The worst case one more round can cost: two batched attempts at the
  ## LLM timeout plus a little. A round is not OPENED unless it fits.
  2.0 * config.llmTimeoutSeconds.float + 2.0

proc batchSpacingSeconds(config: GameConfig): float =
  ## The Bedrock sidecar caps 30 requests per minute per EPISODE. A round
  ## can issue up to 2 x seats calls (the batch plus one retry batch), so
  ## the floor between round starts is 2 x seats x 60 / 30 = 4 x seats.
  if config.batchSpacingSeconds > 0: config.batchSpacingSeconds.float
  else: 4.0 * config.players.len.float

proc playEpisode(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "gozu: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "gozu: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"
    let reserve = roundReserveSeconds(config)
    let spacing = batchSpacingSeconds(config)

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      let roundStart = epochTime()
      withLock stateLock:
        if state.sim.done:
          break
        ## Refuse to OPEN a round that cannot finish inside the budget: an
        ## episode that outruns the platform timeout is discarded whole,
        ## while a deadline stop is a fully scored real result.
        if playDeadline > 0.0 and roundStart + reserve > playDeadline:
          echo "gozu: episode deadline reached after ",
            state.sim.roundsPlayed, "/", config.maxRounds,
            " rounds; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        state.sim.beginRound()
        for seat in 0 ..< config.players.len:
          seats.add(seat)
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        echo "gozu: round ", state.sim.round + 1, " of ", config.maxRounds,
          (if config.mode == mGoofspiel: " prize " & $state.sim.prize()
           else: " token " & $state.sim.position),
          " at ", (epochTime() - gameStart).int, "s"
        state.broadcastLocked()

      var usedLlm = false
      for seat in seats:
        if scripted[seat] == skNone and not client.disabled:
          usedLlm = true

      ## The slow part (Claude, ONE parallel batch for the round) runs
      ## outside the lock on a snapshot; only this thread mutates the sim,
      ## so the snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, prompts, scripted)

      withLock stateLock:
        var bids: seq[int]
        var says: seq[string]
        var notes: seq[string]
        var wasScripted: seq[bool]
        var fellBack: seq[bool]
        for index, seat in seats:
          var decision = decisions[index]
          if decision.bid notin state.sim.legalBids(seat):
            echo "gozu: seat ", seat, " bid ", decision.bid,
              " rejected; using scripted fallback"
            decision = scriptedAction(state.sim, seat, skMatch)
            decision.fellBack = true
          bids.add(decision.bid)
          says.add(decision.say)
          notes.add(decision.notes)
          wasScripted.add(scripted[seat] != skNone or client.disabled)
          fellBack.add(decision.fellBack)
          echo "gozu: round ", state.sim.round + 1, " ",
            state.sim.names[seat], " bids ", decision.bid,
            (if decision.say.len > 0: " says \"" & decision.say & "\"" else: ""),
            " at ", (epochTime() - gameStart).int, "s"
        state.sim.applyBids(bids, says, notes, wasScripted, fellBack)
        echo "gozu: round ", state.sim.round + 1, " resolved, margin ",
          state.sim.margin,
          (if config.mode == mOshiZumo: " token " & $state.sim.position
           else: "")
        state.broadcastLocked()

      ## Pace between rounds so spectators can read the table.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)
      ## And floor the wall-clock spacing between LLM batches so a fast
      ## episode cannot trip the sidecar's per-episode rate limit.
      if usedLlm and spacing > 0.0:
        let waited = epochTime() - roundStart
        if waited < spacing:
          sleep(int((spacing - waited) * 1000.0))

    ## Let the last round land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  ## The game thread's whole frame. Without this guard a raise anywhere in
  ## the episode — the reachable one is the artifact POST in `writeArtifact`,
  ## which raises IOError on a non-2xx — kills the thread silently while the
  ## mummy server keeps serving, so the container never reaches its `quit`
  ## and hangs until the platform's own episode timeout kills it. Exit
  ## non-zero instead: a failed episode that ends is a result, a container
  ## that will not exit is not.
  try:
    playEpisode(runtimeConfig)
  except CatchableError as error:
    echo "gozu: game thread failed: ", error.msg
    echo "gozu: shutting down rather than serving a dead episode"
    quit(1)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc scriptHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name,
        "application/javascript; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "gozu: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "gozu.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "mode": $state.config.mode,
        "seats": state.config.players.len,
        "maxRounds": state.config.maxRounds
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          let prompt = cleanText(payload{"prompt"}.getStr(), MaxPromptLen)
          let node = payload{"scripted"}
          var kind = skNone
          if not node.isNil:
            case node.kind
            of JBool: kind = if node.getBool(): skMatch else: skNone
            of JString: kind = parseScriptKind(node.getStr())
            else: discard
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = kind
          echo "gozu: slot ", slot, " delivered a prompt (", prompt.len,
            " chars", (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "gozu: ignoring bad player frame: ",
          cleanText(error.msg, MaxErrorLen)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## Registration order matters: every /client route is registered before
  ## the asset catch-all, and neither client route opens the player socket
  ## (the certifier fetches both BEFORE the player pods start).
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", scriptHandler("renderer.js"))
  result.get("/client/chrome_common.js", scriptHandler("chrome_common.js"))
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let node = payload["config"]
  result.mode = parseMode(node{"mode"}.getStr("goofspiel"))
  result.seed = node{"seed"}.getInt(0)
  result.cards = node{"cards"}.getInt(13)
  result.coins = node{"coins"}.getInt(20)
  result.size = node{"size"}.getInt(3)
  result.minBid = node{"minBid"}.getInt(1)
  result.maxRounds = node{"maxRounds"}.getInt(13)
  ## The replay carries the episode's fitted cap and its shuffled deck;
  ## never re-fit and never re-draw.
  result.sampled = true
  if node.hasKey("prizeOrder"):
    for value in node["prizeOrder"]:
      result.prizeOrder.add(value.getInt())
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("gozu.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "gozu: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(GozuError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "gozu: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
