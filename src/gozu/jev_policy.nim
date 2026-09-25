## Jev policy over the ordinary seat observation and sealed-bid action.

import std/[json, os, strutils]
import curly

proc chooseBid*(observation: JsonNode): JsonNode =
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Gozu Jev policy has no model transport")

  var criteria = newJObject()
  for legal in observation["legalBids"]:
    let bid = legal.getInt()
    criteria["bid_" & $bid] = %("Bid " & $bid & " this round. The bid is " &
      "sealed until all seats submit. It is spent whether it wins or loses. " &
      "Balance winning this round against resources needed later.")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing " & observation["mode"].getStr() &
      ". Choose one legal sealed bid that maximizes your final score. " &
      "Goofspiel awards the face-up prize to the highest bidder, splitting " &
      "ties. Oshi-Zumo pushes the token one cell toward the winner's " &
      "opponent, and tied bids do not move it. Previous bids are public; " &
      "current bids and future prize order are hidden. Your seat " &
      "observation is:\n" & $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the legal bid most likely to improve your final score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  let bid = parseInt(selected[4 .. ^1])
  echo "gozu Jev player: round ", observation["round"].getInt(),
    " bid ", bid, " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = %*{
    "type": "bid",
    "round": observation["round"],
    "bid": bid
  }
