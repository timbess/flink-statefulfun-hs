FROM nixos/nix

RUN mkdir -p /app/example/greeter
WORKDIR /app/example/greeter

COPY shell.nix /app/example/greeter
RUN nix-shell --run true

# COPY flink-statefulfun.cabal /app
# RUN nix-shell --run 'cd /app && cabal install --dependencies-only'

# COPY example/greeter /app/example/greeter
COPY . /app
# COPY flink-statefulfun.cabal /app
# COPY src /app
# COPY cabal.project /app
# COPY proto /app
# COPY LICENSE /app
# COPY CHANGELOG.md /app

EXPOSE 8000

RUN nix-shell --run 'cabal install --installdir=.'
RUN mv `readlink flink-statefulfun-greeter` .

FROM debian

COPY --from=0 /app/example/greeter/flink-statefulfun-greeter .
CMD ["./flink-statefulfun-greeter", "+RTS", "-N"]