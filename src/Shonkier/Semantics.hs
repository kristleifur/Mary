module Shonkier.Semantics where

import Control.Monad
import Data.Map (Map, singleton, (!?))

import Data.Bwd
import Shonkier.Syntax

data Value' a
  = VAtom a
  | VLit Literal
  | VPrim Primitive [[a]]
  | VCell (Value' a) (Value' a)
  | VFun [Frame' a] (Env' a) [[a]] [Clause' a]
  -- ^ Env is the one the function was created in
  --   Frames ??
  | VThunk (Computation' a)
  deriving (Show)

type Value = Value' String

-- environments

type Env' a = Map String (Value' a)
type Env = Env' String

merge :: Env' a -> Env' a -> Env' a
merge = flip (<>)

lmatch :: Literal -> Literal -> Maybe ()
lmatch (String _ str) (String _ str') = guard (str == str')

vmatch :: Eq a => PValue' a -> Value' a -> Maybe (Env' a)
vmatch (PAtom a)   (VAtom b)   = mempty <$ guard (a == b)
vmatch (PLit l)    (VLit l')   = mempty <$ lmatch l l'
vmatch (PBind x)   v           = pure (singleton x v)
vmatch (PCell p q) (VCell v w) = merge <$> vmatch p v <*> vmatch q w
vmatch _ _ = Nothing

cmatch :: Eq a => PComputation' a -> Computation' a -> Maybe (Env' a)
cmatch (PValue p)           (Value v)             = vmatch p v
cmatch (PRequest (a, ps) k) (Request (b, vs) frs) = do
  guard (a == b)
  rho <- matches vmatch ps vs
  return $ merge rho $ singleton k $
    VFun frs mempty [] [( [PValue (PBind "_return")]
                        , Var "_return"
                        )]
cmatch (PThunk k) c = pure $ singleton k $ VThunk c
cmatch _ _ = Nothing

mayZipWith :: (a -> b -> Maybe c) -> [a] -> [b] -> Maybe [c]
mayZipWith f []       []       = pure []
mayZipWith f (a : as) (b : bs) =
  (:) <$> f a b <*> mayZipWith f as bs
mayZipWith _ _ _ = Nothing

matches :: (a -> b -> Maybe (Env' c)) -> [a] -> [b] -> Maybe (Env' c)
matches match as bs = foldl merge mempty <$> mayZipWith match as bs

-- Evaluation contexts

data Funy' a
  = FAtom a
  | FPrim Primitive
  | FFun [Frame' a] (Env' a) [Clause' a]
  deriving (Show)
type Funy = Funy' String

-- The argument of type (Env' a) indicates the
-- cursor position
data Frame' a
  = CellL (Env' a) (Term' a)
  | CellR (Value' a) (Env' a)
  | AppL (Env' a) [Term' a]
  | AppR (Funy' a)
         (Bwd (Computation' a))
         -- ^ already evaluated arguments (some requests we are
         --   willing to handle may still need to be dealt with)
         ([a], Env' a)
         -- ^ focus: [a] = requests we are willing to handle
         [([a],Term' a)]
         -- ^ each arg comes with requests we are willing to handle
  deriving (Show)

type Frame = Frame' String

type Context' a = Bwd (Frame' a)
type Context = Context' String

-- Evaluation functions

type Request' a = (a, [Value' a])
type Request = Request' String

data Computation' a
  = Value (Value' a)
  | Request (Request' a) [Frame' a]
  -- ^ Invoking an effect & none of the
  -- frames present know how to interpret it
  deriving (Show)

type Computation = Computation' String

eval :: Context -> (Env, Term) -> Computation
eval ctx (rho, t) = case t of
  Var x     -> case rho !? x of
    Just v  -> use ctx v
    Nothing -> handle ctx ("OutOfScope", []) []
  -- move left; start evaluating left to right
  Atom a    -> use ctx (VAtom a)
  Lit l     -> use ctx (VLit l)
  Cell a b  -> eval (ctx :< CellL rho b) (rho, a)
  App f as  -> eval (ctx :< AppL rho as) (rho, f)
  Fun es cs -> use ctx (VFun [] rho es cs)


use :: Context -> Value -> Computation
use Nil         v = Value v
use (ctx :< fr) v = case fr of
  -- move right or upwards
  CellL rho b -> eval (ctx :< CellR v rho) (rho, b)
  CellR u rho -> use ctx (VCell u v)
  -- we better be making a request or using a function
  AppL rho as -> case v of
    VAtom f            ->
      -- Here we are enforcing the invariant:
      -- Atomic functions i.e. requests only ever offer
      -- to handle the empty list of requests.
      let cs = map ([],) as
      in app ctx (FAtom f) Nil rho cs
    VPrim f hs          ->
      let cs = zip (hs ++ repeat []) as
      in app ctx (FPrim f) Nil rho cs
    VFun frs sig hs cls ->
      let cs = zip (hs ++ repeat []) as
      in app ctx (FFun frs sig cls) Nil rho cs
    VThunk c -> case as of
      [] -> case c of
        Value v       -> use ctx v
        Request r frs -> handle ctx r frs
      _  -> handle ctx ("ThunksAreNullary", [v]) []
    _ -> handle ctx ("NoFun",[v]) []
  AppR f vz (_, rho) as -> app ctx f (vz :< Value v) rho as

app :: Context -> Funy
    -> Bwd Computation -> Env -> [([String],Term)]
    -> Computation
app ctx f cz rho as = case as of
  []             -> case f of
    FAtom a         ->
      -- Here we are relying on the invariant:
      -- Atomic functions i.e. requests only ever offer
      -- to handle the empty list of requests.
      let vs = map unsafeComToValue (cz <>> []) in
      handle ctx (a, vs) []
    FPrim p         -> prim ctx p (cz <>> [])
    FFun frs sig cs -> call (ctx <>< frs) sig cs (cz <>> [])
  ((hs, a) : as) -> eval (ctx :< AppR f cz (hs, rho) as) (rho, a)

unsafeComToValue :: Computation -> Value
unsafeComToValue = \case
  Value v     -> v
  r@Request{} -> error $ unlines
    [ "ARGH! Feeding a request to a request"
    , show r
    ]

handle :: Context -> Request -> [Frame]
       -> Computation
handle ctx r@(a, vs) frs = case ctx of
  Nil         -> Request r frs
  (ctx :< fr) -> case fr of
    AppR f cz (hs, rho) as | a `elem` hs ->
      app ctx f (cz :< Request r frs) rho as
    _ -> handle ctx r (fr : frs)

call :: Context -> Env -> [Clause] -> [Computation]
     -> Computation
call ctx rho []                cs =
  handle ctx ("IncompletePattern", []) []
call ctx rho ((ps, rhs) : cls) cs = case matches cmatch ps cs of
  Nothing  -> call ctx rho cls cs
  Just sig -> eval ctx (merge rho sig, rhs)

prim :: Context -> Primitive -> [Computation] -> Computation
prim ctx "primStringAppend"
         [Value (VLit l@String{}), Value (VLit l'@String{})]
         = use ctx (VLit $ primStringAppend l l')
prim ctx f _ = handle ctx ("NoPrim",[VPrim f []]) []

primStringAppend :: Literal -> Literal -> Literal
primStringAppend (String k str) (String k' str') = String k (str ++ str')
