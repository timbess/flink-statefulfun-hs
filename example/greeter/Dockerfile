# Eventually this should work
# FROM nixos/nix

# RUN mkdir -p /app/example/greeter
# WORKDIR /app/example/greeter

# COPY shell.nix /app/example/greeter
# RUN nix-shell --run true

# # COPY flink-statefulfun.cabal /app
# # RUN nix-shell --run 'cd /app && cabal install --dependencies-only'

# COPY . /app

# EXPOSE 8000

# RUN nix-shell --run 'cabal install --installdir=.'
# RUN mv `readlink flink-statefulfun-greeter` .

FROM utdemir/ghc-musl:v15-ghc884
WORKDIR /app/example/greeter

RUN apk update && apk add protobuf

COPY . /app

RUN cabal install --installdir=.
RUN mv `readlink flink-statefulfun-greeter` .

FROM scratch

COPY --from=0 /app/example/greeter/flink-statefulfun-greeter .
CMD ["./flink-statefulfun-greeter", "+RTS", "-N"]