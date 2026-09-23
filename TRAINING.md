# Metta post-training data

The native simulator and published `match` policy export supervised examples
for both certified Goofspiel/Oshi-Zumo variants:

```sh
nimby sync nimby.lock
for variant in goofspiel-4 oshi-zumo-2; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/gozu-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games. At each simultaneous bid boundary, it records every seat's hosted
system and user prompts and a `match` bid accepted by the game's reply parser
and legal-bid rule. Parsed bids resolve the round together. Whole games stay
in one split. The manifest records source revision, variant, scores, ending,
and row counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/gozu-goofspiel-4 \
  --output /tmp/gozu-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games yielded 416 training and 104 validation examples for
Goofspiel, and 144 training and 36 validation examples for Oshi-Zumo. All
700 examples fit the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the
maximum was 1,182. One CPU optimizer step per variant with a local tiny model
verifies the Metta post-training path. These examples distill the scripted
teacher; they do not establish stronger league play.
