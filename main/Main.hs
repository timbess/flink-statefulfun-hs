module Main where

import Control.Monad.Except
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map as Map
import qualified Data.Text as Text
import GHC.Generics
import Lens.Family2
import Network.Flink.Stateful
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger
import qualified Proto.Example as EX
import qualified Proto.Example_Fields as EX
import Proto.RequestReply (ToFunction'InvocationBatchRequest)

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
  liftIO $ putStrLn $ "Saw " <> Text.unpack name <> " " <> show newCount <> " time(s)"
  modifyCtx (\old -> old {greeterStateCount = newCount})
  where
    name = msg ^. EX.name

functionTable ::
  Map.Map
    (Text.Text, Text.Text)
    (ToFunction'InvocationBatchRequest -> Function GreeterState ())
functionTable =
  Map.fromList
    [ (("greeting", "greeterEntry"), runInvocations greeterEntry),
      (("greeting", "counter"), runInvocations counter)
    ]