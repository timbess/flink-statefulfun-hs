-- | This module is used to store all the
-- utility functions used for testing.
module Network.Flink.Test (testStatefulFunc) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (ReaderT (runReaderT))
import Control.Monad.State (StateT (..))
import Data.Either.Combinators (fromRight')
import Data.Functor (($>))
import Network.Flink.Internal.Stateful
  ( Env (Env),
    Function (runFunction),
    FunctionState,
    newState,
  )

-- | Function for testing stateful functions locally.
--
-- Runs function given some initial state and
-- input message. The final state of the function
-- is returned along with all messages, egress, etc.
-- that were queued up to be sent to Flink during execution.
--
-- Function contains __unsafe__ code, don't use for anything but test cases.
testStatefulFunc ::
  -- | Initial state for test run
  s ->
  -- | Function to run
  (a -> Function s ()) ->
  -- | Input message
  a ->
  IO (FunctionState s)
testStatefulFunc initialCtx func input = runner (newState initialCtx)
  where
    env = Env "test_namespace" "test_function" "placeholder_id"
    runner state = do
      (res, state') <- runReaderT (runStateT (runExceptT $ runFunction (func input)) state) env
      return $ fromRight' (res $> state')
