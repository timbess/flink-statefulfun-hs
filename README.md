# Flink Stateful Functions Haskell SDK
[![Hackage](https://img.shields.io/hackage/v/flink-statefulfun.svg)](https://hackage.haskell.org/package/flink-statefulfun) [![Build](https://img.shields.io/travis/tdbgamer/flink-statefulfun-hs.svg)](https://travis-ci.com/github/tdbgamer/flink-statefulfun-hs) [![Join the chat at https://gitter.im/tdbgamer/flink-statefulfun-hs](https://badges.gitter.im/tdbgamer/flink-statefulfun-hs.svg)](https://gitter.im/tdbgamer/flink-statefulfun-hs?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

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
