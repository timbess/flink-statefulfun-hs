-- | Primary module containing everything needed to create stateful functions with Flink.
--
-- All stateful functions should have a single record type that represents the entire internal state
-- of the function. Stateful functions API provides many "slots" to store state, but for the purposes of this library
-- that is hardcoded to the single key `flink_state` which you can see in the example @module.yaml@.
--
-- The Serde typeclass abstracts serialization away from the library so that users can decide how
-- state should be serialized. Aeson is very convenient so I use it in the example, but protobuf or any other
-- binary format is also acceptable. Flink essentially stores function state as an opaque 'Data.ByteString.ByteString' regardless.
--
-- When running your program don't forget to pass @+RTS -N@ to your binary to run on all cores.
module Network.Flink.Stateful
  ( StatefulFunc
      ( insideCtx,
        getCtx,
        setCtx,
        modifyCtx,
        sendMsg,
        sendMsgDelay,
        sendEgressMsg,
        cancelDelayed
      ),
    flinkWrapper,
    createApp,
    flinkServer,
    flinkApi,
    Address(..),
    ClToken,
    FuncType (..),
    Serde (..),
    FunctionTable,
    JsonSerde (..),
    ProtoSerde (..),
    Expiration(..),
    ExpirationMode(..),
    jsonState,
    protoState,
    sendProtoMsg,
    sendProtoMsgDelay
  )
where

import Network.Flink.Internal.Stateful
    ( StatefulFunc(..),
      JsonSerde(..),
      ProtoSerde(..),
      Serde(..),
      FunctionTable,
      Expiration(..),
      ExpirationMode(..),
      Address(..),
      ClToken(..),
      FuncType (..),
      jsonState,
      protoState,
      flinkApi,
      createApp,
      flinkServer,
      flinkWrapper,
      sendProtoMsg,
      sendProtoMsgDelay
 )