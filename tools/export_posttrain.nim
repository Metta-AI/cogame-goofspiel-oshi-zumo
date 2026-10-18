## Private source candidates. Independent review owns labels and splits.
import std/[json, os, osproc, strutils]
import bitworld/decision_trajectory
import gozu/[sim, llm, prompts, evidence]

const OperatorPrompt = "Choose legal bids to maximize your own score over the complete game."
const Variants = ["goofspiel-4", "oshi-zumo-2"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6 or args.len == 5:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1 and variant in Variants
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating pinned candidates"
  doAssert not dirExists(output) and not fileExists(output)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    let episodeId = "gozu-" & variant & "-" & $seed & "-" & $selection.selectedVariant & "-" & $selection.seed
    let trajectory = newDecisionTrajectory(episodeId, $seed, "gozu", "source-" & revision, revision)
    var count = 0
    while not game.done:
      game.beginRound()
      let before = game
      var bids: seq[int]
      var says, notes: seq[string]
      var scripted: seq[bool]
      for seat in 0 ..< game.seats:
        let teacher = game.scriptedAction(seat, skMatch)
        let action = %*{"bid": teacher.bid, "say": teacher.say, "notes": teacher.notes}
        let parsed = parseDecision(action, game.config.mode)
        doAssert parsed == teacher and parsed.bid in game.legalBids(seat)
        bids.add(parsed.bid)
        says.add(parsed.say)
        notes.add(parsed.notes)
        scripted.add(true)
      game.applyBids(bids, says, notes, scripted)
      for seat in 0 ..< game.seats:
        let system = systemPrompt(before, seat, selection)
        let user = userPrompt(before, seat, OperatorPrompt)
        trajectory.recordExecutedDecision($before.round & "-" & $seat, $seat, "scripted-match",
          %*{"control": "internal", "operator_prompt": OperatorPrompt, "system": system,
            "user": user, "prompt_template": selection.promptMetadata(system, user)},
          %*{"bid": bids[seat], "say": says[seat], "notes": notes[seat]},
          @[], aoTeacher, system, user, game.done)
        inc count
    let outcome = game.resultsJson()
    doAssert game.reason == "complete" and count > 0
    var outcomes = newJObject()
    var policies: seq[string]
    for seat in 0 ..< game.seats:
      outcomes[$seat] = %*{"score": outcome["scores"][seat]}
      policies.add("scripted-match")
    trajectory.finish(esCompleted, outcome, outcomes)
    trajectory.writeEvents(output / (episodeId & ".jsonl"))
    writePrivate(output / (episodeId & ".replay.json"), $game.replayPayloadJson(policies, outcome))
    runs.add(%*{"seed": seed, "seed_family": $seed, "episode_id": episodeId,
      "trajectory": episodeId & ".jsonl", "replay": episodeId & ".replay.json",
      "decisions": count, "scores": outcome["scores"], "ending": outcome["ending"]})
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": 1,
    "game": "goofspiel-oshi-zumo", "variant": variant, "source_revision": revision,
    "teacher": "scripted-match", "operator_prompt": OperatorPrompt,
    "prompt_selection": selection.selectionMetadata(), "review_required": true,
    "runs": runs}) & "\n")
  echo "complete games=", games
