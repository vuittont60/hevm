{-# LANGUAGE DataKinds #-}

{- |
    Module: EVM.Keccak
    Description: Expr passes to determine Keccak assumptions
-}
module EVM.Keccak (keccakAssumptions, keccakCompute) where

import Control.Monad.State
import Data.Set (Set)
import Data.Set qualified as Set

import EVM.Traversals
import EVM.Types
import EVM.Expr

newtype BuilderState = BuilderState
  { keccaks :: Set (Expr EWord) }
  deriving (Show)

initState :: BuilderState
initState = BuilderState { keccaks = Set.empty }

go :: forall a. Expr a -> State BuilderState (Expr a)
go = \case
  e@(Keccak _) -> do
    s <- get
    put $ s{keccaks=Set.insert e s.keccaks}
    pure e
  e -> pure e

findKeccakExpr :: forall a. Expr a -> State BuilderState (Expr a)
findKeccakExpr e = mapExprM go e

findKeccakProp :: Prop -> State BuilderState Prop
findKeccakProp p = mapPropM go p

findKeccakPropsExprs :: [Prop] -> [Expr Buf]  -> [Expr Storage]-> State BuilderState ()
findKeccakPropsExprs ps bufs stores = do
  mapM_ findKeccakProp ps;
  mapM_ findKeccakExpr bufs;
  mapM_ findKeccakExpr stores


combine :: [a] -> [(a,a)]
combine lst = combine' lst []
  where
    combine' [] acc = concat acc
    combine' (x:xs) acc =
      let xcomb = [ (x, y) | y <- xs] in
      combine' xs (xcomb:acc)

minProp :: Expr EWord -> Prop
minProp k@(Keccak _) = PGT k (Lit 256)
minProp _ = internalError "expected keccak expression"

injProp :: (Expr EWord, Expr EWord) -> Prop
injProp (k1@(Keccak b1), k2@(Keccak b2)) =
  POr ((b1 .== b2) .&& (bufLength b1 .== bufLength b2)) (PNeg (PEq k1 k2))
injProp _ = internalError "expected keccak expression"

-- Takes a list of props, find all keccak occurences and generates two kinds of assumptions:
--   1. Minimum output value: That the output of the invocation is greater than
--      50 (needed to avoid spurious counterexamples due to storage collisions
--      with solidity mappings & value type storage slots)
--   2. Injectivity: That keccak is an injective function (we avoid quantifiers
--      here by making this claim for each unique pair of keccak invocations
--      discovered in the input expressions)
keccakAssumptions :: [Prop] -> [Expr Buf] -> [Expr Storage] -> [Prop]
keccakAssumptions ps bufs stores = injectivity <> minValue
  where
    (_, st) = runState (findKeccakPropsExprs ps bufs stores) initState

    injectivity = fmap injProp $ combine (Set.toList st.keccaks)
    minValue = fmap minProp (Set.toList st.keccaks)

compute :: forall a. Expr a -> [Prop]
compute = \case
  e@(Keccak buf) -> do
    let b = simplify buf
    case keccak b of
      lit@(Lit _) -> [PEq e lit]
      _ -> []
  _ -> []

computeKeccakExpr :: forall a. Expr a -> [Prop]
computeKeccakExpr e = foldExpr compute [] e

computeKeccakProp :: Prop -> [Prop]
computeKeccakProp p = foldProp compute [] p

keccakCompute :: [Prop] -> [Expr Buf] -> [Expr Storage] -> [Prop]
keccakCompute ps buf stores =
  concatMap computeKeccakProp ps <>
  concatMap computeKeccakExpr buf <>
  concatMap computeKeccakExpr stores
