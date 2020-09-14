module Main where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map as Map
import qualified Data.Text as T
import Data.Text (Text)
import GHC.Generics
import Lens.Family2
import Network.Flink.Stateful
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger
import qualified Proto.Example as EX
import qualified Proto.Example_Fields as EX
import Proto.RequestReply (ToFunction'InvocationBatchRequest)
import Data.ProtoLens (defMessage)

newtype GreeterState = GreeterState
  { greeterStateCount :: Int
  }
  deriving (Generic, Show, ToJSON, FromJSON)

main :: IO ()
main = do
  putStrLn "http://localhost:8000/"
  run 8000 (logStdout $ createApp initialCtx functionTable)
  where
    initialCtx = GreeterState 0

greeterEntry :: StatefulFunc GreeterState m => EX.GreeterRequest -> m ()
greeterEntry msg = sendMsg ("greeting", "counter", msg ^. EX.name) msg

counter :: StatefulFunc GreeterState m => EX.GreeterRequest -> m ()
counter msg = do
  newCount <- (+ 1) <$> insideCtx greeterStateCount
  let respMsg = "Saw " <> T.unpack name <> " " <> show newCount <> " time(s)"
  
  sendEgressMsg ("greeting", "greets") (kafkaRecord "greets" name $ response (T.pack respMsg))
  modifyCtx (\old -> old {greeterStateCount = newCount})
  where
    name = msg ^. EX.name
    response :: Text -> EX.GreeterResponse
    response greeting = defMessage
      & EX.greeting .~ greeting

functionTable ::
  Map.Map
    (Text, Text)
    (ToFunction'InvocationBatchRequest -> Function GreeterState ())
functionTable =
  Map.fromList
    [ (("greeting", "greeterEntry"), runInvocations greeterEntry),
      (("greeting", "counter"), runInvocations counter)
    ]