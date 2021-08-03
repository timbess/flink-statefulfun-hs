{-# LANGUAGE PatternSynonyms #-}
module Network.Flink.Internal.Stateful
  ( StatefulFunc
      ( insideCtx,
        getCtx,
        setCtx,
        modifyCtx,
        sendMsg,
        sendMsgDelay,
        sendEgressMsg
      ),
    flinkWrapper,
    createApp,
    flinkServer,
    flinkApi,
    Address(.., Address'),
    FuncType (..),
    Function (..),
    Serde (..),
    FunctionState (..),
    FlinkError (..),
    FunctionTable,
    Env (..),
    Expiration(..),
    ExpirationMode(..),
    newState,
    ProtoSerde (..),
    JsonSerde (..),
    jsonState,
    protoState,
    sendProtoMsg,
    sendProtoMsgDelay
  )
where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State (MonadState, StateT (..), gets, modify)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Either.Combinators (mapLeft)
import Data.Foldable (Foldable (toList))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.ProtoLens (Message, defMessage, encodeMessage, messageName)
import Data.ProtoLens.Any (UnpackError)
import Data.ProtoLens.Encoding (decodeMessage)
import Data.ProtoLens.Prism
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import Data.Text.Lazy (fromStrict)
import Data.Coerce ( coerce )
import qualified Data.Text.Lazy.Encoding as T
import Lens.Family2
import Lens.Micro ( traversed, filtered )
import Network.Flink.Internal.ProtoServant (Proto)
import Proto.RequestReply (FromFunction, ToFunction)
import qualified Proto.RequestReply as PR
import qualified Proto.RequestReply_Fields as PR
import Servant

import Data.Time.Clock ( NominalDiffTime )

data FuncType = FuncType Text Text deriving (Eq, Ord)
data Address = Address FuncType Text

{-# COMPLETE Address' #-}
pattern Address' :: Text -> Text -> Text -> Address
pattern Address' fnamespace fnTp fid = Address (FuncType fnamespace fnTp) fid

data FuncRes = IncompleteContext Expiration Text | UpdatedState (FunctionState PR.TypedValue) deriving Show
type FuncExec = Env -> PR.ToFunction'InvocationBatchRequest -> IO (Either FlinkError FuncRes)
--- | Table of stateful functions `(functionNamespace, functionType) -> function
type FunctionTable = Map FuncType FuncExec

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

data ExpirationMode =  NONE | AFTER_WRITE | AFTER_CALL deriving (Show, Eq)

data Expiration = Expiration {
  emode :: ExpirationMode,
  expireAfterMillis :: NominalDiffTime
} deriving (Show, Eq)

-- | Monad stack used for the execution of a Flink stateful function
-- Don't reference this directly in your code if possible
newtype Function s a = Function {runFunction :: ExceptT FlinkError (StateT (FunctionState s) (ReaderT Env IO)) a}
  deriving (Monad, Applicative, Functor, MonadState (FunctionState s), MonadError FlinkError, MonadIO, MonadReader Env)

class Serde a where
  -- | Type name
  tpName :: Proxy a -> Text

  -- | decodes types from strict 'ByteString's
  deserializeBytes :: ByteString -> Either String a

  -- | encodes types to strict 'ByteString's
  serializeBytes :: a -> ByteString

newtype ProtoSerde a = ProtoSerde {getProto :: a}
  deriving (Functor)

instance Message a => Serde (ProtoSerde a) where
  tpName px = "type.googleapis.com/" <> messageName (unliftP px)
    where unliftP :: Proxy (f a) -> Proxy a
          unliftP Proxy = Proxy
  deserializeBytes a = ProtoSerde <$> decodeMessage a
  serializeBytes (ProtoSerde a) = encodeMessage a

type Json a = (FromJSON a, ToJSON a)

newtype JsonSerde a = JsonSerde {getJson :: a}
  deriving (Functor)

instance Json a => Serde (JsonSerde a) where
  tpName _ = "json/json" -- TODO: add adt name
  deserializeBytes a = JsonSerde <$> eitherDecode (BSL.fromStrict a)
  serializeBytes (JsonSerde a) = BSL.toStrict $ encode a

instance Serde () where
  tpName _ = "ghc/Unit"
  deserializeBytes _ = pure ()
  serializeBytes _ = ""

instance Serde ByteString where
  tpName _ = "ghc/Data.ByteString"
  deserializeBytes = pure
  serializeBytes = id

instance Serde BSL.ByteString where
  tpName _ = "ghc/Data.ByteString.Lazy"
  deserializeBytes = pure . BSL.fromStrict
  serializeBytes = BSL.toStrict

-- | Used to represent all Flink stateful function capabilities.
--
-- Contexts are received from Flink and deserializeBytesd into `s`
-- all modifications to state are shipped back to Flink at the end of the
-- batch to be persisted.
--
-- Message passing is also queued up and passed back at the end of the current
-- batch.
class MonadIO m => StatefulFunc s m | m -> s where
  -- Internal
  setInitialCtx :: s -> m ()

  -- Public
  insideCtx :: (s -> a) -> m a
  getCtx :: m s
  setCtx :: s -> m ()
  modifyCtx :: (s -> s) -> m ()
  sendEgressMsg ::
    Message a =>
    -- | egress address (namespace, type)
    (Text, Text) ->
    -- | protobuf message to send (should be a Kafka or Kinesis protobuf record)
    a ->
    m ()
  sendMsg ::
    Serde a =>
    -- | Function address (namespace, type, id)
    Address ->
    -- | message to send
    a ->
    m ()
  sendMsgDelay ::
    Serde a =>
    -- | Function address (namespace, type, id)
    Address ->
    -- | delay before message send
    NominalDiffTime ->
    -- | message to send
    a ->
    -- | returns cancelation token with which delivery of the message could be canceled
    m ()

instance StatefulFunc s (Function s) where
  setInitialCtx ctx = modify (\old -> old {functionStateCtx = ctx})

  insideCtx func = func <$> getCtx
  getCtx = gets functionStateCtx
  setCtx new = modify (\old -> old {functionStateCtx = new, functionStateMutated = True})
  modifyCtx mutator = getCtx >>= setCtx . mutator

  sendEgressMsg (namespace, egressType) msg = do
    egresses <- gets functionStateEgressMessages
    modify (\old -> old {functionStateEgressMessages = egresses Seq.:|> egressMsg})
    where
      wmsg = ProtoSerde msg
      egressMsg :: PR.FromFunction'EgressMessage
      egressMsg =
        defMessage
          & PR.egressNamespace .~ namespace
          & PR.egressType .~ egressType
          & PR.argument .~ tpValue
      tpValue =
        defMessage
          & PR.typename .~ tpName (pure wmsg)
          & PR.hasValue .~ True          
          & PR.value .~ serializeBytes wmsg

  sendMsg (Address' namespace funcType id') msg = do
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
          & PR.argument .~ tpValue
      tpValue =
        defMessage
          & PR.typename .~ tpName (pure msg)
          & PR.hasValue .~ True
          & PR.value .~ serializeBytes msg

  sendMsgDelay (Address' namespace funcType id') delay msg = do
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
          & PR.delayInMs .~ round (delay * 1000)
          & PR.target .~ target
          & PR.argument .~ tpValue
      tpValue =
        defMessage
          & PR.typename .~ tpName (pure msg)
          & PR.hasValue .~ True
          & PR.value .~ serializeBytes msg

-- | Convinience function to send protobuf messages
sendProtoMsg :: (StatefulFunc s m, Message a) => Address -> a -> m ()
sendProtoMsg addr = sendMsg addr . ProtoSerde

-- | Convinience function to send delayed protobuf messages
sendProtoMsgDelay :: (StatefulFunc s m, Message a) => Address -> NominalDiffTime -> a -> m ()
sendProtoMsgDelay addr delay = sendMsgDelay addr delay . ProtoSerde

data FlinkError
  = MissingInvocationBatch
  | ProtodeserializeBytesError String
  | InvalidTypePassedError Text Text
  | EmptyArgumentPassed
  | StateDecodeError String
  | MessageDecodeError String
  | ProtoMessageDecodeError UnpackError
  | NoSuchFunction (Text, Text)
  deriving (Show, Eq)

-- | Convenience function for wrapping state in newtype for JSON serialization
jsonState :: Json s => Function s () -> Function (JsonSerde s) ()
jsonState = coerce

-- | Convenience function for wrapping state in newtype for Protobuf serialization
protoState :: Message s => Function s () -> Function (ProtoSerde s) ()
protoState = coerce

-- | Tries to unwrap typed value, possibly throwing FlinkError on broken input
unwrapA :: forall a m. (Serde a, MonadError FlinkError m) => PR.TypedValue -> m (Maybe a)
unwrapA arg = let
      atp = arg ^. PR.typename
      ctp = tpName @a Proxy
      in if not (arg^. PR.hasValue) then pure Nothing else
           if atp /= ctp
              then throwError (InvalidTypePassedError ctp atp)
              else Just <$> (liftEither . mapLeft MessageDecodeError $ deserializeBytes @a (arg ^. PR.value))

-- | Takes a function taking an arbitrary state type and converts it to take 'ByteString's.
-- This allows each function in the 'FunctionTable' to take its own individual type of state and just expose
-- a function accepting 'ByteString' to the library code.
flinkWrapper :: forall a s. (Serde a, Serde s) => s -> Expiration -> (a -> Function s ()) -> FuncExec
flinkWrapper s0 expr func env invocationBatch = runExceptT $ do
  (eiRes, _) <- liftIO $ runner (newState s0)
  liftEither eiRes
  where
    passedArgs = invocationBatch ^.. PR.invocations . traversed . PR.argument
    mbInitCtx = (PR.state . traversed . filtered ((== "flink_state") . (^. PR.stateName)) . PR.stateValue) 
      `firstOf` invocationBatch
    runWithCtx = do
      case mbInitCtx of 
        Nothing -> return $ IncompleteContext expr (tpName @s Proxy) -- if state was not propagated to the function - shorcut to incomplete context reponse
        Just tv -> do 
          mbCtx <- unwrapA @s tv
          case mbCtx of
            Nothing -> pure () -- if null state value was propagated
            Just s1 -> setInitialCtx s1
          mbArgs <- traverse (unwrapA @a) passedArgs
          args <- traverse (maybe (throwError EmptyArgumentPassed) pure) mbArgs
          mapM_ func args
          gets (UpdatedState . fmap outS)
    runner state = runReaderT (runStateT (runExceptT $ runFunction runWithCtx) state) env
    outS fstate = defMessage
        & PR.typename .~ tpName (pure fstate)
        & PR.value .~ serializeBytes fstate

createFlinkResp :: FuncRes -> FromFunction
createFlinkResp (UpdatedState (FunctionState state mutated invocations delayedInvocations egresses)) =
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
createFlinkResp (IncompleteContext (Expiration mode expireTime) typeName) = 
  defMessage & PR.incompleteInvocationContext .~ ( 
    defMessage & PR.missingValues .~ [
      defMessage
        & PR.stateName .~ "flink_state"
        & PR.typeTypename .~ typeName
        & PR.expirationSpec .~ (
          defMessage 
            & PR.expireAfterMillis .~ round (expireTime * 1000.0)
            & PR.mode .~ pbmode mode)
      ])
  where pbmode NONE = PR.FromFunction'ExpirationSpec'NONE 
        pbmode AFTER_CALL = PR.FromFunction'ExpirationSpec'AFTER_INVOKE  
        pbmode AFTER_WRITE = PR.FromFunction'ExpirationSpec'AFTER_WRITE  

type FlinkApi =
  "statefun" :> ReqBody '[Proto] ToFunction :> Post '[Proto] FromFunction

flinkApi :: Proxy FlinkApi
flinkApi = Proxy

-- | Takes function table and creates a wai 'Application' to serve flink requests
createApp :: FunctionTable -> Application
createApp funcs = serve flinkApi (flinkServer funcs)

-- | Takes function table and creates a servant 'Server' to serve flink requests
flinkServer :: FunctionTable -> Server FlinkApi
flinkServer functions toFunction = do
  batch <- getBatch toFunction
  (function, (namespace, type', id')) <- findFunc (batch ^. PR.target)
  result <- liftIO $ function (Env namespace type' id') batch
  finalState <- liftEither $ mapLeft flinkErrToServant result
  return $ createFlinkResp finalState
  where
    getBatch input = maybe (throwError $ flinkErrToServant MissingInvocationBatch) return (input ^? PR.maybe'request . _Just . PR._ToFunction'Invocation')
    findFunc addr = do
      res <- maybe (throwError $ flinkErrToServant $ NoSuchFunction (namespace, type')) return (Map.lookup (FuncType namespace type') functions)
      return (res, address)
      where
        address@(namespace, type', _) = (addr ^. PR.namespace, addr ^. PR.type', addr ^. PR.id)

flinkErrToServant :: FlinkError -> ServerError
flinkErrToServant err = case err of
  MissingInvocationBatch -> err400 {errBody = "Invocation batch missing"}
  ProtodeserializeBytesError protoErr -> err400 {errBody = "Could not deserializeBytes protobuf " <> BSL.pack protoErr}
  StateDecodeError decodeErr -> err400 {errBody = "Invalid JSON " <> BSL.pack decodeErr}
  MessageDecodeError msg -> err400 {errBody = "Failed to decode message " <> BSL.pack msg}
  ProtoMessageDecodeError msg -> err400 {errBody = "Failed to decode message " <> BSL.pack (show msg)}
  NoSuchFunction (namespace, type') -> err400 {errBody = "No such function " <> T.encodeUtf8 (fromStrict namespace) <> T.encodeUtf8 (fromStrict type')}
  InvalidTypePassedError expected passed -> err400 {errBody = "Expected type " <> T.encodeUtf8 (fromStrict expected) <> ", got " <>  T.encodeUtf8 (fromStrict passed)}
  EmptyArgumentPassed -> err400 {errBody = "Empty argument was passed to the function" }