-- | Support for handling errors of a particular type, i.e. checked exceptions.
--
-- /Note:/ the 'Error' effect is a suitable replacement for the
-- 'Control.Monad.Trans.Except.ExceptT' monad transformer from the
-- @transformers@ library. It is __not__ a general mechanism for handling
-- exceptions, that's what functions from the @exceptions@ library are for (see
-- "Control.Monad.Catch" for more information).
--
-- In particular, regular exceptions of type @e@ are distinct from errors of
-- type @e@ and will __not__ be caught by functions from this module:
--
-- >>> import qualified Control.Monad.Catch as E
-- >>> let boom = error "BOOM!"
-- >>> runEff . runError @ErrorCall $ boom `catchError` \_ (_::ErrorCall) -> pure "caught"
-- *** Exception: BOOM!
-- ...
--
-- If you want to catch regular exceptions, you should use
-- 'Control.Monad.Catch.catch' (or a similar function):
--
-- >>> runEff $ boom `E.catch` \(_::ErrorCall) -> pure "caught"
-- "caught"
--
-- On the other hand, functions for safe finalization and management of
-- resources such as 'Control.Monad.Catch.finally' and
-- 'Control.Monad.Catch.bracket' work as expected:
--
-- >>> let display = liftIO . putStrLn
-- >>> :{
-- runEff . fmap (either (Left . snd) Right) . runError @String $ do
--   E.bracket_ (display "Beginning.")
--              (display "Cleaning up.")
--              (display "Computing." >> throwError "oops" >> display "More.")
-- :}
-- Beginning.
-- Computing.
-- Cleaning up.
-- Left "oops"
--
module Effectful.Error
 ( Error
 , runError
 , throwError
 , catchError
 , handleError
 , tryError

 -- * Re-exports
 , HasCallStack
 , CallStack
 , getCallStack
 , prettyCallStack
 ) where

import Control.Exception
import Data.Typeable
import Data.Unique
import GHC.Stack

import Effectful.Dispatch.Static
import Effectful.Monad

-- | Provide the ability to handle errors of type @e@.
newtype Error e :: Effect where
  Error :: ErrorId -> Error e m r

-- | Handle errors of type @e@.
runError
  :: forall e es a. Typeable e
  => Eff (Error e : es) a
  -> Eff es (Either (CallStack, e) a)
runError m = unsafeEff $ \es0 -> mask $ \release -> do
  eid <- newErrorId
  size0 <- sizeEnv es0
  es <- unsafeConsEnv (IdA (Error @e eid)) noRelinker es0
  r <- tryErrorIO release eid es `onException` unsafeTailEnv size0 es
  unsafeTailEnv size0 es
  pure r
  where
    tryErrorIO release eid es = try (release $ unEff m es) >>= \case
      Right a -> pure $ Right a
      Left ex -> tryHandler ex eid (\cs e -> Left (cs, e))
               $ throwIO ex

-- | Throw an error of type @e@.
throwError
  :: forall e es a. (HasCallStack, Typeable e, Error e :> es)
  => e
  -- ^ The error.
  -> Eff es a
throwError e = unsafeEff $ \es -> do
  IdA (Error eid) <- getEnv @(Error e) es
  throwIO $ ErrorEx eid callStack e

-- | Handle an error of type @e@.
catchError
  :: forall e es a. (Typeable e, Error e :> es)
  => Eff es a
  -- ^ The inner computation.
  -> (CallStack -> e -> Eff es a)
  -- ^ A handler for errors in the inner computation.
  -> Eff es a
catchError m handler = unsafeEff $ \es -> do
  IdA (Error eid) <- getEnv @(Error e) es
  size <- sizeEnv es
  catchErrorIO eid (unEff m es) $ \cs e -> do
    checkSizeEnv size es
    unEff (handler cs e) es

-- | The same as @'flip' 'catchError'@, which is useful in situations where the
-- code for the handler is shorter.
handleError
  :: forall e es a. (Typeable e, Error e :> es)
  => (CallStack -> e -> Eff es a)
  -- ^ A handler for errors in the inner computation.
  -> Eff es a
  -- ^ The inner computation.
  -> Eff es a
handleError = flip catchError

-- | Similar to 'catchError', but returns an 'Either' result which is a 'Right'
-- if no error was thrown and a 'Left' otherwise.
tryError
  :: forall e es a. (Typeable e, Error e :> es)
  => Eff es a
  -- ^ The inner computation.
  -> Eff es (Either (CallStack, e) a)
tryError m = (Right <$> m) `catchError` \es e -> pure $ Left (es, e)

----------------------------------------
-- Helpers

newtype ErrorId = ErrorId Unique
  deriving Eq

-- | A unique is picked so that distinct 'Error' handlers for the same type
-- don't catch each other's exceptions.
newErrorId :: IO ErrorId
newErrorId = ErrorId <$> newUnique

tryHandler
  :: Typeable e
  => SomeException
  -> ErrorId
  -> (CallStack -> e -> r)
  -> IO r
  -> IO r
tryHandler ex eid0 handler next = case fromException ex of
  Just (ErrorEx eid cs e)
    | eid0 == eid -> pure $ handler cs e
    | otherwise   -> next
  Nothing -> next

data ErrorEx e = ErrorEx !ErrorId CallStack e
instance Typeable e => Show (ErrorEx e) where
  showsPrec p (ErrorEx _ cs e)
    = ("Effectful.Error.ErrorEx (" ++)
    . showsPrec p (typeOf e)
    . (") " ++)
    . showsPrec p cs
instance Typeable e => Exception (ErrorEx e)

catchErrorIO :: Typeable e => ErrorId -> IO a -> (CallStack -> e -> IO a) -> IO a
catchErrorIO eid m handler = do
  m `catch` \err@(ErrorEx etag e cs) -> do
    if eid == etag
      then handler e cs
      else throwIO err
