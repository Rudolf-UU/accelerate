{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE BlockArguments         #-}
{-# LANGUAGE EmptyCase              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE InstanceSigs           #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE PatternGuards          #-}
{-# LANGUAGE PatternSynonyms        #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE ViewPatterns           #-}

{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# LANGUAGE QuantifiedConstraints #-}

module Data.Array.Accelerate.Eval where

import Prelude                                                      hiding (take, (!!), sum)
import Data.Array.Accelerate.AST.Partitioned
import Data.Array.Accelerate.AST.Operation
import Data.Array.Accelerate.Trafo.Desugar
import Data.Array.Accelerate.Representation.Array
import Data.Array.Accelerate.Representation.Type
import Data.Array.Accelerate.AST.Environment
import Data.Array.Accelerate.Trafo.Operation.LiveVars
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Graph (MakesILP (BackendClusterArg), BackendCluster)
import Data.Array.Accelerate.Pretty.Partitioned ()


import Data.Array.Accelerate.Trafo.Schedule.Uniform ()
import Data.Array.Accelerate.Pretty.Schedule.Uniform ()
import Data.Kind (Type)
import Data.Bifunctor (bimap)
import Data.Biapplicative (biliftA2)
import Data.Functor.Compose
import Data.Type.Equality
import Data.Array.Accelerate.Type (ScalarType)
import Unsafe.Coerce (unsafeCoerce)
import Data.Array.Accelerate.Representation.Shape (ShapeR (..))
import Data.Composition ((.*))
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Labels (Label)


type BackendArgs op env = PreArgs (BackendClusterArg2 op env)
type BackendEnv op env = Env (BackendEnvElem op env)
data BackendEnvElem op env arg = BEE (ToArg env arg) (BackendClusterArg2 op env arg)
type BackendArgEnv op env = Env (BackendArgEnvElem op env)
data BackendArgEnvElem op env arg = BAE (FromArg env (Embed op arg)) (BackendClusterArg2 op env arg)
type EmbedEnv op env = Env (FromArg' op env)
newtype FromArg' op env a = FromArg (FromArg env (Embed op a))
pattern PushFA :: () => (e' ~ (e, x)) => EmbedEnv op env e -> FromArg env (Embed op x) -> EmbedEnv op env e'
pattern PushFA env x = Push env (FromArg x)
{-# COMPLETE Empty, PushFA #-}

-- TODO make actually static, i.e. by using `Fun env (Int -> Int)` instead in the interpreter
class (MakesILP op, forall env arg. Eq (BackendClusterArg2 op env arg)) => StaticClusterAnalysis (op :: Type -> Type) where
  -- give better name
  data BackendClusterArg2 op env arg
  onOp :: op args -> BackendArgs op env (OutArgsOf args) -> Args env args -> FEnv op env -> BackendArgs op env args
  def :: Arg env arg -> FEnv op env -> BackendClusterArg op arg -> BackendClusterArg2 op env arg
  valueToIn    :: BackendClusterArg2 op env (Value sh e)     -> BackendClusterArg2 op env (In    sh e)
  valueToOut   :: BackendClusterArg2 op env (Value sh e)     -> BackendClusterArg2 op env (Out   sh e)
  inToValue    :: BackendClusterArg2 op env (In    sh e)     -> BackendClusterArg2 op env (Value sh e)
  outToValue   :: BackendClusterArg2 op env (Out   sh e)     -> BackendClusterArg2 op env (Value sh e)
  outToSh      :: BackendClusterArg2 op env (Out   sh e)     -> BackendClusterArg2 op env (Sh    sh e)
  shToOut      :: BackendClusterArg2 op env (Sh    sh e)     -> BackendClusterArg2 op env (Out   sh e)
  shToValue    :: BackendClusterArg2 op env (Sh    sh e)     -> BackendClusterArg2 op env (Value sh e)
  varToValue   :: BackendClusterArg2 op env (Var'  sh)       -> BackendClusterArg2 op env (Value sh e)
  varToSh      :: BackendClusterArg2 op env (Var'  sh)       -> BackendClusterArg2 op env (Sh    sh e)
  shToVar      :: BackendClusterArg2 op env (Sh    sh e)     -> BackendClusterArg2 op env (Var'  sh  )
  shrinkOrGrow :: BackendClusterArg2 op env (m     sh e')    -> BackendClusterArg2 op env (m     sh e)
  addTup       :: BackendClusterArg2 op env (v     sh e)     -> BackendClusterArg2 op env (v     sh ((), e))
  unitToVar    :: BackendClusterArg2 op env (m     sh ())    -> BackendClusterArg2 op env (Var'  sh  )  
  varToUnit    :: BackendClusterArg2 op env (Var' sh)        -> BackendClusterArg2 op env (m     sh ()) 
  inToVar      :: BackendClusterArg2 op env (In sh e)        -> BackendClusterArg2 op env (Var' sh   )
  pairinfo     :: BackendClusterArg2 op env (m sh a)         -> BackendClusterArg2 op env (m sh b) -> BackendClusterArg2 op env (m sh (a,b))
  pairinfo a b = if shrinkOrGrow a == b then shrinkOrGrow a else error "pairing unequal"
  unpairinfo   :: BackendClusterArg2 op env (m sh (a,b))     -> (BackendClusterArg2 op env (m sh a),  BackendClusterArg2 op env (m sh b))
  unpairinfo x = (shrinkOrGrow x, shrinkOrGrow x)



makeBackendArg :: forall op env args. StaticClusterAnalysis op => Args env args -> FEnv op env -> Cluster op args -> BackendCluster op args -> BackendArgs op env args
makeBackendArg args env c b = go args c (defaultOuts args b)
  where
    go :: forall args. Args env args -> Cluster op args -> BackendArgs op env (OutArgsOf args) -> BackendArgs op env args
    go args (Fused f l r) outputs = let
      backR = go (right f args) r (rightB args f outputs)
      backL = go (left  f args) l (backleft f backR outputs)
      in fuseBack f backL backR
    go args (Op (SLVOp (SOp (SOAOp op soa) (SA sort unsort)) sa)) outputs = 
      slv sa . sort . soaExpand uncombineB soa $ onOp @op op (forgetIn (soaShrink combine soa $ unsort $ slv' sa args) $ soaShrink combineB soa $ unsort $ slv' sa $ inventIn args outputs) (soaShrink combine soa $ unsort $ slv' sa args) env

    combineB   :: BackendClusterArg2 op env (f l) -> BackendClusterArg2 op env (f r) -> BackendClusterArg2 op env (f (l,r))
    combineB   = unsafeCoerce $ pairinfo   @op
    uncombineB :: BackendClusterArg2 op env (f (l,r)) -> (BackendClusterArg2 op env (f l), BackendClusterArg2 op env (f r))
    uncombineB = unsafeCoerce $ unpairinfo @op

    defaultOuts :: Args env args -> BackendCluster op args -> BackendArgs op env (OutArgsOf args)
    defaultOuts args backendcluster = forgetIn args $ fuseArgsWith args backendcluster (\arg b -> def arg env b)

    fuseBack :: forall largs rargs args
              . Fusion largs rargs args 
             -> BackendArgs op env largs 
             -> BackendArgs op env rargs 
             -> BackendArgs op env args
    fuseBack EmptyF ArgsNil ArgsNil = ArgsNil
    fuseBack (Vertical ar f) (l :>: ls) (r :>: rs) = inToVar r :>: fuseBack f ls rs
    fuseBack (Horizontal  f) (l :>: ls) (r :>: rs) = l :>: fuseBack f ls rs
    fuseBack (Diagonal    f) (l :>: ls) (r :>: rs) = l :>: fuseBack f ls rs
    fuseBack (IntroI1     f) (l :>: ls)        rs  = l :>: fuseBack f ls rs
    fuseBack (IntroI2     f)        ls  (r :>: rs) = r :>: fuseBack f ls rs
    fuseBack (IntroO1     f) (l :>: ls)        rs  = l :>: fuseBack f ls rs
    fuseBack (IntroO2     f)        ls  (r :>: rs) = r :>: fuseBack f ls rs
    fuseBack (IntroL      f) (l :>: ls)        rs  = l :>: fuseBack f ls rs
    fuseBack (IntroR      f)        ls  (r :>: rs) = r :>: fuseBack f ls rs

    rightB :: forall largs rargs args
            . StaticClusterAnalysis op 
           => Args env args 
           -> Fusion largs rargs args
           -> BackendArgs op env (OutArgsOf  args)
           -> BackendArgs op env (OutArgsOf rargs)
    rightB args f = forgetIn (right f args) . right' (valueToIn . varToValue) (valueToIn . outToValue) f . inventIn args

    backleft :: forall largs rargs args
              . StaticClusterAnalysis op
             => Fusion largs rargs args
             -> BackendArgs op env rargs
             -> BackendArgs op env (OutArgsOf args)
             -> BackendArgs op env (OutArgsOf largs)
    backleft EmptyF ArgsNil ArgsNil = ArgsNil
    backleft (Vertical ar f) (r:>:rs)      as  = (valueToOut . inToValue) r :>: backleft f rs as
    backleft (Horizontal  f) (_:>:rs)      as  =                                backleft f rs as
    backleft (Diagonal    f) (r:>:rs) (a:>:as) = (valueToOut . inToValue) r :>: backleft f rs as -- just using 'a' is also type correct, and maybe also fine? Not sure anymore
    backleft (IntroI1     f)      rs       as  =                                backleft f rs as
    backleft (IntroI2     f) (_:>:rs)      as  =                                backleft f rs as
    backleft (IntroO1     f)      rs  (a:>:as) = a                          :>: backleft f rs as
    backleft (IntroO2     f) (_:>:rs) (_:>:as) =                                backleft f rs as
    backleft (IntroL      f)      rs       as = unsafeCoerce $ backleft f rs (unsafeCoerce as)
    backleft (IntroR      f) (_:>:rs)      as =                                backleft f rs (unsafeCoerce as)

inventIn :: Args env args -> PreArgs f (OutArgsOf args) -> PreArgs f args
inventIn ArgsNil ArgsNil = ArgsNil
inventIn (ArgArray Out _ _ _ :>: args) (arg :>: out) = arg :>: inventIn args out
inventIn (ArgArray In  _ _ _ :>: args) out = error "fake argument" :>: inventIn args out
inventIn (ArgArray Mut _ _ _ :>: args) out = error "fake argument" :>: inventIn args out
inventIn (ArgVar _           :>: args) out = error "fake argument" :>: inventIn args out
inventIn (ArgExp _           :>: args) out = error "fake argument" :>: inventIn args out
inventIn (ArgFun _           :>: args) out = error "fake argument" :>: inventIn args out

forgetIn :: Args env args -> PreArgs f args -> PreArgs f (OutArgsOf args)
forgetIn ArgsNil ArgsNil = ArgsNil
forgetIn (ArgArray Out _ _ _ :>: args) (arg :>: out) = arg :>: forgetIn args out
forgetIn (ArgArray In  _ _ _ :>: args) (_   :>: out) = forgetIn args out
forgetIn (ArgArray Mut _ _ _ :>: args) (_   :>: out) = forgetIn args out
forgetIn (ArgVar _           :>: args) (_   :>: out) = forgetIn args out
forgetIn (ArgExp _           :>: args) (_   :>: out) = forgetIn args out
forgetIn (ArgFun _           :>: args) (_   :>: out) = forgetIn args out



sortingOnOut :: (forall f. PreArgs f args -> PreArgs f sorted) -> Args env args -> PreArgs g (OutArgsOf args) -> PreArgs g (OutArgsOf sorted)
sortingOnOut sort args out = justOut (sort args) $ sort $ inventIn args out


class (StaticClusterAnalysis op, Monad (EvalMonad op), TupRmonoid (Embed' op))
    => EvalOp op where
  type family EvalMonad op :: Type -> Type
  type family Index op :: Type 
  type family Embed' op :: Type -> Type
  type family EnvF op :: Type -> Type

  unit :: Embed' op ()

  -- TODO most of these functions should probably be unnecesary, but adding them is the easiest way to get things working right now
  indexsh :: GroundVars env sh -> FEnv op env -> EvalMonad op (Embed' op sh)
  indexsh'   :: ExpVars env sh -> FEnv op env -> EvalMonad op (Embed' op sh)
  subtup :: SubTupR e e' -> Embed' op e -> Embed' op e'


  evalOp :: Index op -> Label -> op args -> FEnv op env -> BackendArgEnv op env (InArgs args) -> EvalMonad op (EmbedEnv op env (OutArgs args))
  writeOutput :: ScalarType e -> GroundVars env sh -> GroundVars env (Buffers e) -> FEnv op env -> Index op -> Embed' op e -> EvalMonad op ()
  readInput :: ScalarType e -> GroundVars env sh -> GroundVars env (Buffers e) -> FEnv op env -> BackendClusterArg2 op env (In sh e) -> Index op -> EvalMonad op (Embed' op e)
type FEnv op = Env (EnvF op)
type family Embed (op :: Type -> Type) a where
  Embed op (Value sh e) = Value' op sh e
  Embed op (Sh sh e) = Sh' op sh e
  Embed op e = e -- Mut, Exp', Var', Fun'

data Value' op sh e = Value' (Embed' op e) (Sh' op sh e)
data Sh' op sh e = Shape' (ShapeR sh) (Embed' op sh)


evalCluster :: forall op env args. (EvalOp op) => Cluster op args -> BackendCluster op args -> Args env args -> FEnv op env -> Index op -> EvalMonad op ()
evalCluster c b args env ix = do
  let ba = makeBackendArg args env c b
  input <- readInputs args ba
  output <- evalOps c input args
  writeOutputs args output
  where
    evalOps :: forall args. Cluster op args -> BackendArgEnv op env (InArgs args) -> Args env args -> EvalMonad op (EmbedEnv op env (OutArgs args))
    evalOps c ba args = case c of
      Op (SLVOp (SOp (SOAOp op soas) (SA f g)) sa) -> slvOut () sa . outargs f (g $ slv' sa args) . soaOut splitFromArg' (soaShrink combine soas $ g $ slv' sa args) soas <$> evalOp ix undefined op env (soaIn pairInArg (g $ slv' sa args) soas $ inargs g $ slvIn () sa ba) 
      Fused f l r -> do
        lin <- leftIn f ba env
        lout <- evalOps l lin (left f args)
        let rin = rightIn f lout ba
        rout <- evalOps r rin (right f args)
        return $ totalOut f lout rout

    splitFromArg' :: FromArg' op env (Value sh (l,r)) -> (FromArg' op env (Value sh l), FromArg' op env (Value sh r))
    splitFromArg' (FromArg v) = bimap FromArg FromArg $ unpair' v

    pairInArg :: Arg env (arg (l,r)) -> BackendArgEnvElem op env (InArg (arg l)) ->  BackendArgEnvElem op env (InArg (arg r)) ->  BackendArgEnvElem op env (InArg (arg (l,r)))
    pairInArg (ArgArray In  _ _ _) l r = getCompose $ pair' (Compose l) (Compose r)
    pairInArg (ArgArray Out _ _ _) l r = getCompose $ pair' (Compose l) (Compose r)
    pairInArg _ _ _ = error "SOA'd non-array args"

    readInputs :: forall args. Args env args -> BackendArgs op env args -> EvalMonad op (BackendArgEnv op env (InArgs args))
    readInputs ArgsNil ArgsNil = pure Empty
    readInputs (arg :>: args) (bca :>: bcas) = case arg of
      ArgVar x -> flip Push (BAE x bca) <$> readInputs args bcas
      ArgExp x -> flip Push (BAE x bca) <$> readInputs args bcas
      ArgFun x -> flip Push (BAE x bca) <$> readInputs args bcas
      ArgArray Mut (ArrayR shr r) sh buf -> flip Push (BAE (ArrayDescriptor shr sh buf, r) bca) <$> readInputs args bcas
      ArgArray Out (ArrayR shr _) sh _   -> (\sh' -> flip Push (BAE (Shape' shr sh') (outToSh bca))) <$> indexsh @op sh env <*> readInputs args bcas
      ArgArray In  (ArrayR shr r) sh buf -> case r of
        TupRsingle t -> (\env v sh' -> Push env (BAE (Value' v (Shape' shr sh')) (inToValue bca))) <$> readInputs args bcas <*> readInput t sh buf env bca ix <*> indexsh @op sh env
        TupRunit -> (\sh' -> flip Push (BAE (Value' (unit @op) (Shape' shr sh')) (inToValue bca))) <$> indexsh @op sh env <*> readInputs args bcas
        TupRpair{} -> error "not SOA'd"

    writeOutputs :: forall args. Args env args -> EmbedEnv op env (OutArgs args) -> EvalMonad op ()
    writeOutputs ArgsNil Empty = pure ()
    writeOutputs (ArgArray Out (ArrayR _ r) sh buf :>: args) (PushFA env' (Value' x _)) 
      | TupRsingle t <- r = writeOutput @op t sh buf env ix x >> writeOutputs args env'
      | otherwise = error "not soa'd"
    writeOutputs (ArgVar _ :>: args) env = writeOutputs args env
    writeOutputs (ArgExp _ :>: args) env = writeOutputs args env
    writeOutputs (ArgFun _ :>: args) env = writeOutputs args env
    writeOutputs (ArgArray In  _ _ _ :>: args) env = writeOutputs args env
    writeOutputs (ArgArray Mut _ _ _ :>: args) env = writeOutputs args env

    leftIn :: forall largs rargs args. Fusion largs rargs args -> BackendArgEnv op env (InArgs args) -> FEnv op env -> EvalMonad op (BackendArgEnv op env (InArgs largs))
    leftIn EmptyF Empty _ = pure Empty
    leftIn (Vertical ar f) (Push env (BAE x b)) env'= Push <$> leftIn f env env' <*> ((`BAE` varToSh b) . Shape' (evarToShR x) <$> indexsh' @op x env')
    leftIn (Horizontal  f) (Push env bae) env' = (`Push` bae) <$> leftIn f env env'
    leftIn (Diagonal    f) (Push env bae) env' = (`Push` bae) <$> leftIn f env env'
    leftIn (IntroI1     f) (Push env bae) env' = (`Push` bae) <$> leftIn f env env'
    leftIn (IntroI2     f) (Push env _  ) env' =                  leftIn f env env'
    leftIn (IntroO1     f) (Push env bae) env' = (`Push` bae) <$> leftIn f env env'
    leftIn (IntroO2     f) (Push env _  ) env' =                  leftIn f env env'
    leftIn (IntroL      f) (Push env bae) env' = (`Push` bae) <$> leftIn f env env'
    leftIn (IntroR      f) (Push env _  ) env' =                  leftIn f env env'

    rightIn :: forall largs rargs args
             . Fusion largs rargs args
            -> EmbedEnv op env (OutArgs largs)
            -> BackendArgEnv op env  ( InArgs  args)
            -> BackendArgEnv op env  ( InArgs rargs)
    rightIn EmptyF Empty Empty = Empty
    rightIn (Vertical ar f) (PushFA lenv fa) (Push env (BAE _ b)) = Push (rightIn f lenv env) (BAE fa $ varToValue b)
    rightIn (Horizontal  f)         lenv     (Push env bae      ) = Push (rightIn f lenv env) bae
    rightIn (Diagonal    f) (PushFA lenv fa) (Push env (BAE _ b)) = Push (rightIn f lenv env) (BAE fa $ shToValue b)
    rightIn (IntroI1     f)         lenv     (Push env _        ) =       rightIn f lenv env
    rightIn (IntroI2     f)         lenv     (Push env bae      ) = Push (rightIn f lenv env) bae
    rightIn (IntroO1     f) (PushFA lenv _ ) (Push env _        ) =       rightIn f lenv env
    rightIn (IntroO2     f)         lenv     (Push env bae      ) = Push (rightIn f lenv env) bae
    rightIn (IntroL      f)         lenv     (Push env _        ) =       rightIn f (unsafeCoerce lenv) env
    rightIn (IntroR      f)         lenv     (Push env bae      ) = Push (rightIn f lenv env) bae

    inargs :: forall op env args args'
            . (forall f. PreArgs f args -> PreArgs f args')
           -> BackendArgEnv op env (InArgs args)
           -> BackendArgEnv op env (InArgs args')
    inargs f 
      | Refl <- inargslemma @args
      = toEnv . f . fromEnv
      where
        fromEnv :: forall args. BackendArgEnv op env args -> PreArgs (BAEEInArg op env) (InArgs' args)
        fromEnv Empty = ArgsNil
        fromEnv (Push env (x :: BackendArgEnvElem op env t)) 
          | Refl <- inarglemma @t = BAEEInArg x :>: fromEnv env
        toEnv :: forall args. PreArgs (BAEEInArg op env) args -> BackendArgEnv op env (InArgs args)
        toEnv ArgsNil = Empty
        toEnv (BAEEInArg x :>: args) = Push (toEnv args) x


    totalOut :: forall largs rargs args
              . Fusion largs rargs args
             -> EmbedEnv op env (OutArgs largs)
             -> EmbedEnv op env (OutArgs rargs)
             -> EmbedEnv op env (OutArgs args)
    totalOut EmptyF Empty Empty = Empty
    totalOut (Vertical ar f) (Push l _)      r    =       totalOut f l r
    totalOut (Horizontal f)       l         r    =       totalOut f l r
    totalOut (Diagonal   f) (Push l o)      r    = Push (totalOut f l r) o
    totalOut (IntroI1    f)       l         r    =       totalOut f l r
    totalOut (IntroI2    f)       l         r    =       totalOut f l r
    totalOut (IntroO1    f) (Push l o)      r    = Push (totalOut f l r) o
    totalOut (IntroO2    f)       l   (Push r o) = Push (totalOut f l r) o
    totalOut (IntroL     f)       l         r    = unsafeCoerce $ totalOut f (unsafeCoerce l) r
    totalOut (IntroR     f)       l         r    = unsafeCoerce $ totalOut f l (unsafeCoerce r)

    outargs :: forall op env args args'
              . (forall f. PreArgs f args -> PreArgs f args')
            -> Args env args
            -> EmbedEnv op env (OutArgs args)
            -> EmbedEnv op env (OutArgs args')
    outargs f args 
      | Refl <- inargslemma @args = toEnv . f . fromEnv args
      where
        -- coerces are safe, just me being lazy
        fromEnv :: forall args. Args env args -> EmbedEnv op env (OutArgs args) -> PreArgs (FAOutArg op env) args
        fromEnv ArgsNil Empty = ArgsNil
        fromEnv (a :>: args) out = case a of
          ArgArray Out _ _ _ -> case out of
            Push out' x -> FAOutJust x :>: fromEnv args out'
          _ -> FAOutNothing :>: fromEnv args (unsafeCoerce out)
        toEnv :: forall args. PreArgs (FAOutArg op env) args -> EmbedEnv op env (OutArgs args)
        toEnv ArgsNil = Empty
        toEnv (FAOutJust x :>: args) = Push (toEnv args) x
        toEnv (FAOutNothing :>: args) = unsafeCoerce $ toEnv args

newtype BAEEInArg op env arg = BAEEInArg (BackendArgEnvElem op env (InArg arg))
data FAOutArg (op :: Type -> Type) env arg where
  FAOutNothing :: FAOutArg op env arg
  FAOutJust :: FromArg' op env (Value sh e) -> FAOutArg op env (Out sh e)


instance EvalOp op => TupRmonoid (Value' op sh) where
  pair' (Value' x sh1) (Value' y sh2) = Value' (pair' x y) (pair' sh1 sh2)
  unpair' (Value' x sh) = biliftA2 Value' Value' (unpair' x) (unpair' sh)

instance TupRmonoid (Sh' op sh) where
  pair' (Shape' shr sh) _ = Shape' shr sh
  unpair' (Shape' shr sh) = (Shape' shr sh, Shape' shr sh)


instance EvalOp op => TupRmonoid (Compose (BackendArgEnvElem op env) (Value sh)) where
  pair' (Compose (BAE x b)) (Compose (BAE y d)) =
    Compose $ BAE (pair' x y) (pairinfo b d)
  unpair' (Compose (BAE x b)) =
    biliftA2
      (Compose .* BAE)
      (Compose .* BAE)
      (unpair' x)
      (unpairinfo b)

instance EvalOp op => TupRmonoid (Compose (BackendArgEnvElem op env) (Sh sh)) where
  pair' (Compose (BAE x b)) (Compose (BAE y d)) =
    Compose $ BAE (pair' x y) (pairinfo b d)
  unpair' (Compose (BAE x b)) =
    biliftA2
      (Compose .* BAE)
      (Compose .* BAE)
      (unpair' x)
      (unpairinfo b)