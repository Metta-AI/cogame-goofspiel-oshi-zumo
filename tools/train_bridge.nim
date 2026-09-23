## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:gozu-train-bridge tools/train_bridge.nim

import std/[json, os]
import gozu/[llm, sim]

const OperatorPrompt = "Choose legal bids to maximize your own score over the complete game."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc publicHistory(game: Sim): JsonNode =
  result = newJArray()
  var positions = newSeq[int](game.config.maxRounds)
  for event in game.events:
    if event.kind == evPush:
      positions[event.round] = event.positionAfter
  for event in game.events:
    if event.kind == evReveal:
      let prize = if game.config.mode == mGoofspiel:
        game.prizeOrder[event.round] else: -1
      let position = if game.config.mode == mOshiZumo:
        positions[event.round] else: -1
      result.add(%*{"round": event.round, "prize": prize,
        "bids": event.bids, "position_after": position})

proc decision(game: Sim, id, seat: int): JsonNode =
  %*{
    "kind": "decision", "game": "goofspiel-oshi-zumo", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.round,
    "semantic_view": {
      "mode": $game.config.mode, "seat": seat, "round": game.round,
      "max_rounds": game.config.maxRounds, "prize": game.prize(),
      "position": game.position, "hands": game.hands,
      "coins": game.coins, "points": game.points,
      "history": game.publicHistory()
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["bid"],
      "properties": {"bid": {"type": "integer"}}},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, id, seat: int): JsonNode =
  let handSlots = if game.config.mode == mGoofspiel: game.config.cards else: 0
  var values = newJArray()
  values.add(%(if game.config.mode == mGoofspiel: 1 else: 0))
  values.add(%(if game.config.mode == mOshiZumo: 1 else: 0))
  for other in 0 ..< game.seats:
    values.add(%(if seat == other: 1 else: 0))
  for value in [game.round, game.config.maxRounds, game.prize(), game.position]:
    values.add(%value)
  for other in 0 ..< game.seats:
    values.add(%game.points[other])
    values.add(%game.spent[other])
    values.add(%game.coins[other])
    for card in 1 .. handSlots:
      values.add(%(if card in game.hands[other]: 1 else: 0))
  var revealed = 0
  let history = game.publicHistory()
  for round in history:
    values.add(round["prize"])
    values.add(round["position_after"])
    for bid in round["bids"]:
      values.add(bid)
    inc revealed
  for round in revealed ..< game.config.maxRounds:
    for field in 0 ..< game.seats + 2:
      values.add(%0)
  let slots = if game.config.mode == mGoofspiel:
    game.config.cards + 1 else: game.config.coins + 1
  let legal = game.legalBids(seat)
  var actions = newJArray()
  for bid in 0 ..< slots:
    actions.add(if bid in legal: %*{"bid": bid} else: newJNull())
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: gozu-train-bridge MANIFEST [goofspiel-4|oshi-zumo-2]", 1)
  let variant = if args.len == 2: args[1] else: "goofspiel-4"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var bids: seq[int]
  var id = 0
  var seat = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == variantConfig["players"].len
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for player in 0 ..< variantConfig["players"].len:
        runtimeConfig["tokens"].add(%("t" & $player))
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      game.beginRound()
      bids = @[]
      id = 0
      seat = 0
      response = game.decision(id, seat)
    of "encode":
      doAssert not game.done
      response = game.encoding(id, seat)
    of "teacher":
      doAssert not game.done
      let teacher = game.scriptedAction(seat, skMatch)
      response = %*{"response": $(%*{"bid": teacher.bid})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let parsed = parseDecision(action, game.config.mode)
      doAssert parsed.bid in game.legalBids(seat)
      bids.add(parsed.bid)
      inc id
      var observation: JsonNode
      if bids.len == game.seats:
        game.applyBids(bids, newSeq[string](game.seats),
          newSeq[string](game.seats), newSeq[bool](game.seats))
        bids = @[]
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< game.seats:
            scores[$slot] = outcome["scores"][slot]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          game.beginRound()
          seat = 0
          observation = game.decision(id, seat)
      else:
        inc seat
        observation = game.decision(id, seat)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
