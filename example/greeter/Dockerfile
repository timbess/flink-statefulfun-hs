# Eventually this should work
FROM nixos/nix

RUN nix-env -iA cachix -f https://cachix.org/api/v1/install
RUN cachix use iohk
RUN cachix use static-haskell-nix
RUN cachix use flink-statefulfun

RUN mkdir -p /app/example/greeter
WORKDIR /app/example/greeter

COPY shell.nix /app/example/greeter
RUN nix-shell --run true

COPY . /app
# TODO: Stupid docker doesn't cache this.
# RUN rm -rf example

# RUN nix-shell --run 'cd /app && cabal build'

# COPY example /app/example

RUN nix-shell --run 'cabal install --installdir=.'
RUN mv `readlink flink-statefulfun-greeter` .

FROM scratch

EXPOSE 8000

COPY --from=0 /app/example/greeter/flink-statefulfun-greeter .
CMD ["./flink-statefulfun-greeter", "+RTS", "-N"]