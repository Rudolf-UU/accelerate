{-# LANGUAGE CPP                  #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE InstanceSigs         #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PatternGuards        #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE ViewPatterns         #-}

-- |
-- Module      : Data.Array.Accelerate.Trafo.NewNewFusion
-- Copyright   : [2012..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- This module should implement fusion.
--

module Data.Array.Accelerate.Trafo.NewNewFusion (

  convertAcc,  convertAccWith,
  convertAfun, convertAfunWith,
  
  Benchmarking(..), convertAccBench, convertAccBenchF

) where

import Data.Array.Accelerate.AST.Operation
import Data.Array.Accelerate.AST.Partitioned
import Data.Array.Accelerate.Trafo.Config
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Trafo.Partitioning.ILP (gurobiFusion, gurobiFusionF, greedy, greedyF, no, noF)
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Graph (MakesILP)
import qualified Data.Array.Accelerate.Pretty.Operation as Pretty
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Solve (Objective (..))


#ifdef ACCELERATE_DEBUG
import System.IO.Unsafe -- for debugging
#endif

data Benchmarking = GreedyFusion | NoFusion
  deriving (Show, Eq)

convertAccBench :: (MakesILP op, Pretty.PrettyOp (Cluster op)) => Benchmarking -> OperationAcc op () a -> PartitionedAcc op () a
convertAccBench GreedyFusion = withSimplStats (greedy FusedEdges)
convertAccBench NoFusion = withSimplStats (no FusedEdges)
convertAccBenchF :: (MakesILP op, Pretty.PrettyOp (Cluster op)) => Benchmarking -> OperationAfun op () a -> PartitionedAfun op () a
convertAccBenchF GreedyFusion = withSimplStats (greedyF FusedEdges)
convertAccBenchF NoFusion = withSimplStats (noF FusedEdges)


-- Array Fusion
-- ============

-- | Apply the fusion transformation to a de Bruijn AST
--
convertAccWith
    :: (HasCallStack, MakesILP op, Pretty.PrettyOp (Cluster op))
    => Config
    -> Objective
    -> OperationAcc op () a
    -> PartitionedAcc op () a
convertAccWith _ = withSimplStats gurobiFusion

convertAcc :: (HasCallStack, MakesILP op, Pretty.PrettyOp (Cluster op)) => Objective -> OperationAcc op () a -> PartitionedAcc op () a
convertAcc = convertAccWith defaultOptions

-- | Apply the fusion transformation to a function of array arguments
--
convertAfun :: (HasCallStack, MakesILP op, Pretty.PrettyOp (Cluster op)) => Objective -> OperationAfun op () f -> PartitionedAfun op () f
convertAfun = convertAfunWith defaultOptions

convertAfunWith :: (HasCallStack, MakesILP op, Pretty.PrettyOp (Cluster op)) => Config -> Objective -> OperationAfun op () f -> PartitionedAfun op () f
convertAfunWith _ = withSimplStats gurobiFusionF


withSimplStats :: a -> a
-- #ifdef ACCELERATE_DEBUG
-- withSimplStats x = unsafePerformIO Stats.resetSimplCount `seq` x
-- #else
withSimplStats x = x
-- #endif

-- dontFuse :: op args -> Args env args -> Cluster' op args
-- dontFuse = unfused