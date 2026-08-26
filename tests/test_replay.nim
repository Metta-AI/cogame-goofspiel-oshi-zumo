## Record -> re-derive, and the bytes. Assertions 16-19 of the design note.
##
## A replay is only a replay if the wasm viewer reaches the SAME state the
## server was in, for every ending, including the ones the bids alone cannot
## explain: a wall-clock stop is applied by the same `settle` proc on both
## paths, and this is what proves it (particle-worlds 13c66d7, 2026-08-26).

import std/[json, sequtils, strutils, unicode, unittest]
import gozu/sim

type Recorded = object
  config: GameConfig
  sim: Sim
  frames: seq[(int, string)]   ## (event count, tableStateJson) after a step

proc goofConfig(seed = 3, seats = 4): GameConfig =
  result = defaultGameConfig()
  result.mode = mGoofspiel
  result.seed = seed
  result.cards = 13
  result.maxRounds = 13
  result.sampled = true
  for index in 0 ..< seats:
    result.players.add(PlayerConfig(name: "Policy" & $(index + 1)))
    result.tokens.add("t" & $index)

proc oshiConfig(seed = 3, coins = 20, maxRounds = 20): GameConfig =
  result = defaultGameConfig()
  result.mode = mOshiZumo
  result.seed = seed
  result.coins = coins
  result.size = 3
  result.minBid = 1
  result.maxRounds = maxRounds
  result.sampled = true
  for index in 0 ..< 2:
    result.players.add(PlayerConfig(name: "Policy" & $(index + 1)))
    result.tokens.add("t" & $index)

proc snap(rec: var Recorded) =
  rec.frames.add((rec.sim.events.len, $rec.sim.tableStateJson()))

proc start(config: GameConfig): Recorded =
  result.config = config
  result.sim = initSim(config)

proc playRound(rec: var Recorded, bids: seq[int], say = "", note = "") =
  rec.sim.beginRound()
  if rec.config.mode == mGoofspiel:
    ## Oshi-zumo emits no event for the round opening, so the replay opens
    ## the round lazily on the reveal and there is no frame to compare.
    snap(rec)
  let says = newSeqWith(bids.len, say)
  let notes = newSeqWith(bids.len, note)
  rec.sim.applyBids(bids, says, notes, newSeq[bool](bids.len))
  snap(rec)

proc stop(rec: var Recorded) =
  rec.sim.endEarly()
  snap(rec)

proc checkRederives(rec: Recorded) =
  let frames = replayMatch(rec.config, rec.sim.events)
  check frames.len == rec.sim.events.len + 1
  for (index, state) in rec.frames:
    check $frames[index].tableStateJson() == state

# ---- 16: every reason/ending pair records and re-derives ------------------

proc prizesExhausted(): Recorded =
  result = start(goofConfig(seed = 21))
  while not result.sim.done:
    var bids: seq[int]
    for seat in 0 ..< 4:
      bids.add(if seat == 0: result.sim.hands[seat][^1]
               else: result.sim.hands[seat][0])
    result.playRound(bids, "burning a king on a four", "watch seat 0")

proc pushout(): Recorded =
  result = start(oshiConfig(seed = 21))
  while not result.sim.done:
    result.playRound(@[2, 1])

proc coinsExhausted(): Recorded =
  result = start(oshiConfig(seed = 21, coins = 6))
  result.playRound(@[2, 1])
  result.playRound(@[4, 5])

proc roundCap(): Recorded =
  result = start(oshiConfig(seed = 21, maxRounds = 4))
  for step in 0 ..< 4:
    result.playRound(@[1, 1])

proc wallClock(): Recorded =
  result = start(goofConfig(seed = 21))
  for step in 0 ..< 5:
    var bids: seq[int]
    for seat in 0 ..< 4:
      bids.add(result.sim.hands[seat][0])
    result.playRound(bids)
  result.stop()

suite "16 record -> re-derive, for every ending":
  test "complete / prizes-exhausted":
    let rec = prizesExhausted()
    check rec.sim.reason == "complete"
    check rec.sim.ending == "prizes-exhausted"
    checkRederives(rec)

  test "complete / pushout":
    let rec = pushout()
    check rec.sim.ending == "pushout"
    checkRederives(rec)

  test "complete / coins-exhausted":
    let rec = coinsExhausted()
    check rec.sim.ending == "coins-exhausted"
    checkRederives(rec)

  test "complete / round-cap":
    let rec = roundCap()
    check rec.sim.ending == "round-cap"
    checkRederives(rec)

  test "deadline / wall-clock":
    let rec = wallClock()
    check rec.sim.reason == "deadline"
    check rec.sim.ending == "wall-clock"
    check rec.sim.roundsPlayed == 5
    checkRederives(rec)
    ## The stop is not derivable from the bids; it re-derives only because
    ## the recorded `end` event carries it into the same settle proc.
    let frames = replayMatch(rec.config, rec.sim.events)
    check frames[^1].done
    check frames[^1].ending == "wall-clock"

# ---- 17: a tampered recording is a raised error, not a silent drift -------

suite "17 replayMatch checks what it re-derives":
  test "a disagreeing prize raises":
    let rec = prizesExhausted()
    var events = rec.sim.events
    var index = -1
    for position, event in events:
      if event.kind == evPrize:
        index = position
        break
    check index >= 0
    events[index].prize = events[index].prize mod 13 + 1
    expect GozuError:
      discard replayMatch(rec.config, events)

  test "a disagreeing push raises":
    let rec = pushout()
    var events = rec.sim.events
    var index = -1
    for position, event in events:
      if event.kind == evPush:
        index = position
        break
    check index >= 0
    events[index].positionAfter += 1
    expect GozuError:
      discard replayMatch(rec.config, events)

  test "a truncated points array raises":
    ## The length guard used to SKIP the comparison when the arrays differed,
    ## so a reveal carrying the wrong number of point totals re-derived
    ## silently.
    let rec = prizesExhausted()
    var events = rec.sim.events
    var index = -1
    for position, event in events:
      if event.kind == evReveal:
        index = position
        break
    check index >= 0
    check events[index].points.len == 4
    events[index].points.setLen(3)
    expect GozuError:
      discard replayMatch(rec.config, events)

# ---- 18: strict UTF-8, on rune boundaries ---------------------------------

suite "18 the replay bytes are strict UTF-8":
  test "full-cap multi-byte say and notes round-trip":
    ## Every truncation in this repo goes through cleanText, which cuts on a
    ## RUNE boundary. A byte cut renders in a browser and fails a strict
    ## JSON parser, which is how a replay becomes unreadable in production.
    var say = ""
    for index in 0 ..< MaxSayLen:
      say.add(if index mod 2 == 0: "日" else: "🎴")
    var notes = ""
    for index in 0 ..< MaxNotesLen:
      notes.add(if index mod 3 == 0: "🎴" else: "日")
    check say.runeLen == MaxSayLen
    check notes.runeLen == MaxNotesLen

    var rec = start(goofConfig(seed = 33))
    while not rec.sim.done:
      var bids: seq[int]
      for seat in 0 ..< 4:
        bids.add(rec.sim.hands[seat][0])
      rec.playRound(bids, say, notes)
    for event in rec.sim.events:
      if event.kind == evReveal:
        for text in event.says:
          check text.runeLen == MaxSayLen
        for text in event.notes:
          check text.runeLen == MaxNotesLen

    let payload = $rec.sim.replayPayloadJson(@["a", "b", "c", "d"],
      rec.sim.resultsJson())
    check validateUtf8(payload) == -1
    let parsed = parseJson(payload)
    check parsed["events"].len == rec.sim.events.len
    check validateUtf8($parsed) == -1

  test "over-cap text is cut on a rune boundary, not a byte boundary":
    var long = ""
    for index in 0 ..< 500:
      long.add("🎴")
    let cutSay = cleanText(long, MaxSayLen)
    let cutNotes = cleanText(long, MaxNotesLen)
    check cutSay.runeLen == MaxSayLen
    check cutNotes.runeLen == MaxNotesLen
    check cutSay.endsWith("…")
    check validateUtf8(cutSay) == -1
    check validateUtf8(cutNotes) == -1

# ---- 19: the payload is self-sufficient -----------------------------------

suite "19 the replay payload carries what the viewer needs":
  test "names, policyNames, config and results, by key":
    let rec = prizesExhausted()
    let policyNames = @["gozu-tempo", "Baseline (1)", "gozu-reader",
      "Baseline (2)"]
    let payload = rec.sim.replayPayloadJson(policyNames, rec.sim.resultsJson())
    check payload["protocol"].getStr() == "gozu.replay.v1"
    check payload["names"].len == 4
    check payload["policyNames"].len == 4
    check payload["policyNames"][0].getStr() == "gozu-tempo"
    let config = payload["config"]
    check config["mode"].getStr() == "goofspiel"
    check config["seed"].getInt() == 21
    check config["prizeOrder"].len == 13
    check config["maxRounds"].getInt() == 13
    check config["sampled"].getBool()
    check payload["events"].len == rec.sim.events.len
    check payload["results"]["reason"].getStr() == "complete"
    check payload["results"]["ending"].getStr() == "prizes-exhausted"
    check payload["results"]["names"].len == 4

    ## And the bytes alone reconstruct the episode: no seed guessing, no
    ## server, nothing but the file.
    var replayConfig = defaultGameConfig()
    replayConfig.mode = parseMode(config["mode"].getStr())
    replayConfig.seed = 999_999          ## deliberately the WRONG seed
    replayConfig.cards = config["cards"].getInt()
    replayConfig.maxRounds = config["maxRounds"].getInt()
    replayConfig.sampled = true
    for value in config["prizeOrder"]:
      replayConfig.prizeOrder.add(value.getInt())
    for name in payload["names"]:
      replayConfig.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in payload["events"]:
      events.add(eventFromJson(node))
    let frames = replayMatch(replayConfig, events)
    check frames[^1].done
    check frames[^1].points == rec.sim.points
