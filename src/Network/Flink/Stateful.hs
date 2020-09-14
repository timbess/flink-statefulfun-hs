module Network.Flink.Stateful (
 StatefulFunc(
  insideCtx,
  getCtx,
  setCtx,
  modifyCtx,
  sendMsg,
  sendMsgDelay,
  sendEgressMsg
 ),
 runInvocations,
 createApp,
 kafkaRecord,
 Function
) where

import Control.Monad.State
import Data.Aeson (FromJSON, ToJSON)
import Lens.Family2
import Data.ProtoLens.Prism
import Proto.RequestReply (ToFunction, FromFunction)
import qualified Proto.RequestReply as PR
import qualified Proto.RequestReply_Fields as PR
import Data.ProtoLens (encodeMessage, defMessage, Message)
import Control.Monad.Except
import Data.Text (Text)
import Proto.Google.Protobuf.Any (Any)
import Data.ProtoLens.Any (UnpackError)
import qualified Data.ProtoLens.Any as Any
import Data.Either.Combinators (fromRight, mapLeft)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.ByteString.Lazy (toStrict)
import Control.Monad.Reader
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Aeson as Aeson
import Data.Foldable (Foldable(toList))
import Network.Flink.ProtoServant ( Proto )
import Servant
import qualified Data.Text.Lazy.Encoding as T
import Data.Text.Lazy (fromStrict)
import qualified Proto.Kafka as Kafka
import qualified Proto.Kafka_Fields as Kafka

data (FromJSON ctx, ToJSON ctx) => Env ctx = Env 
  { envDefaultCtx :: ctx
  , envFunctionNamespace :: Text
  , envFunctionType :: Text
  , envFunctionId :: Text
  }
  deriving (Show)

data (FromJSON ctx, ToJSON ctx) => FunctionState ctx = FunctionState
  { functionStateCtx :: Maybe ctx
  , functionStateMutated :: Bool
  , functionStateInvocations :: Seq PR.FromFunction'Invocation
  , functionStateDelayedInvocations :: Seq PR.FromFunction'DelayedInvocation
  , functionStateEgressMessages :: Seq PR.FromFunction'EgressMessage
  }
  deriving (Show)

newState :: (FromJSON a, ToJSON a) => FunctionState a
newState = FunctionState Nothing False mempty mempty mempty

newtype Function s a = Function {runFunction :: ExceptT FlinkError (StateT (FunctionState s) (ReaderT (Env s) IO)) a}
  deriving (Monad, Applicative, Functor, MonadState (FunctionState s), MonadError FlinkError, MonadIO, MonadReader (Env s))

-- deriving instance  Monad (StateT (FunctionState ctx) Identity) => Monad Function

class MonadIO m => StatefulFunc s m | m -> s where
  -- Internal
  setInitialCtx :: s -> m ()

  -- Public
  insideCtx :: (s -> a) -> m a
  getCtx :: m s
  setCtx :: s -> m ()
  modifyCtx :: (s -> s) -> m ()
  sendMsg :: Message a
    => (Text, Text, Text) -- ^ Function address (namespace, type, id)
    -> a                  -- ^ protobuf message to send
    -> m ()
  sendMsgDelay :: Message a
    => (Text, Text, Text) -- ^ Function address (namespace, type, id)
    -> Int                -- ^ delay before message send
    -> a                  -- ^ protobuf message to send
    -> m ()
  sendEgressMsg :: Message a
    => (Text, Text)       -- ^ egress address (namespace, type)
    -> a                  -- ^ protobuf message to send (should be a Kafka or Kinesis protobuf record)
    -> m ()

instance (FromJSON s, ToJSON s) => StatefulFunc s (Function s) where
  setInitialCtx ctx = modify (\old -> old { functionStateCtx = Just ctx})

  insideCtx func = func <$> getCtx
  getCtx = do
    defaultCtx <- asks envDefaultCtx
    state' <- gets functionStateCtx
    return $ fromMaybe defaultCtx state'
  setCtx new = modify (\old -> old { functionStateCtx = Just new, functionStateMutated = True })
  modifyCtx mutator = mutator <$> getCtx >>= setCtx
  sendMsg (namespace, funcType, id') msg = do
      invocations <- gets functionStateInvocations
      modify (\old -> old { functionStateInvocations = invocations Seq.:|> invocation })
    where
      target :: PR.Address
      target = defMessage
        & PR.namespace .~ namespace
        & PR.type' .~ funcType
        & PR.id .~ id'
      invocation :: PR.FromFunction'Invocation
      invocation = defMessage
        & PR.target .~ target
        & PR.argument .~ Any.pack msg
  sendMsgDelay (namespace, funcType, id') delay msg = do
      invocations <- gets functionStateDelayedInvocations
      modify (\old -> old { functionStateDelayedInvocations = invocations Seq.:|> invocation })
    where
      target :: PR.Address
      target = defMessage
        & PR.namespace .~ namespace
        & PR.type' .~ funcType
        & PR.id .~ id'
      invocation :: PR.FromFunction'DelayedInvocation
      invocation = defMessage
        & PR.delayInMs .~ fromIntegral delay
        & PR.target .~ target
        & PR.argument .~ Any.pack msg
  sendEgressMsg (namespace, egressType) msg = do
      invocations <- gets functionStateEgressMessages
      modify (\old -> old { functionStateEgressMessages = invocations Seq.:|> invocation })
    where
      invocation :: PR.FromFunction'EgressMessage
      invocation = defMessage
        & PR.egressNamespace .~ namespace
        & PR.egressType .~ egressType
        & PR.argument .~ Any.pack msg

data FlinkError = MissingInvocationBatch
                | ProtoUnpackError UnpackError
                | ProtoDeserializeError String
                | AesonDecodeError String
                | NoSuchFunction (Text, Text)
  deriving (Show, Eq)

invoke :: (StatefulFunc s m, MonadError FlinkError m, Message a, MonadReader (Env s) m, FromJSON s, ToJSON s) => (a -> m b) -> Any -> m b
invoke f input = f =<< liftEither (mapLeft ProtoUnpackError $ Any.unpack input)

runInvocations :: (StatefulFunc s m, MonadError FlinkError m, Message a, MonadReader (Env s) m, FromJSON s, ToJSON s) => (a -> m ()) -> PR.ToFunction'InvocationBatchRequest -> m ()
runInvocations func invocationBatch = do
    defaultCtx <- asks envDefaultCtx
    let initialCtx = maybe defaultCtx (getInitialCtx defaultCtx) (listToMaybe $ invocationBatch ^. PR.state)
    setInitialCtx initialCtx
    mapM_ (invoke func) ((^. PR.argument) <$> invocationBatch ^. PR.invocations)
  where
    getInitialCtx def pv = fromRight def (mapLeft AesonDecodeError $ Aeson.eitherDecode (BSL.fromStrict $ pv ^. PR.stateValue))

createFlinkResp :: (FromJSON s, ToJSON s) => FunctionState s -> FromFunction
createFlinkResp (FunctionState state' mutated invocations delayedInvocations egresses) =
  defMessage & PR.invocationResult .~
    (defMessage 
      & PR.stateMutations .~ toList stateMutations
      & PR.outgoingMessages .~ toList invocations
      & PR.delayedInvocations .~ toList delayedInvocations
      & PR.outgoingEgresses .~ toList egresses)
  where
    stateMutations :: [PR.FromFunction'PersistedValueMutation]
    stateMutations = [ defMessage 
      & PR.mutationType .~ PR.FromFunction'PersistedValueMutation'MODIFY
      & PR.stateName .~ "flink_state"
      & PR.stateValue .~ toStrict (Aeson.encode state')
      | mutated ]

type FlinkApi =
  "statefun" :> ReqBody '[Proto] ToFunction :> Post '[Proto] FromFunction

flinkApi :: Proxy FlinkApi
flinkApi = Proxy

flinkServer :: (ToJSON s, FromJSON s) => s -> Map (Text, Text) (PR.ToFunction'InvocationBatchRequest -> Function s ()) -> Server FlinkApi
flinkServer initialCtx functions toFunction = do
  (res, (namespace, type', id')) <- runBatch toFunction
  let env = Env initialCtx namespace type' id'
  (err, finalState) <- liftIO $ runReaderT (runStateT (runExceptT $ runFunction res) newState) env
  liftEither (mapLeft flinkErrToServant err)
  return $ createFlinkResp finalState
  where
    runBatch toFunc = do
      batch <- getBatch toFunc
      (function, address) <- findFunc (batch ^. PR.target)
      pure (function batch, address)
    getBatch input = maybe (throwError $ flinkErrToServant MissingInvocationBatch) return (input ^? PR.maybe'request . _Just . PR._ToFunction'Invocation')
    findFunc addr = do
        res <- maybe (throwError $ flinkErrToServant $ NoSuchFunction (namespace, type')) return (Map.lookup (namespace, type') functions)
        return (res, address)
      where
        address@(namespace, type', _) = (addr ^. PR.namespace, addr ^. PR.type', addr ^. PR.id)

flinkErrToServant :: FlinkError -> ServerError
flinkErrToServant err = case err of
  MissingInvocationBatch -> err400 { errBody = "Invocation batch missing" }
  ProtoUnpackError unpackErr -> err400 { errBody = "Failed to unpack protobuf Any " <>  BSL.pack (show unpackErr) }
  ProtoDeserializeError protoErr -> err400 { errBody = "Could not deserialize protobuf " <> BSL.pack protoErr }
  AesonDecodeError aesonErr -> err400 { errBody = "Invalid JSON " <> BSL.pack aesonErr }
  NoSuchFunction (namespace, type') -> err400 { errBody = "No such function " <> T.encodeUtf8 (fromStrict namespace) <> T.encodeUtf8 (fromStrict type') }

createApp :: (ToJSON s, FromJSON s) => s -> Map (Text, Text) (PR.ToFunction'InvocationBatchRequest -> Function s ()) -> Application
createApp initialCtx funcs = serve flinkApi (flinkServer initialCtx funcs)

kafkaRecord :: (Message v) => Text -> Text -> v -> Kafka.KafkaProducerRecord
kafkaRecord topic k v = 
  defMessage
    & Kafka.topic .~ topic
    & Kafka.key .~ k
    & Kafka.valueBytes .~ encodeMessage v