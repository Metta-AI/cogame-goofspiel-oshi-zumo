## Verify native captures against the source-owned seeded replay engine.
import std/[json, os, strutils]
import gozu/[sim, llm, server]

let args = commandLineParams()
if args.len != 3: quit("usage: verify_native REPLAY TRAJECTORY EPISODE_ID", 1)
let replay = parseFile(args[0])
var captures: seq[JsonNode]
for line in readFile(args[1]).strip().splitLines(): captures.add(parseJson(line))
let summary = captures[^1]
doAssert summary["event_type"].getStr() == "episode"
doAssert summary["episode_id"].getStr() == args[2]
doAssert summary["outcome"] == replay["results"]
let config = configFromReplay(replay)
doAssert summary["seed_family"].getStr() == $config.seed
var events: seq[GameEvent]
for event in replay["events"]: events.add(eventFromJson(event))
let frames = replayMatch(config, events)
let fullSchedule = frames[^1].done and frames[^1].reason == "complete"
doAssert frames[^1].resultsJson()["scores"] == replay["results"]["scores"]
doAssert (summary["status"].getStr() == "completed") == fullSchedule
var index = 0
for eventIndex, event in events:
  if event.kind == evReveal:
    for actingSeat in 0 ..< config.players.len:
      let seat = actingSeat
      let capture = captures[index]
      doAssert capture["event_type"].getStr() == "decision"
      doAssert capture["decision_index"].getInt() == index
      doAssert capture["decision_id"].getStr() == $event.round & "-" & $seat
      doAssert capture["seat"].getStr() == $seat
      let action = %*{"bid": event.bids[seat], "say": event.says[seat], "notes": event.notes[seat]}
      doAssert capture["executed_action"] == action
      doAssert capture["observation"]["system"].getStr() == systemPrompt(frames[eventIndex], seat)
      let operatorPrompt = capture["observation"]["operator_prompt"].getStr()
      let system = systemPrompt(frames[eventIndex], seat)
      let user = userPrompt(frames[eventIndex], seat, operatorPrompt)
      doAssert capture["observation"]["user"].getStr() == user
      for attempt in capture["attempts"]:
        if attempt["origin"].getStr() == "model":
          doAssert attempt["prompt"][0]["content"].getStr() == system
          doAssert attempt["prompt"][1]["content"].getStr().startsWith(user)
          doAssert attempt["request"]["system"].getStr() == system
          doAssert attempt["request"]["messages"][0]["content"] == attempt["prompt"][1]["content"]
        if attempt["attempt_id"] == capture["selected_attempt_id"] and attempt["origin"].getStr() in ["model", "teacher"]:
          let parsed = parseDecision(extractJsonObject(attempt["response"].getStr()), config.mode)
          let normalized = %*{"bid": parsed.bid, "say": parsed.say, "notes": parsed.notes}
          doAssert normalized == action
      inc index
doAssert index == captures.len - 1
echo $(%*{"seed": config.seed, "scores": replay["results"]["scores"],
  "full_schedule": fullSchedule, "decisions": index, "policy_names": replay["policyNames"]})
