# Flink Stateful Functions Haskell SDK

Provides a typed API for creating [flink stateful functions](https://flink.apache.org/news/2020/04/07/release-statefun-2.0.0.html). Greeter example is in [example/greeter/main/Main.hs](example/greeter/main/Main.hs)

## How to run example

```bash
cd example
docker-compose build
docker-compose up -d
docker-compose logs -f event-generator
```

## How to compile locally

1. [Install nix](https://nixos.org/download.html)
2. [Install cachix](https://github.com/cachix/cachix#installation)
3. Setup nix cache 
```bash
cachix use iohk
cachix use static-haskell-nix
cachix use flink-statefulfun
```
4. Compile inside a nix shell
```bash
nix-shell
cabal build
```