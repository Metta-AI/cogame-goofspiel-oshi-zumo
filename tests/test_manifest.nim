## Packaging invariants, parsed from the shipped template. Assertions 20-23
## of the design note's `## Tests`.
##
## Every one of these is a rule the PLATFORM enforces at upload or at
## certification, where the failure is a red release run two phases later
## rather than a red test here.

import std/[json, strutils, unittest]

let manifest = parseJson(readFile("coworld_manifest_template.json"))

proc gameConfigs(): seq[(string, JsonNode)] =
  for variant in manifest["variants"]:
    result.add((variant["id"].getStr(), variant["game_config"]))
  result.add(("certification", manifest["certification"]["game_config"]))

suite "20 num_agents is everywhere and agrees with itself":
  test "both variants and the cert fixture declare it":
    for (id, config) in gameConfigs():
      checkpoint(id)
      check config.hasKey("num_agents")
      let seats = config["num_agents"]
      check seats.kind == JInt
      check seats.getInt() > 0
      check config["players"].len == seats.getInt()
    ## CoworldVariant is additionalProperties:false and permits only
    ## id/name/description/game_config, so the seat count lives in
    ## game_config and nowhere else - a variant-level copy fails the
    ## upload manifest validation.
    for variant in manifest["variants"]:
      checkpoint(variant["id"].getStr())
      check not variant.hasKey("num_agents")
      check variant.hasKey("description")
    ## The number tools/ci/docker_smoke.sh cross-checks SMOKE_SEATS against.
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 4
    check manifest["certification"]["players"].len == 4

suite "21 config_schema":
  test "no game_config carries runner-managed tokens":
    ## matriculate rejects "game_config must not include runner-managed
    ## tokens" (cogame-knights-archers 0.1.0).
    for (id, config) in gameConfigs():
      checkpoint(id)
      check not config.hasKey("tokens")

  test "the schema still requires tokens and bounds every array":
    let schema = manifest["game"]["config_schema"]
    check "tokens" in schema["required"].to(seq[string])
    check "players" in schema["required"].to(seq[string])
    check not schema["additionalProperties"].getBool()
    for name, property in schema["properties"]:
      if property{"type"}.getStr() == "array":
        checkpoint(name)
        check property.hasKey("minItems")
        check property.hasKey("maxItems")

  test "results_schema pins the two reason values and the five endings":
    let schema = manifest["game"]["results_schema"]
    check schema["properties"]["reason"]["enum"].to(seq[string]) ==
      @["complete", "deadline"]
    check schema["properties"]["ending"]["enum"].to(seq[string]) ==
      @["prizes-exhausted", "pushout", "coins-exhausted", "round-cap",
        "wall-clock"]
    for name, property in schema["properties"]:
      if property{"type"}.getStr() == "array":
        checkpoint(name)
        check property["minItems"].getInt() == 2
        check property["maxItems"].getInt() == 10

suite "22 the 0.1.42+ upload contract":
  test "protocols and docs are typed text objects":
    ## Bare strings here are a platform-side validation error the repo CI
    ## does not otherwise catch (cogame-garble 0.1.0).
    let game = manifest["game"]
    for key in ["player", "global"]:
      checkpoint(key)
      check game["protocols"][key]["type"].getStr() == "text"
      check game["protocols"][key]["value"].getStr().len > 200
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["pages"].len >= 1
    for page in game["docs"]["pages"]:
      check page.hasKey("id")
      check page.hasKey("title")
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200

  test "the shape the CLI validates":
    let game = manifest["game"]
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt() == 20
    check not manifest.hasKey("version")
    check not game.hasKey("display_name")
    check not game.hasKey("tags")
    check game.hasKey("description")
    check game["owner"].getStr().len > 0
    check game["runnable"]["type"].getStr() == "game"
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"

  test "the image placeholder comes from the compose service name":
    ## `{{GAME_IMAGE}}` is not a thing: the placeholder is the compose
    ## service uppercased with '-' -> '_' (lantern 0.1.0).
    let compose = readFile("compose.yaml")
    check "  goofspiel-oshi-zumo:" in compose
    check "coworld-goofspiel-oshi-zumo:latest" in compose
    let expected = "{{GOOFSPIEL_OSHI_ZUMO_IMAGE}}"
    check manifest["game"]["runnable"]["image"].getStr() == expected
    for player in manifest["player"]:
      check player["image"].getStr() == expected

  test "every bundled player asks for a whole cpu":
    ## The bundled minimum is "1"; "500m" is rejected at upload
    ## (cogame-pistonball 0.1.1).
    check manifest["player"].len == 2
    for player in manifest["player"]:
      checkpoint(player["id"].getStr())
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["resources"]["requests"]["cpu"].getStr() == "100m"
      check player["type"].getStr() == "player"
      check player["name"].getStr().len > 0
      check player["description"].getStr().len > 0

  test "the secret namespace is game.name":
    ## The namespace must equal game.name exactly or upload-coworld 400s
    ## after a fully green certify (cooperative-hunting, 2026-08-25).
    let name = manifest["game"]["name"].getStr()
    let uri = manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
      .getStr()
    check uri == "secret://coworld/" & name & "/anthropic_api_key"

suite "23 the certification fixture seats every declared runnable":
  test "player ids resolve both ways":
    ## A fixture that seats only one of the declared runnables fails cert
    ## `players_missing` (raid 0.1.2 -> 0.1.3).
    var declared: seq[string]
    for player in manifest["player"]:
      declared.add(player["id"].getStr())
    var seated: seq[string]
    for slot in manifest["certification"]["players"]:
      let id = slot["player_id"].getStr()
      check id in declared
      seated.add(id)
    for id in declared:
      checkpoint(id)
      check id in seated
