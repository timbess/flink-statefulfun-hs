module Main where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Map (Map)
import qualified Data.Map as Map
import Data.ProtoLens (Message, defMessage)
import Data.ProtoLens.Prism
import qualified Data.Text as Text
import Lens.Family2
import Network.Flink.Stateful
import qualified Proto.Example as EX
import qualified Proto.Example_Fields as EX
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger
import GHC.Generics
import Data.Aeson (FromJSON, ToJSON)

newtype GreeterState = GreeterState {
  greeterStateCount :: Int
} deriving (Generic, Show, ToJSON, FromJSON)

main :: IO ()
main = do
  putStrLn "http://localhost:8000/"
  -- middleware <- mkRequestLogger (def { outputFormat = Detailed True })
  run 8000 (logStdout $ createServantApp initialCtx functionTable)
  where
    initialCtx = GreeterState 0

greeterEntry :: StatefulFunc GreeterState m => EX.GreeterRequest -> m ()
greeterEntry msg = sendMsg msg ("greeting", "counter", msg ^. EX.name)

counter :: StatefulFunc GreeterState m => EX.GreeterRequest -> m ()
counter msg = do
  newCount <- (+ 1) <$> insideCtx greeterStateCount
  liftIO $ putStrLn $ "Saw " <> Text.unpack name <> " " <> show newCount <> " time(s)"
  modifyCtx (\old -> old {greeterStateCount = newCount})
  where
    name = msg ^. EX.name

functionTable =
  Map.fromList
    [ (("greeting", "greeterEntry"), runInvocations greeterEntry),
      (("greeting", "counter"), runInvocations counter)
    ]