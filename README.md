# Flink Stateful Functions Haskell SDK [![Hackage](https://img.shields.io/hackage/v/flink-statefulfun.svg)](https://hackage.haskell.org/package/flink-statefulfun) [![Build](https://img.shields.io/travis/tdbgamer/flink-statefulfun-hs.svg)](https://travis-ci.com/github/tdbgamer/flink-statefulfun-hs)

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

printer :: StatefulFunc () m => ProtoSerde EX.GreeterResponse -> m ()
printer (ProtoSerde msg) = liftIO $ print msg
```

This declares a simple function that takes an `GreeterResponse` protobuf
type as an argument and simply prints it. `Statefulfunc` makes this a Flink
stateful function with a state type of `()` (meaning it requires no state).

Wrapping the `GreeterResponse` in `ProtoSerde` uses the [proto-lens](https://github.com/google/proto-lens)
library to deserialize the incoming messages for this function. To use JSON it can
also be wrapped in `JsonSerde` instead. Don't forget that the sender will have to use
`sendByteMsg` instead of `sendMsg` to send JSON to this function if you choose to do so.

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

counter :: StatefulFunc GreeterState m => ProtoSerde EX.GreeterRequest -> m ()
counter (ProtoSerde msg) = do
  newCount <- (+ 1) <$> insideCtx greeterStateCount
  let respMsg = "Saw " <> T.unpack name <> " " <> show newCount <> " time(s)"

  sendMsg ("printing", "printer") (response $ T.pack respMsg)
  modifyCtx (\old -> old {greeterStateCount = newCount})
  where
    name = msg ^. EX.name
    response :: Text -> EX.GreeterResponse
    response greeting =
      defMessage
        & EX.greeting .~ greeting
```

The `StateFunc` typeclass gives us access to the `GreeterState` that we are sending to and from Flink
on every batch of incoming messages our function receives. For every event, this function will calculate
its new count, send a message to the printer function we made earlier, then update its state with the new count.

Internally this is batched over many events before sending state back to Flink for efficiency.

NOTE: For JSON messages, you must use `sendByteMsg` instead and wrap the message in `JsonSerde` or alternatively
pass any type with an instance of `Serde` (leaving the door open for Avro, etc.). When communicating with other SDKs using protobuf, you'll likely want
to use `sendMsg`.

### Serve HTTP API

```haskell
import qualified Data.Map as Map
import Network.Wai.Handler.Warp (run)

main :: IO ()
main = do
  putStrLn "http://localhost:8000/"
  run 8000 (logStdout $ createApp functionTable)

functionTable :: FunctionTable
functionTable =
  Map.fromList
    [ (("printing", "printer"), (serializeBytes (), makeConcrete printer)),
      (("greeting", "counter"), (serializeBytes . JsonSerde $ GreeterState 0, makeConcrete (jsonState counter)))
    ]
```

The `FunctionTable` is a Map of `(namespace, functionType)` to `(initialState, concreteFunction)`.
`jsonState` is a helper to serialize your function state as `JSON` for storage in the flink backend.
`protoState` can also be used if that is your preference. `makeConcrete` transforms your function into one
that takes arbitrary `ByteString`s so that every function in the `FunctionTable` Map is homogenous.

`createApp` can be used to turn the `FunctionTable` into a `Warp` `Application` and served on any port.

### Create module YAML

To use the functions that are now served from the API, we now need to declare it in the `module.yaml`.

```yaml
version: "1.0"
module:
  meta:
    type: remote
  spec:
    functions:
      - function:
          meta:
            kind: http
            type: greeting/counter
          spec:
            endpoint: http://localhost:8000/statefun
            states:
              - flink_state
            maxNumBatchRequests: 500
            timeout: 2min
      - function:
          meta:
            kind: http
            type: printing/printer
          spec:
            endpoint: http://localhost:8000/statefun
            states:
              - flink_state
            maxNumBatchRequests: 500
            timeout: 2min
```
