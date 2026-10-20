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

Language training is owned by the [Metta posttraining research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining).
Use its documented training and source-admission workflows from that checkout.
These examples distill the scripted teacher; they do not establish stronger play.
Oshi-Zumo seeds only rename seats and share one physical scenario family; the
default exporter keeps that family entirely in training. See the
[scenario partition guidance](README.md#prompt-diversity) before constructing validation data.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/gozu-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/gozu-train-bridge
```

The certified Goofspiel and Oshi-Zumo games expose 14 and 21 bid slots,
respectively. The simulator's `legalBids` masks spent cards and unaffordable
coin bids. Numeric observations contain the current public prize or token
position, player resources, and resolved bid history. They exclude future
prize order and the other seats' sealed bids. A round resolves only after
every seat has chosen. The `match` policy supplies opponents and teacher
labels. Complete games return the native zero-sum scores. Hosted prompts
remain available to the Metta post-training exporter.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.
