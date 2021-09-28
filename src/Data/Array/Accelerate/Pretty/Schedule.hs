{-# LANGUAGE GADTs      #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Data.Array.Accelerate.Pretty.Schedule
-- Copyright   : [2008..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.Pretty.Schedule (
  PrettySchedule(..), PrettyKernel(..), PrettyKernelStyle(..)
) where

import Data.Array.Accelerate.AST.Kernel
import Data.Array.Accelerate.Pretty.Exp

class PrettySchedule sched where
  prettySchedule :: PrettyKernel kernel => sched kernel () t -> Adoc

class PrettyKernel kernel where
  prettyKernel :: PrettyKernelStyle kernel

data PrettyKernelStyle kernel where
  PrettyKernelBody :: (forall env. Val env -> kernel env -> Adoc) -> PrettyKernelStyle kernel

  PrettyKernelFun :: (forall t. KernelFun kernel t -> Adoc) -> PrettyKernelStyle kernel