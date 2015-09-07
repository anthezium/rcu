{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_HADDOCK not-home #-}

-- | STM-based RCU with concurrent writers
module Control.Concurrent.RCU.Internal
  ( SRef(..)
  , RCUThread(..)
  , RCU(..)
  , runRCU
  , R(..)
  , W(..)
  , MonadNew(..)
  , MonadReading(..)
  , MonadWriting(..)
  , MonadRCU(..)
  ) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Control.Monad.Trans.Identity
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Reader
import Data.Coerce
import Data.Int
import Prelude hiding (read, Read)
import qualified Control.Monad.Trans.RWS.Lazy as Lazy
import qualified Control.Monad.Trans.RWS.Strict as Strict
import qualified Control.Monad.Trans.State.Lazy as Lazy
import qualified Control.Monad.Trans.State.Strict as Strict
import qualified Control.Monad.Trans.Writer.Lazy as Lazy
import qualified Control.Monad.Trans.Writer.Strict as Strict

--------------------------------------------------------------------------------
-- * Shared References
--------------------------------------------------------------------------------

newtype SRef s a = SRef { unSRef :: TVar a }

--------------------------------------------------------------------------------
-- * MonadNew
--------------------------------------------------------------------------------

class Monad m => MonadNew s m | m -> s where
  newSRef :: a -> m (SRef s a)
  default newSRef :: (m ~ t n, MonadTrans t, MonadNew s n) => a -> m (SRef s a)
  newSRef a = lift (newSRef a)

instance MonadNew s m => MonadNew s (ReaderT e m)
instance (MonadNew s m, Monoid w) => MonadNew s (Strict.WriterT w m)
instance (MonadNew s m, Monoid w) => MonadNew s (Lazy.WriterT w m)
instance MonadNew s' m => MonadNew s' (Strict.StateT s m)
instance MonadNew s' m => MonadNew s' (Lazy.StateT s m)
instance (MonadNew s' m, Monoid w) => MonadNew s' (Strict.RWST r w s m)
instance (MonadNew s' m, Monoid w) => MonadNew s' (Lazy.RWST r w s m)
instance MonadNew s m => MonadNew s (ExceptT e m)
instance MonadNew s m => MonadNew s (MaybeT m)
instance MonadNew s m => MonadNew s (IdentityT m)

--------------------------------------------------------------------------------
-- * MonadReading
--------------------------------------------------------------------------------

-- | This is a read-side critical section
class MonadNew s m => MonadReading s m | m -> s where
  readSRef :: SRef s a -> m a
  default readSRef :: (m ~ t n, MonadTrans t, MonadReading s n) => SRef s a -> m a
  readSRef r = lift (readSRef r)

instance MonadReading s m => MonadReading s (ReaderT e m)
instance (MonadReading s m, Monoid w) => MonadReading s (Strict.WriterT w m)
instance (MonadReading s m, Monoid w) => MonadReading s (Lazy.WriterT w m)
instance MonadReading s' m => MonadReading s' (Strict.StateT s m)
instance MonadReading s' m => MonadReading s' (Lazy.StateT s m)
instance (MonadReading s' m, Monoid w) => MonadReading s' (Strict.RWST r w s m)
instance (MonadReading s' m, Monoid w) => MonadReading s' (Lazy.RWST r w s m)
instance MonadReading s m => MonadReading s (ExceptT e m)
instance MonadReading s m => MonadReading s (MaybeT m)
instance MonadReading s m => MonadReading s (IdentityT m)

--------------------------------------------------------------------------------
-- * MonadWriting
--------------------------------------------------------------------------------

-- | This is a write-side critical section
class MonadReading s m => MonadWriting s m | m -> s where
  writeSRef :: SRef s a -> a -> m ()
  default writeSRef :: (m ~ t n, MonadTrans t, MonadWriting s n) => SRef s a -> a -> m ()
  writeSRef r a = lift (writeSRef r a)

  synchronize :: m ()
  default synchronize :: (m ~ t n, MonadTrans t, MonadWriting s n) => m ()
  synchronize = lift synchronize

instance MonadWriting s m => MonadWriting s (ReaderT e m)
instance (MonadWriting s m, Monoid w) => MonadWriting s (Strict.WriterT w m)
instance (MonadWriting s m, Monoid w) => MonadWriting s (Lazy.WriterT w m)
instance MonadWriting s m => MonadWriting s (Strict.StateT s m)
instance MonadWriting s m => MonadWriting s (Lazy.StateT s m)
instance (MonadWriting s m, Monoid w) => MonadWriting s (Strict.RWST r w s m)
instance (MonadWriting s m, Monoid w) => MonadWriting s (Lazy.RWST r w s m)
instance MonadWriting s m => MonadWriting s (IdentityT m)
instance MonadWriting s m => MonadWriting s (ExceptT e m)
instance MonadWriting s m => MonadWriting s (MaybeT m)

--------------------------------------------------------------------------------
-- * MonadRCU
--------------------------------------------------------------------------------

-- | This is the executor service that can fork, join and execute critical sections.
class
  ( MonadReading s (Reading m)
  , MonadWriting s (Writing m)
  , MonadNew s m
  ) => MonadRCU s m | m -> s where

  -- | a read-side critical section
  type Reading m :: * -> *

  -- | a write-side critical section
  type Writing m :: * -> *

  -- | threads we can fork and join
  type Thread m :: * -> *

  -- | Fork a thread
  forking  :: m a -> m (Thread m a)

  -- | Join a thread
  joining  :: Thread m a -> m a

  -- | run a read-side critical section
  reading :: Reading m a -> m a

  -- | run a write-side critical section
  writing :: Writing m a -> m a

instance MonadRCU s m => MonadRCU s (ReaderT e m) where
  type Reading (ReaderT e m) = ReaderT e (Reading m)
  type Writing (ReaderT e m) = ReaderT e (Writing m)
  type Thread (ReaderT e m) = Thread m
  forking (ReaderT f)  = ReaderT $ \a -> forking (f a)
  joining = lift . joining
  reading (ReaderT f) = ReaderT $ \a -> reading (f a)
  writing (ReaderT f) = ReaderT $ \a -> writing (f a)

instance MonadRCU s m => MonadRCU s (IdentityT m) where
  type Reading (IdentityT m) = Reading m
  type Writing (IdentityT m) = Writing m
  type Thread (IdentityT m) = Thread m
  forking (IdentityT m) = IdentityT (forking m)
  joining = lift . joining
  reading m = IdentityT (reading m)
  writing m = IdentityT (writing m)

instance MonadRCU s m => MonadRCU s (ExceptT e m) where
  type Reading (ExceptT e m) = ExceptT e (Reading m)
  type Writing (ExceptT e m) = ExceptT e (Writing m)
  type Thread (ExceptT e m) = ExceptT e (Thread m)
  forking (ExceptT m) = lift $ ExceptT <$> forking m
  joining (ExceptT m) = ExceptT $ joining m
  reading (ExceptT m) = ExceptT $ reading m
  writing (ExceptT m) = ExceptT $ writing m

instance MonadRCU s m => MonadRCU s (MaybeT m) where
  type Reading (MaybeT m) = MaybeT (Reading m)
  type Writing (MaybeT m) = MaybeT (Writing m)
  type Thread (MaybeT m) = MaybeT (Thread m)
  forking (MaybeT m) = lift $ MaybeT <$> forking m
  joining (MaybeT m) = MaybeT $ joining m
  reading (MaybeT m) = MaybeT $ reading m
  writing (MaybeT m) = MaybeT $ writing m

instance (MonadRCU s m, Monoid e) => MonadRCU s (Strict.WriterT e m) where
  type Reading (Strict.WriterT e m) = Strict.WriterT e (Reading m)
  type Writing (Strict.WriterT e m) = Strict.WriterT e (Writing m)
  type Thread (Strict.WriterT e m) = Strict.WriterT e (Thread m)
  forking (Strict.WriterT m) = lift $ Strict.WriterT <$> forking m
  joining (Strict.WriterT m) = Strict.WriterT $ joining m
  reading (Strict.WriterT m) = Strict.WriterT $ reading m
  writing (Strict.WriterT m) = Strict.WriterT $ writing m

instance (MonadRCU s m, Monoid e) => MonadRCU s (Lazy.WriterT e m) where
  type Reading (Lazy.WriterT e m) = Lazy.WriterT e (Reading m)
  type Writing (Lazy.WriterT e m) = Lazy.WriterT e (Writing m)
  type Thread (Lazy.WriterT e m) = Lazy.WriterT e (Thread m)
  forking (Lazy.WriterT m) = lift $ Lazy.WriterT <$> forking m
  joining (Lazy.WriterT m) = Lazy.WriterT $ joining m
  reading (Lazy.WriterT m) = Lazy.WriterT $ reading m
  writing (Lazy.WriterT m) = Lazy.WriterT $ writing m

--------------------------------------------------------------------------------
-- * Read-Side Critical Sections
--------------------------------------------------------------------------------

newtype R s a = R { runR :: IO a } deriving (Functor, Applicative, Monad)

instance MonadNew s (R s) where
  newSRef = r where
    r :: forall a. a -> R s (SRef s a)
    r = coerce (newTVarIO :: a -> IO (TVar a))

instance MonadReading s (R s) where
  readSRef = r where
    r :: forall a. SRef s a -> R s a
    r = coerce (readTVarIO :: TVar a -> IO a)

--------------------------------------------------------------------------------
-- * Write-Side Critical Sections
--------------------------------------------------------------------------------

newtype W s a = W { runW :: TVar Int64 -> STM a }
  deriving Functor

instance Applicative (W s) where
  pure a = W $ \ _ -> pure a
  W mf <*> W ma = W $ \c -> mf c <*> ma c

instance Monad (W s) where
  return a = W $ \ _ -> pure a
  W m >>= f = W $ \ c -> do
    a <- m c
    runW (f a) c
  fail s = W $ \ _ -> fail s

instance Alternative (W s) where
  empty = W $ \ _ -> empty
  W ma <|> W mb = W $ \c -> ma c <|> mb c

instance MonadPlus (W s) where
  mzero = W $ \ _ -> mzero
  W ma `mplus` W mb = W $ \c -> ma c `mplus` mb c

instance MonadNew s (W s) where
  newSRef a = W $ \_ -> SRef <$> newTVar a

instance MonadReading s (W s) where
  readSRef (SRef r) = W $ \ _ -> readTVar r

instance MonadWriting s (W s) where
  writeSRef (SRef r) a = W $ \ _ -> writeTVar r a
  synchronize = W $ \ c -> modifyTVar' c (+1)

--------------------------------------------------------------------------------
-- * RCU Context
--------------------------------------------------------------------------------

newtype RCU s a = RCU { unRCU :: TVar Int64 -> IO a }
  deriving Functor

instance Applicative (RCU s) where
  pure = return
  (<*>) = ap

instance Monad (RCU s) where
  return a = RCU $ \ _ -> return a
  RCU m >>= f = RCU $ \s -> do
    a <- m s
    unRCU (f a) s

instance MonadNew s (RCU s) where
  newSRef a = RCU $ \_ -> SRef <$> newTVarIO a

-- | For now we don't bother to hold onto the thread id
data RCUThread s a = RCUThread
  { rcuThreadId :: {-# UNPACK #-} !ThreadId
  , rcuThreadVar :: {-# UNPACK #-} !(MVar a)
  }

instance MonadRCU s (RCU s) where
  type Reading (RCU s) = R s
  type Writing (RCU s) = W s
  type Thread (RCU s) = RCUThread s
  forking (RCU m) = RCU $ \ c -> do
    result <- newEmptyMVar
    tid <- forkIO $ do
      x <- m c
      putMVar result x
    return (RCUThread tid result)
  joining (RCUThread _ m) = RCU $ \ _ -> readMVar m
  reading (R m) = RCU $ \ _ -> m
  writing (W m) = RCU $ \ c -> atomically $ do
    _ <- readTVar c -- deliberately incur a data dependency!
    m c

instance MonadIO (RCU s) where
  liftIO m = RCU $ \ _ -> m

runRCU :: (forall s. RCU s a) -> IO a
runRCU m = do
  c <- newTVarIO 0
  unRCU m c