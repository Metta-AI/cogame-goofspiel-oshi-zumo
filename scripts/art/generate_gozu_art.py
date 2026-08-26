#!/usr/bin/env python3
"""Generate the two NEW board assets with nano-banana (gemini-2.5-flash-image).

Produces one source sheet under scripts/art/source/ with both objects side by
side on a flat chroma backdrop, so the two renders share a style. The split
script (split_gozu_sheet.py) keys the backdrop out and writes:

  data/sumo_token.png   96x96    the oshi-zumo wrestler on the dohyo track
  data/card_back.png    120x168  the goofspiel prize deck's back

The key is never printed, never written to a file and never a URL parameter:
it is the `x-goog-api-key` header only.

  GEMINI_API_KEY=... python3 scripts/art/generate_gozu_art.py
"""

import base64
import json
import os
import sys
import urllib.request

MODEL = "gemini-2.5-flash-image"
URL = ("https://generativelanguage.googleapis.com/v1beta/models/"
       f"{MODEL}:generateContent")

PROMPT = """Draw TWO separate objects side by side in one row on a perfectly
flat, solid, uniform pure bright green (#00FF00) background — no shadows, no
gradients, no floor, no text, no labels, no borders. Leave a wide band of pure
green between the two objects and around them; they will be chroma-keyed out
and split apart.

Style for BOTH: hand-inked woodblock print, thick confident dark brown-black
ink lines (#2a1f16) on warm cream paper (#f2e8d8), flat colour fills, amber
(#e8a33d) as the only accent, no photographic shading, no gradients, crisp
edges, centred, front-facing, whole object inside the frame.

LEFT: a stout sumo wrestler standing square in a low stance, arms out, fists
clenched, topknot, wearing an AMBER (#e8a33d) mawashi belt. Inked in dark
brown-black outline on cream, flat fills. Square composition.

RIGHT: the BACK of a single playing card, tall rectangle with rounded corners,
a thick dark brown-black ink border and an amber-and-cream geometric
interlocking-diamond lattice filling the whole face. No numbers, no pips, no
letters. Portrait composition, taller than wide."""


def main() -> int:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2
    body = {
        "contents": [{"parts": [{"text": PROMPT}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        URL,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "content-type": "application/json"},
    )
    try:
        response = json.load(urllib.request.urlopen(request, timeout=180))
    except urllib.error.HTTPError as error:  # noqa: PERF203 - one call
        print(f"HTTP {error.code}: {error.read()[:800]!r}", file=sys.stderr)
        return 1
    part = next(p for p in response["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    out = os.path.join(os.path.dirname(__file__), "source", "gozu_sheet.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
