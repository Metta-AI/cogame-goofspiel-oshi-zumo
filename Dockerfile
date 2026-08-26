# Goofspiel / Oshi-Zumo game + player image. One image, two entrypoints:
#   /bin/goofspiel-oshi-zumo         - the game server (default)
#   /bin/goofspiel-oshi-zumo-player  - the prompt-delivery player
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/gozu
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The repo nim.cfg pins the host machine's package paths; regenerate it from
# the container's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gozu-nimcache --out:goofspiel-oshi-zumo src/gozu.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gozu-player-nimcache --out:goofspiel-oshi-zumo-player \
    src/gozu_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/gozu
COPY --from=build /workspace/gozu/goofspiel-oshi-zumo /bin/goofspiel-oshi-zumo
COPY --from=build /workspace/gozu/goofspiel-oshi-zumo-player /bin/goofspiel-oshi-zumo-player
COPY --from=build /workspace/gozu/data ./data
COPY --from=build /workspace/gozu/client ./client

CMD ["/bin/goofspiel-oshi-zumo"]
