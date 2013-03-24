{-# LANGUAGE CPP
           , UnicodeSyntax
           , NoImplicitPrelude
           , RankNTypes
           , TypeFamilies
           , FunctionalDependencies
           , FlexibleInstances
           , UndecidableInstances
           , MultiParamTypeClasses
           , TypeOperators
  #-}

#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif

{- |
Module      :  Control.Monad.Trans.Control
Copyright   :  Bas van Dijk, Anders Kaseorg
License     :  BSD-style

Maintainer  :  Bas van Dijk <v.dijk.bas@gmail.com>
Stability   :  experimental
-}

module Control.Monad.Trans.Control
    ( -- $example

      -- * MonadTransControl
      MonadTransControl(..), Run

      -- ** Defaults for MonadTransControl
    , DefaultStT, defaultLiftWith,     defaultRestoreT

      -- * MonadBaseControl
    , MonadBaseControl (..), RunInBase

      -- ** Defaults for MonadBaseControl
    , DefaultStM, defaultLiftBaseWith, defaultRestoreM

      -- * Utility functions
    , control

    , liftBaseOp, liftBaseOp_

    , liftBaseDiscard
    ) where


--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from base:
import Data.Function ( ($), const )
import Data.Monoid   ( Monoid, mempty )
import Control.Monad ( Monad, (>>=), return, liftM )
import System.IO     ( IO )
import Data.Maybe    ( Maybe )
import Data.Either   ( Either )

#if MIN_VERSION_base(4,3,0)
import GHC.Conc.Sync ( STM )
#endif

#if MIN_VERSION_base(4,4,0) || defined(INSTANCE_ST)
import           Control.Monad.ST.Lazy             ( ST )
import qualified Control.Monad.ST.Strict as Strict ( ST )
#endif

-- from base-unicode-symbols:
import Data.Function.Unicode ( (∘) )

-- from transformers:
import Control.Monad.Trans.Class    ( MonadTrans )

import Control.Monad.Trans.Identity ( IdentityT(IdentityT), runIdentityT )
import Control.Monad.Trans.List     ( ListT    (ListT),     runListT )
import Control.Monad.Trans.Maybe    ( MaybeT   (MaybeT),    runMaybeT )
import Control.Monad.Trans.Error    ( ErrorT   (ErrorT),    runErrorT, Error )
import Control.Monad.Trans.Reader   ( ReaderT  (ReaderT),   runReaderT )
import Control.Monad.Trans.State    ( StateT   (StateT),    runStateT )
import Control.Monad.Trans.Writer   ( WriterT  (WriterT),   runWriterT )
import Control.Monad.Trans.RWS      ( RWST     (RWST),      runRWST )

import qualified Control.Monad.Trans.RWS.Strict    as Strict ( RWST   (RWST),    runRWST )
import qualified Control.Monad.Trans.State.Strict  as Strict ( StateT (StateT),  runStateT )
import qualified Control.Monad.Trans.Writer.Strict as Strict ( WriterT(WriterT), runWriterT )

import Data.Functor.Identity ( Identity(Identity), runIdentity )
import Data.Functor.Compose  ( Compose(Compose), getCompose )

-- from transformers-base:
import Control.Monad.Base ( MonadBase )

import Data.Tuple ( swap )

#if MIN_VERSION_base(4,3,0)
import Control.Monad ( void )
#else
import Data.Functor (Functor, fmap)
void ∷ Functor f ⇒ f a → f ()
void = fmap (const ())
#endif

--------------------------------------------------------------------------------
-- Example
--------------------------------------------------------------------------------

-- $example
--
-- The following example shows how to make a custom monad transformer
-- (which wraps another monad transformer) an instance of both
-- 'MonadTransControl' and 'MonadBaseControl':
--
-- @
-- {-\# LANGUAGE GeneralizedNewtypeDeriving,
--              TypeFamilies,
--              FlexibleInstances,
--              MultiParamTypeClasses,
--              UndecidableInstances -- Needed for the MonadBase instance
--   \#-}
--
-- import Control.Applicative
--import Control.Monad.Base
--import Control.Monad.Trans.Class
--import Control.Monad.Trans.Control
--import Control.Monad.Trans.State
--
-- newtype CounterT m a = CounterT {unCounterT :: StateT Int m a}
--    deriving (Functor, Applicative, Monad, MonadTrans)
--
-- instance MonadBase b m => MonadBase b (CounterT m) where
--    liftBase = liftBaseDefault
--
-- instance 'MonadTransControl' CounterT where
--    type StT CounterT = 'DefaultStT' (StateT Int)
--    liftWith = 'defaultLiftWith' CounterT unCounterT
--    restoreT = 'defaultRestoreT' CounterT
--
-- instance 'MonadBaseControl' b m => 'MonadBaseControl' b (CounterT m) where
--    type StM (CounterT m) = 'DefaultStM' CounterT m
--    liftBaseWith = 'defaultLiftBaseWith'
--    restoreM     = 'defaultRestoreM'
-- @


--------------------------------------------------------------------------------
-- MonadTransControl type class
--------------------------------------------------------------------------------

class MonadTrans t ⇒ MonadTransControl t where
  -- | Monadic state of @t@.
  type StT t ∷ * → *

  -- | @liftWith@ is similar to 'lift' in that it lifts a computation from
  -- the argument monad to the constructed monad.
  --
  -- Instances should satisfy similar laws as the 'MonadTrans' laws:
  --
  -- @liftWith . const . return = return@
  --
  -- @liftWith (const (m >>= f)) = liftWith (const m) >>= liftWith . const . f@
  --
  -- The difference with 'lift' is that before lifting the @m@ computation
  -- @liftWith@ captures the state of @t@. It then provides the @m@
  -- computation with a 'Run' function that allows running @t n@ computations in
  -- @n@ (for all @n@) on the captured state.
  liftWith ∷ Monad m ⇒ (Run t → m a) → t m a

  -- | Construct a @t@ computation from the monadic state of @t@ that is
  -- returned from a 'Run' function.
  --
  -- Instances should satisfy:
  --
  -- @liftWith (\\run -> run t) >>= restoreT . return = t@
  restoreT ∷ Monad m ⇒ m (StT t a) → t m a

-- | A function that runs a transformed monad @t n@ on the monadic state that
-- was captured by 'liftWith'
--
-- A @Run t@ function yields a computation in @n@ that returns the monadic state
-- of @t@. This state can later be used to restore a @t@ computation using
-- 'restoreT'.
type Run t = ∀ n b. Monad n ⇒ t n b → n (StT t b)


--------------------------------------------------------------------------------
-- Defaults for MonadTransControl
--------------------------------------------------------------------------------

-- | Default definition for the 'StT' associated type synonym that can
-- be used in the 'MonadTransControl' instance for newtypes wrapping
-- other monad transformers. (See the example at the top of this module).
type DefaultStT n = StT n

-- | Default definition for the 'liftWith' method that can be used in
-- the 'MonadTransControl' instance for newtypes wrapping other monad
-- transformers. (See the example at the top of this module).
--
-- Note that:
-- @defaultLiftWith t unT = \\f -> t $ 'liftWith' $ \\run -> f $ liftM IdentityT . run . unT@
defaultLiftWith ∷ (Monad m, MonadTransControl n)
                ⇒ (∀ b.   n m b → t m b)     -- ^ Monad constructor
                → (∀ o b. t o b → n o b)     -- ^ Monad deconstructor
                → ((∀ k b. Monad k ⇒ t k b → k (DefaultStT n b)) → m a) → t m a
defaultLiftWith t unT = \f → t $ liftWith $ \run → f $ run ∘ unT
{-# INLINE defaultLiftWith #-}

-- | Default definition for the 'restoreT' method that can be used in
-- the 'MonadTransControl' instance for newtypes wrapping other monad
-- transformers. (See the example at the top of this module).
--
-- Note that: @defaultRestoreT t = t . 'restoreT' . liftM runIdentityT@
defaultRestoreT ∷ (Monad m, MonadTransControl n)
                ⇒ (n m a → t m a)     -- ^ Monad constructor
                → m (DefaultStT n a) → t m a
defaultRestoreT t = t ∘ restoreT
{-# INLINE defaultRestoreT #-}


--------------------------------------------------------------------------------
-- MonadTransControl instances
--------------------------------------------------------------------------------

instance MonadTransControl IdentityT where
    type StT IdentityT = Identity
    liftWith f = IdentityT $ f $ liftM Identity ∘ runIdentityT
    restoreT = IdentityT ∘ liftM runIdentity
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}


instance MonadTransControl MaybeT where
    type StT MaybeT = Maybe
    liftWith f = MaybeT $ liftM return $ f runMaybeT
    restoreT = MaybeT
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance Error e ⇒ MonadTransControl (ErrorT e) where
    type StT (ErrorT e) = Either e
    liftWith f = ErrorT $ liftM return $ f runErrorT
    restoreT = ErrorT
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadTransControl ListT where
    type StT ListT = []
    liftWith f = ListT $ liftM return $ f runListT
    restoreT = ListT
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadTransControl (ReaderT r) where
    type StT (ReaderT r) = Identity
    liftWith f = ReaderT $ \r → f $ \t → liftM Identity $ runReaderT t r
    restoreT = ReaderT ∘ const ∘ liftM runIdentity
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadTransControl (StateT s) where
    type StT (StateT s) = (,) s
    liftWith f = StateT $ \s →
                   liftM (\x → (x, s))
                         (f $ \t → liftM swap $ runStateT t s)
    restoreT = StateT ∘ const ∘ liftM swap
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadTransControl (Strict.StateT s) where
    type StT (Strict.StateT s) = (,) s
    liftWith f = Strict.StateT $ \s →
                   liftM (\x → (x, s))
                         (f $ \t → liftM swap $ Strict.runStateT t s)
    restoreT = Strict.StateT ∘ const ∘ liftM swap
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance Monoid w ⇒ MonadTransControl (WriterT w) where
    type StT (WriterT w) = (,) w
    liftWith f = WriterT $ liftM (\x → (x, mempty))
                                 (f $ liftM swap ∘ runWriterT)
    restoreT = WriterT ∘ liftM swap
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance Monoid w ⇒ MonadTransControl (Strict.WriterT w) where
    type StT (Strict.WriterT w) = (,) w
    liftWith f = Strict.WriterT $ liftM (\x → (x, mempty))
                                        (f $ liftM swap ∘ Strict.runWriterT)
    restoreT = Strict.WriterT ∘ liftM swap
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

stRWS :: (a, s, w) -> (w, s, a)
stRWS (a, s, w) = (w, s, a)

unStRWS :: (w, s, a) -> (a, s, w)
unStRWS (w, s, a) = (a, s, w)

instance Monoid w ⇒ MonadTransControl (RWST r w s) where
    type StT (RWST r w s) = (,,) w s
    liftWith f = RWST $ \r s → liftM (\x → (x, s, mempty))
                                     (f $ \t → liftM stRWS $ runRWST t r s)
    restoreT mSt = RWST $ \_ _ → liftM unStRWS mSt
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance Monoid w ⇒ MonadTransControl (Strict.RWST r w s) where
    type StT (Strict.RWST r w s) = (,,) w s
    liftWith f =
        Strict.RWST $ \r s → liftM (\x → (x, s, mempty))
                                   (f $ \t → liftM stRWS $ Strict.runRWST t r s)
    restoreT mSt = Strict.RWST $ \_ _ → liftM unStRWS mSt
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}


--------------------------------------------------------------------------------
-- MonadBaseControl type class
--------------------------------------------------------------------------------

class MonadBase b m ⇒ MonadBaseControl b m | m → b where
    -- | Monadic state of @m@.
    type StM m ∷ * → *

    -- | @liftBaseWith@ is similar to 'liftIO' and 'liftBase' in that it
    -- lifts a base computation to the constructed monad.
    --
    -- Instances should satisfy similar laws as the 'MonadIO' and 'MonadBase' laws:
    --
    -- @liftBaseWith . const . return = return@
    --
    -- @liftBaseWith (const (m >>= f)) = liftBaseWith (const m) >>= liftBaseWith . const . f@
    --
    -- The difference with 'liftBase' is that before lifting the base computation
    -- @liftBaseWith@ captures the state of @m@. It then provides the base
    -- computation with a 'RunInBase' function that allows running @m@
    -- computations in the base monad on the captured state.
    liftBaseWith ∷ (RunInBase m b → b a) → m a

    -- | Construct a @m@ computation from the monadic state of @m@ that is
    -- returned from a 'RunInBase' function.
    --
    -- Instances should satisfy:
    --
    -- @liftBaseWith (\\runInBase -> runInBase m) >>= restoreM = m@
    restoreM ∷ StM m a → m a

-- | A function that runs a @m@ computation on the monadic state that was
-- captured by 'liftBaseWith'
--
-- A @RunInBase m@ function yields a computation in the base monad of @m@ that
-- returns the monadic state of @m@. This state can later be used to restore the
-- @m@ computation using 'restoreM'.
type RunInBase m b = ∀ a. m a → b (StM m a)


--------------------------------------------------------------------------------
-- MonadBaseControl instances for all monads in the base library
--------------------------------------------------------------------------------

#define BASE(M)                           \
instance MonadBaseControl (M) (M) where { \
    type StM (M) = Identity;              \
    liftBaseWith f = f $ liftM Identity;  \
    restoreM = return ∘ runIdentity;      \
    {-# INLINE liftBaseWith #-};          \
    {-# INLINE restoreM #-}}

BASE(IO)
BASE(Maybe)
BASE(Either e)
BASE([])
BASE((→) r)
BASE(Identity)

#if MIN_VERSION_base(4,3,0)
BASE(STM)
#endif

#if MIN_VERSION_base(4,4,0) || defined(INSTANCE_ST)
BASE(Strict.ST s)
BASE(       ST s)
#endif

#undef BASE


--------------------------------------------------------------------------------
-- Defaults for MonadBaseControl
--------------------------------------------------------------------------------

-- | Default definition for the 'StM' associated type synonym.
--
-- It can be used to define the 'StM' for new 'MonadBaseControl' instances.
type DefaultStM t m = StM m `Compose` StT t

-- | Default defintion for the 'liftBaseWith' method.
--
-- Note that it composes a 'liftWith' of @t@ with a 'liftBaseWith' of @m@ to
-- give a 'liftBaseWith' of @t m@:
--
-- @
-- defaultLiftBaseWith = \\f -> 'liftWith' $ \\run ->
--                               'liftBaseWith' $ \\runInBase ->
--                                 f $ liftM 'Compose' . runInBase . run
-- @
defaultLiftBaseWith ∷ ( MonadTransControl t
                      , MonadBaseControl b m
                      , StM (t m) ~ DefaultStM t m
                      )
                    ⇒ ((RunInBase (t m) b  → b α) → t m α)
defaultLiftBaseWith f = liftWith $ \run →
                          liftBaseWith $ \runInBase →
                            f $ liftM Compose ∘ runInBase ∘ run
{-# INLINE defaultLiftBaseWith #-}

-- | Default definition for the 'restoreM' method.
--
-- Note that: @defaultRestoreM unStM = 'restoreT' . 'restoreM' . 'getCompose'@
defaultRestoreM ∷ ( MonadTransControl t
                  , MonadBaseControl b m
                  , StM (t m) ~ DefaultStM t m
                  )
                ⇒ (StM (t m) α → t m α)
defaultRestoreM = restoreT ∘ restoreM ∘ getCompose
{-# INLINE defaultRestoreM #-}


--------------------------------------------------------------------------------
-- MonadBaseControl transformer instances
--------------------------------------------------------------------------------

#define BODY(T) {                         \
    type StM (T m) = DefaultStM (T) m;    \
    liftBaseWith   = defaultLiftBaseWith; \
    restoreM       = defaultRestoreM;     \
    {-# INLINE liftBaseWith #-};          \
    {-# INLINE restoreM #-}}

#define TRANS(         T) \
  instance (     MonadBaseControl b m) ⇒ MonadBaseControl b (T m) where BODY(T)
#define TRANS_CTX(CTX, T) \
  instance (CTX, MonadBaseControl b m) ⇒ MonadBaseControl b (T m) where BODY(T)

TRANS(IdentityT)
TRANS(MaybeT)
TRANS(ListT)
TRANS(ReaderT r)
TRANS(Strict.StateT s)
TRANS(       StateT s)

TRANS_CTX(Error e,         ErrorT e)
TRANS_CTX(Monoid w, Strict.WriterT w)
TRANS_CTX(Monoid w,        WriterT w)
TRANS_CTX(Monoid w, Strict.RWST r w s)
TRANS_CTX(Monoid w,        RWST r w s)


--------------------------------------------------------------------------------
-- * Utility functions
--------------------------------------------------------------------------------

-- | An often used composition: @control f = 'liftBaseWith' f >>= 'restoreM'@
control ∷ MonadBaseControl b m ⇒ (RunInBase m b → b (StM m a)) → m a
control f = liftBaseWith f >>= restoreM
{-# INLINE control #-}

-- | @liftBaseOp@ is a particular application of 'liftBaseWith' that allows
-- lifting control operations of type:
--
-- @((a -> b c) -> b c)@ to: @('MonadBaseControl' b m => (a -> m c) -> m c)@.
--
-- For example:
--
-- @liftBaseOp alloca :: 'MonadBaseControl' 'IO' m => (Ptr a -> m c) -> m c@
liftBaseOp ∷ MonadBaseControl b m
           ⇒ ((a → b (StM m c)) → b (StM m d))
           → ((a →        m c)  →        m d)
liftBaseOp f = \g → control $ \runInBase → f $ runInBase ∘ g
{-# INLINE liftBaseOp #-}

-- | @liftBaseOp_@ is a particular application of 'liftBaseWith' that allows
-- lifting control operations of type:
--
-- @(b a -> b a)@ to: @('MonadBaseControl' b m => m a -> m a)@.
--
-- For example:
--
-- @liftBaseOp_ mask_ :: 'MonadBaseControl' 'IO' m => m a -> m a@
liftBaseOp_ ∷ MonadBaseControl b m
            ⇒ (b (StM m a) → b (StM m c))
            → (       m a  →        m c)
liftBaseOp_ f = \m → control $ \runInBase → f $ runInBase m
{-# INLINE liftBaseOp_ #-}

-- | @liftBaseDiscard@ is a particular application of 'liftBaseWith' that allows
-- lifting control operations of type:
--
-- @(b () -> b a)@ to: @('MonadBaseControl' b m => m () -> m a)@.
--
-- Note that, while the argument computation @m ()@ has access to the captured
-- state, all its side-effects in @m@ are discarded. It is run only for its
-- side-effects in the base monad @b@.
--
-- For example:
--
-- @liftBaseDiscard forkIO :: 'MonadBaseControl' 'IO' m => m () -> m ThreadId@
liftBaseDiscard ∷ MonadBaseControl b m ⇒ (b () → b a) → (m () → m a)
liftBaseDiscard f = \m → liftBaseWith $ \runInBase → f $ void $ runInBase m
{-# INLINE liftBaseDiscard #-}
