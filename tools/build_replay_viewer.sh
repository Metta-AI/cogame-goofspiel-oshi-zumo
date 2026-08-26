#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, must end up containing index.html).
#
# Fork of cogame-babel's tools/build_replay_viewer.sh, with one fix: the
# output directory's PARENT is created before the containment check, because
# `coworld build` pre-creates it and a fresh CI checkout does not
# (ecos, 2026-08-23).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

output_dir="$1"
if [[ "${output_dir}" != /* ]]; then
  echo "output dir must be absolute: ${output_dir}" >&2
  exit 1
fi
mkdir -p "$(dirname "${output_dir}")"

export PATH="$HOME/.nimby/nim/bin:$PATH"

if command -v emcc >/dev/null && command -v nim >/dev/null; then
  # Local toolchain: build the wasm module directly.
  (cd "${repo_dir}" && nim c --hints:off -d:emscripten \
    replay-viewer/gozu_replay.nim)
else
  # Fall back to the pinned emsdk container.
  image_tag="gozu-replay-viewer-build:$$"
  docker build --platform linux/amd64 \
    --file "${repo_dir}/Dockerfile.replay-viewer" \
    --tag "${image_tag}" "${repo_dir}"
  container_id="$(docker create "${image_tag}")"
  rm -rf "${repo_dir}/replay-viewer/dist"
  docker cp "${container_id}:/workspace/gozu/replay-viewer/dist" \
    "${repo_dir}/replay-viewer/dist"
  docker rm "${container_id}" >/dev/null
  docker image rm "${image_tag}" >/dev/null
fi

dist="${repo_dir}/replay-viewer/dist"
test -s "${dist}/gozu_replay.wasm"
test -s "${dist}/gozu_replay.js"

rm -rf "${output_dir}"
mkdir -p "${output_dir}/assets"
cp "${dist}/gozu_replay.js" "${dist}/gozu_replay.wasm" "${output_dir}/"
cp "${repo_dir}/replay-viewer/index.html" \
  "${repo_dir}/replay-viewer/static_replay.js" \
  "${repo_dir}/client/renderer.js" \
  "${repo_dir}/client/chrome_common.js" \
  "${repo_dir}/client/chrome.css" \
  "${output_dir}/"
for asset in soldier_red_front.png soldier_blue_front.png \
  soldier_green_front.png soldier_yellow_front.png \
  arena_floor.png sumo_token.png card_back.png font.ttf; do
  cp "${repo_dir}/data/${asset}" "${output_dir}/assets/"
done

test -f "${output_dir}/index.html"
grep -q 'data-replay' "${output_dir}/static_replay.js"
echo "gozu replay viewer bundle: ${output_dir}"
