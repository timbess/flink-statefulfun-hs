# Flink Stateful Functions Haskell SDK

Provides a typed API for creating [flink stateful functions](https://flink.apache.org/news/2020/04/07/release-statefun-2.0.0.html). Greeter example is in [example/greeter/main/Main.hs](example/greeter/main/Main.hs)


## How to run example

```bash
$ cd example
$ docker-compose build
$ docker-compose up -d
$ docker-compose logs -f event-generator
```