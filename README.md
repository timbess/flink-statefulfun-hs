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
3. Setup nix cache.
```bash
cachix use iohk
cachix use static-haskell-nix
cachix use flink-statefulfun
```
4. Compile inside a nix shell.
```bash
nix-shell
cabal build
```

## Tutorial

### Define our protobuf messages
```protobuf
// Example.proto
syntax = "proto3";

package example;

message GreeterRequest {
  string name = 1;
}

message GreeterResponse {
  string greeting = 1;
}
```

### Declare a function

```haskell
import Network.Flink.Stateful
import qualified Proto.Example as EX
import qualified Proto.Example_Fields as EX

printer :: StatefulFunc () m => EX.GreeterResponse -> m ()
printer msg = liftIO $ print msg
```

This declares a simple function that takes an `GreeterResponse` protobuf
type as an argument and simply prints it. `StatefulFunc` makes this a Flink
stateful function with a state type of `()` (meaning it requires no state).

### Declaring a function with state

```haskell
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics

newtype GreeterState = GreeterState
  { greeterStateCount :: Int
  }
  deriving (Generic, Show)

instance ToJSON GreeterState
instance FromJSON GreeterState

counter :: StatefulFunc GreeterState m => EX.GreeterRequest -> m ()
counter msg = do
  newCount <- (+ 1) <$> insideCtx greeterStateCount
  let respMsg = "Saw " <> T.unpack name <> " " <> show newCount <> " time(s)"

  sendMsgProto ("printing", "printer") (response $ T.pack respMsg)
  modifyCtx (\old -> old {greeterStateCount = newCount})
  where
    name = msg ^. EX.name
    response :: Text -> EX.GreeterResponse
    response greeting =
      defMessage
        & EX.greeting .~ greeting
```

The `StatefulFunc` typeclass gives us access to the `GreeterState` that we are sending to and
from Flink on every batch of incoming messages our function receives. For every message,
this function will calculate its new count, send a message to the printer function we
made earlier, then update its state with the new count.

Internally this is batched over many events before sending state back to Flink for efficiency.

NOTE: For JSON (or anything other than protobuf) messages, you must use `sendByteMsg` instead.
When communicating with other SDKs, you'll likely want to use `sendMsg` and protobuf.

### Serve HTTP API

```haskell
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Map as Map
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger

main :: IO ()
main = do
  putStrLn "http://localhost:8000/"
  run 8000 (logStdout $ createApp functionTable)

functionTable :: FunctionTable
functionTable =
  Map.fromList
    [ ((FuncType "greeting" "greeterEntry"), flinkWrapper () (Expiration NONE 0) (greeterEntry . getProto)),
      ((FuncType  "greeting" "counter"), flinkWrapper (JsonSerde (GreeterState 0)) (Expiration AFTER_CALL 5) (jsonState . counter . getProto))
    ]
```

The `FunctionTable` is a Map of `(namespace, functionType)` to `wrappedFunction`.
`jsonState` is a helper to serialize your function state as `JSON` for storage in the flink
backend. `protoState` can also be used if that is your preference. `flinkWrapper` transforms
your function into one that takes arbitrary `ByteString`s so that every function in the
`FunctionTable` Map is homogenous. `protoInput` indicates that the input message should be
deserialized as protobuf. `jsonInput` can be used instead to deserialize the messages as JSON.

`createApp` is used to turn the `FunctionTable` into a `Warp` `Application` which can be served
using the `run` function provided by `Warp`.

NOTE: JSON messages may not play nice with other SDKs, you'll probably want to stick with protobuf
if you're communicating with another SDK without knowing too much Flink Statefun internals.

### Create module YAML

To use the functions that are now served from the API, we now need to declare it in the `module.yaml`.

```yaml
version: "3.0"
module:
  meta:
    type: remote
  spec:
    endpoints:
      - endpoint:
        meta: 
          kind: http
        spec:
          functions: greeting/*
          urlPathTemplate: http://localhost:8000/statefun
```

Flink Statefun supports multiple states, but for simplicity the SDK just serializes the whole
record and hard codes `flink_state` as the only state value it uses.
