## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy
import ./types

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "gozu-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, game, rivals: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", a cog playing " & game & " against " & rivals & "."
  of pvPlain: "You play " & alias & ", a cog. Your game is " & game & ", against " & rivals & "."
  of pvNumbered: "1. Identity: " & alias & ", a cog. 2. Game: " & game & ". 3. Opponents: " & rivals & "."
  of pvQuestions: "Who are you? " & alias & ", a cog. What are you playing? " & game & ", against " & rivals & "."
  of pvReordered: "In " & game & ", against " & rivals & ", you play the cog " & alias & "."
  of pvHeldoutBriefing: "Take the role of the cog " & alias & " for " & game & " against " & rivals & "."
  of pvHeldoutReference: "Player identity: " & alias & " (a cog). Game: " & game & ". Opposition: " & rivals & "."
  of pvMixed: raise newException(ValueError, "mixed must resolve to a training wording")

proc scenarioFamily*(config: GameConfig): string =
  if config.mode == mGoofspiel:
    return "gozu-prizes-" & $config.seed
  # Oshi seeds rename seats but do not change the board or starting resources.
  let physical = %*{"size": config.size, "coins": config.coins,
    "minBid": config.minBid, "maxRounds": config.maxRounds}
  "gozu-oshi-" & sha256($physical).toHex.toLowerAscii()
