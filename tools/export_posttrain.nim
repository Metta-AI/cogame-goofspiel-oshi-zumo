## Export complete Goofspiel and Oshi-Zumo games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import gozu/[sim, llm]

const OperatorPrompt = "Choose legal bids to maximize your own score over the complete game."
const Variants = ["goofspiel-4", "oshi-zumo-2"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      sim.beginRound()
      var bids: seq[int]
      var says: seq[string]
      var notes: seq[string]
      var scripted: seq[bool]
      for seat in 0 ..< sim.seats:
        let teacher = sim.scriptedAction(seat, skMatch)
        let completion = %*{
          "bid": teacher.bid, "say": teacher.say,
          "notes": teacher.notes
        }
        let parsed = parseDecision(completion, sim.config.mode)
        doAssert parsed == teacher
        doAssert parsed.bid in sim.legalBids(seat)
        bids.add(parsed.bid)
        says.add(parsed.say)
        notes.add(parsed.notes)
        scripted.add(true)
        rows.add($(%*{
          "episode_id": "gozu-" & variant & "-" & $seed,
          "seed": "gozu-" & variant & "-" & $seed,
          "decision_id": sim.round * sim.seats + seat,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "goofspiel-oshi-zumo",
          "action_schema_revision": "gozu-bid-v1"
        }))
      sim.applyBids(bids, says, notes, scripted)
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "ending": outcome["ending"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "goofspiel-oshi-zumo",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-match",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
