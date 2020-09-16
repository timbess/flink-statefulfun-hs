module Network.Flink.Stateful
  ( StatefulFunc
      ( insideCtx,
        getCtx,
        setCtx,
        modifyCtx,
        sendMsg,
        sendMsgDelay,
        sendEgressMsg
      ),
    makeConcrete,
    createApp,
    flinkServer,
    flinkApi,
    kafkaRecord,
    Function,
    FlinkState (..),
    FunctionTable
  )
where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State (MonadState, StateT (..), gets, modify)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Either.Combinators (mapLeft)
import Data.Foldable (Foldable (toList))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (listToMaybe)
import Data.ProtoLens (Message, defMessage, encodeMessage)
import Data.ProtoLens.Any (UnpackError)
import qualified Data.ProtoLens.Any as Any
import Data.ProtoLens.Prism
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import Data.Text.Lazy (fromStrict)
import qualified Data.Text.Lazy.Encoding as T
import Lens.Family2
import Network.Flink.ProtoServant (Proto)
import Proto.Google.Protobuf.Any (Any)
import qualified Proto.Kafka as Kafka
import qualified Proto.Kafka_Fields as Kafka
import Proto.RequestReply (FromFunction, ToFunction)
import qualified Proto.RequestReply as PR
import qualified Proto.RequestReply_Fields as PR
import Servant

type FunctionTable = Map (Text, Text) (ByteString, ByteString -> Env -> PR.ToFunction'InvocationBatchRequest -> IO (Either FlinkError (FunctionState ByteString)))

data Env = Env
  { envFunctionNamespace :: Text,
    envFunctionType :: Text,
    envFunctionId :: Text
  }
  deriving (Show)

data FunctionState ctx = FunctionState
  { functionStateCtx :: ctx,
    functionStateMutated :: Bool,
    functionStateInvocations :: Seq PR.FromFunction'Invocation,
    functionStateDelayedInvocations :: Seq PR.FromFunction'DelayedInvocation,
    functionStateEgressMessages :: Seq PR.FromFunction'EgressMessage
  }
  deriving (Show, Functor)

newState :: a -> FunctionState a
newState initialCtx = FunctionState initialCtx False mempty mempty mempty

newtype Function s a = Function {runFunction :: ExceptT FlinkError (StateT (FunctionState s) (ReaderT Env IO)) a}
  deriving (Monad, Applicative, Functor, MonadState (FunctionState s), MonadError FlinkError, MonadIO, MonadReader Env)

-- deriving instance  Monad (StateT (FunctionState ctx) Identity) => Monad Function

class FlinkState s where
  decodeState :: ByteString -> Either String s
  encodeState :: s -> ByteString

instance FlinkState () where
  decodeState _ = pure ()
  encodeState _ = ""

class MonadIO m => StatefulFunc s m | m -> s where
  -- Internal
  setInitialCtx :: s -> m ()

  -- Public
  insideCtx :: (s -> a) -> m a
  getCtx :: m s
  setCtx :: s -> m ()
  modifyCtx :: (s -> s) -> m ()
  sendMsg ::
    Message a =>
    -- | Function address (namespace, type, id)
    (Text, Text, Text) ->
    -- | protobuf message to send
    a ->
    m ()
  sendMsgDelay ::
    Message a =>
    -- | Function address (namespace, type, id)
    (Text, Text, Text) ->
    -- | delay before message send
    Int ->
    -- | protobuf message to send
    a ->
    m ()
  sendEgressMsg ::
    Message a =>
    -- | egress address (namespace, type)
    (Text, Text) ->
    -- | protobuf message to send (should be a Kafka or Kinesis protobuf record)
    a ->
    m ()

instance (FlinkState s) => StatefulFunc s (Function s) where
  setInitialCtx ctx = modify (\old -> old {functionStateCtx = ctx})

  insideCtx func = func <$> getCtx
  getCtx = gets functionStateCtx
  setCtx new = modify (\old -> old {functionStateCtx = new, functionStateMutated = True})
  modifyCtx mutator = mutator <$> getCtx >>= setCtx
  sendMsg (namespace, funcType, id') msg = do
    invocations <- gets functionStateInvocations
    modify (\old -> old {functionStateInvocations = invocations Seq.:|> invocation})
    where
      target :: PR.Address
      target =
        defMessage
          & PR.namespace .~ namespace
          & PR.type' .~ funcType
          & PR.id .~ id'
      invocation :: PR.FromFunction'Invocation
      invocation =
        defMessage
          & PR.target .~ target
          & PR.argument .~ Any.pack msg
  sendMsgDelay (namespace, funcType, id') delay msg = do
    invocations <- gets functionStateDelayedInvocations
    modify (\old -> old {functionStateDelayedInvocations = invocations Seq.:|> invocation})
    where
      target :: PR.Address
      target =
        defMessage
          & PR.namespace .~ namespace
          & PR.type' .~ funcType
          & PR.id .~ id'
      invocation :: PR.FromFunction'DelayedInvocation
      invocation =
        defMessage
          & PR.delayInMs .~ fromIntegral delay
          & PR.target .~ target
          & PR.argument .~ Any.pack msg
  sendEgressMsg (namespace, egressType) msg = do
    egresses <- gets functionStateEgressMessages
    modify (\old -> old {functionStateEgressMessages = egresses Seq.:|> egressMsg})
    where
      egressMsg :: PR.FromFunction'EgressMessage
      egressMsg =
        defMessage
          & PR.egressNamespace .~ namespace
          & PR.egressType .~ egressType
          & PR.argument .~ Any.pack msg

data FlinkError
  = MissingInvocationBatch
  | ProtoUnpackError UnpackError
  | ProtoDeserializeError String
  | StateDecodeError String
  | NoSuchFunction (Text, Text)
  deriving (Show, Eq)

invoke :: (FlinkState s, StatefulFunc s m, MonadError FlinkError m, Message a, MonadReader Env m) => (a -> m b) -> Any -> m b
invoke f input = f =<< liftEither (mapLeft ProtoUnpackError $ Any.unpack input)

makeConcrete :: (FlinkState s, Message a) => (a -> Function s ()) -> ByteString -> Env -> PR.ToFunction'InvocationBatchRequest -> IO (Either FlinkError (FunctionState ByteString))
makeConcrete func initialContext env invocationBatch = runExceptT $ do
  deserializedContext <- liftEither $ mapLeft StateDecodeError $ decodeState initialContext
  (err, finalState) <- liftIO $ runner (newState deserializedContext)
  liftEither err
  return $ encodeState <$> finalState
  where
    runner state = runReaderT (runStateT (runExceptT $ runFunction runWithCtx) state) env
    runWithCtx = do
      defaultCtx <- gets functionStateCtx
      let initialCtx = getInitialCtx defaultCtx (listToMaybe $ invocationBatch ^. PR.state)
      case initialCtx of
        Left err -> throwError err
        Right ctx -> setInitialCtx ctx
      mapM_ (invoke func) ((^. PR.argument) <$> invocationBatch ^. PR.invocations)

    getInitialCtx def pv = handleEmptyState def $ (^. PR.stateValue) <$> pv
    handleEmptyState def state' = case state' of
      Just "" -> return def
      Just other -> mapLeft StateDecodeError $ decodeState other
      Nothing -> return def

createFlinkResp :: FunctionState ByteString -> FromFunction
createFlinkResp (FunctionState state mutated invocations delayedInvocations egresses) =
  defMessage & PR.invocationResult
    .~ ( defMessage
           & PR.stateMutations .~ toList stateMutations
           & PR.outgoingMessages .~ toList invocations
           & PR.delayedInvocations .~ toList delayedInvocations
           & PR.outgoingEgresses .~ toList egresses
       )
  where
    stateMutations :: [PR.FromFunction'PersistedValueMutation]
    stateMutations =
      [ defMessage
          & PR.mutationType .~ PR.FromFunction'PersistedValueMutation'MODIFY
          & PR.stateName .~ "flink_state"
          & PR.stateValue .~ state
        | mutated
      ]

type FlinkApi =
  "statefun" :> ReqBody '[Proto] ToFunction :> Post '[Proto] FromFunction

flinkApi :: Proxy FlinkApi
flinkApi = Proxy

createApp :: FunctionTable -> Application
createApp funcs = serve flinkApi (flinkServer funcs)

flinkServer :: FunctionTable -> Server FlinkApi
flinkServer functions toFunction = do
  batch <- getBatch toFunction
  ((initialCtx, function), (namespace, type', id')) <- findFunc (batch ^. PR.target)
  result <- liftIO $ function initialCtx (Env namespace type' id') batch
  finalState <- liftEither $ mapLeft flinkErrToServant result
  return $ createFlinkResp finalState
  where
    getBatch input = maybe (throwError $ flinkErrToServant MissingInvocationBatch) return (input ^? PR.maybe'request . _Just . PR._ToFunction'Invocation')
    findFunc addr = do
      res <- maybe (throwError $ flinkErrToServant $ NoSuchFunction (namespace, type')) return (Map.lookup (namespace, type') functions)
      return (res, address)
      where
        address@(namespace, type', _) = (addr ^. PR.namespace, addr ^. PR.type', addr ^. PR.id)

flinkErrToServant :: FlinkError -> ServerError
flinkErrToServant err = case err of
  MissingInvocationBatch -> err400 {errBody = "Invocation batch missing"}
  ProtoUnpackError unpackErr -> err400 {errBody = "Failed to unpack protobuf Any " <> BSL.pack (show unpackErr)}
  ProtoDeserializeError protoErr -> err400 {errBody = "Could not deserialize protobuf " <> BSL.pack protoErr}
  StateDecodeError decodeErr -> err400 {errBody = "Invalid JSON " <> BSL.pack decodeErr}
  NoSuchFunction (namespace, type') -> err400 {errBody = "No such function " <> T.encodeUtf8 (fromStrict namespace) <> T.encodeUtf8 (fromStrict type')}

kafkaRecord :: (Message v) => Text -> Text -> v -> Kafka.KafkaProducerRecord
kafkaRecord topic k v =
  defMessage
    & Kafka.topic .~ topic
    & Kafka.key .~ k
    & Kafka.valueBytes .~ encodeMessage v
