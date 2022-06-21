{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
module Data.Array.Accelerate.Trafo.Partitioning.ILP.Solve where


import Data.Array.Accelerate.Trafo.Partitioning.ILP.Graph
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Labels
    (Label, parent, Labels )
import Data.Array.Accelerate.Trafo.Partitioning.ILP.Solver

import Data.List (groupBy, sortOn, foldl')
import Prelude hiding ( pi )

import qualified Data.Map as M

-- In this file, order very often subly does matter.
-- To keep this clear, we use S.Set whenever it does not,
-- and [] only when it does. It's also often efficient
-- by removing duplicates.
import qualified Data.Set as S
import Data.Function ( on )
import Lens.Micro ((^.),  _1 )
import Lens.Micro.Extras ( view )
import Data.Maybe (fromJust,  mapMaybe )

-- Any edge of this form will either be trivial (if fusible) or impossible (if infusible). 
-- They originate from the smart constructor -?>, which is not quite smart enough: It should really perform this check,
-- but then it returns a Maybe Edge, which requires refactoring.. So we simply filter all of those out in this step instead.
trimIds :: S.Set Edge -> S.Set Edge
trimIds = S.filter (\(x:->y) -> x /= y)

-- Makes the ILP. Note that this function 'appears' to ignore the Label levels completely!
-- We could add some assertions, but if all the input is well-formed (no labels, constraints, etc
-- that reward putting non-siblings in the same cluster) this is fine: We will interpret 'cluster 3'
-- with parents `Nothing` as a different cluster than 'cluster 3' with parents `Just 5`.
makeILP :: forall op. MakesILP op => Information op -> ILP op
makeILP (Info
          (Graph nodes (trimIds -> fuseEdges') (trimIds -> nofuseEdges))
          backendconstraints
          backendbounds
        ) = combine graphILP
  where
    -- Remove any redundant 'fusible' edges
    fuseEdges = fuseEdges' S.\\ nofuseEdges

    combine :: ILP op -> ILP op
    combine (ILP dir fun cons bnds _) =
             ILP dir fun (cons <> backendconstraints)
                         (bnds <> backendbounds)
                         n
    -- n is used in some of the constraints, as an upperbound on the number of clusters.
    -- We add a small constant to be safe, as some variables have ranges from -3 to number of nodes.
    n :: Int
    n = 5 + S.size nodes

    graphILP = ILP Minimise objFun myConstraints myBounds n

    -- Placeholder, currently maximising the number of vertical/diagonal fusions.
    -- Since we want all clusters to have one 'iteration size', the final objFun should
    -- take care to never reward 'fusing' disjoint clusters, and then slightly penalise it.
    -- The alternative is O(n^2) edges, so this is worth the trouble!
    --
    -- In the future, maybe we want this to be backend-dependent (add to MakesILP).
    -- Also future: add @IVO's IPU reward here.
    objFun :: Expression op
    objFun = foldl' (\f (i :-> j) -> f .+. fused i j)
                    (int 0)
                    (S.toList fuseEdges)

    myConstraints = acyclic <> infusible <> manifestC <> finalize (S.toList nodes)

    -- x_ij <= pi_j - pi_i <= n*x_ij for all fusible edges
    acyclic = foldMap
                (\(i :-> j) -> between
                              ( fused i j )
                              ( pi j .-. pi i )
                              ( timesN $ fused i j ))
                (fuseEdges <> nofuseEdges)
    infusible = foldMap
                  (\(i :-> j) -> fused i j .==. int 1)
                  nofuseEdges

    -- if (i :-> j) is not fused, i has to be manifest
    -- TODO: final output is also manifest
    manifestC = foldMap
                (\(i :-> j) -> fused i j `impliesBinary` (int 1 .-. manifest i))
                (fuseEdges <> nofuseEdges)

    myBounds :: Bounds op
    --            0 <= pi_i <= n
    myBounds = foldMap (\i -> lowerUpper 0 (Pi i) n)
                  (S.toList nodes)
               <>  -- x_ij \in {0, 1}
               foldMap (\(i :-> j) -> binary $ Fused i j)
                  (S.toList $ fuseEdges <> nofuseEdges)
               <>
               foldMap (\(i :-> j) -> binary (ManifestOutput i) <> binary (ManifestOutput j))
                  (S.toList $ fuseEdges <> nofuseEdges)

negateBinary :: Expression op -> Expression op
negateBinary e = int 1 .-. e

-- if a is 1, then b must be 1
impliesBinary :: Expression op -> Expression op -> Constraint op
impliesBinary a b = a .<=. b

-- Extract the fusion information (ordered list of clusters of Labels) (head is the first cluster).
-- Output has the top-level clusters in fst, and the rest in snd.
interpretSolution :: MakesILP op => Solution op -> ([Labels], M.Map Label [Labels])
interpretSolution =
    (\(x:xs) ->
      ( x
      , M.fromList $
            map
            (\l ->
              ( fromJust -- All labels in the Map will have a parent, only the top clusters can have Nothing as parent (depending on whether we have an Acc or an Afun)
              . view parent
              . S.findMin -- `head` and `findMin` just to get _any_ element:
              . head      -- there is at least one and the parents are all identical
              $ l
              , l))
            xs))
  . map
    ( map
      ( S.fromList
      . map fst)
    . partition snd)
  . partition (^. _1.parent)
  . mapMaybe (_1 fromPi)
  . M.toList
  where
    fromPi (Pi l) = Just l
    fromPi _      = Nothing

    -- groupBy only really does what you want on a sorted list
    partition f = groupBy ((==) `on` f) . sortOn f

data ClusterLs = Execs Labels | NonExec Label
  deriving (Eq, Show)



-- I think that only `let`s can still be in the same cluster as `exec`s, 
-- and their bodies should all be in earlier clusters already.
-- Simply make one cluster per let, before the cluster with execs.
-- TODO: split the cluster of Execs into connected components
splitExecs :: ([Labels], M.Map Label [Labels]) -> M.Map Label (Construction op) -> ([ClusterLs], M.Map Label [ClusterLs])
splitExecs (xs, xM) constrM = (f xs, M.map f xM)
  where
    f :: [Labels] -> [ClusterLs]
    f = concatMap (\ls -> filter (/= Execs mempty) $ map NonExec (S.toList $ S.filter isNonExec ls) ++ [Execs (S.filter isExec ls)])

    isExec l = case constrM M.!? l of
      Just CExe{}  -> True
      Just CExe'{} -> True
      _ -> False
    isNonExec l = not $ isExec l
