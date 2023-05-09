{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Data.Avro.Deriving.NormSchema
where

import           Control.Monad.State.Strict
import           Data.Avro.Schema.Schema
import qualified Data.Foldable              as Foldable
import qualified Data.Map.Strict            as M

-- | Extracts all the records from the schema (flattens the schema)
-- Named types get resolved when needed to include at least one "inlined"
-- schema in each record and to make each record self-contained.
-- Note: Namespaces are not really supported in this version. All the
-- namespaces (including inlined into full names) will be ignored
-- during names resolution.
extractDerivables :: Schema -> [Schema]
extractDerivables s = flip evalState initial . normSchema . snd <$> rawRecs
  where
    rawRecs = getTypes s
    initial = M.fromList rawRecs

getTypes :: Schema -> [(TypeName, Schema)]
getTypes rec = case rec of
  r@Record{name, fields} -> (name,r) : (fields >>= (getTypes . fldType))
  Array t                -> getTypes t
  Union ts               -> concatMap getTypes (Foldable.toList ts)
  Map t                  -> getTypes t
  e@Enum{name}           -> [(name, e)]
  f@Fixed{name}          -> [(name, f)]
  _                      -> []

-- Ensures normalisation: "extracted" record is self-contained and
-- all the named types are resolvable within the scope of the schema.
normSchema :: Schema -> State (M.Map TypeName Schema) Schema
normSchema r = case r of
  t@(NamedType tn) -> do
    resolved <- get
    case M.lookup tn resolved of
      Just rs ->
        -- use the looked up schema (which might be a full record) and replace
        -- it in the state with NamedType for future resolves
        -- because only one full definition per schema is needed
        modify' (M.insert tn t) >> case rs of
            NamedType _ -> pure rs -- If we get a reference, the schema was already normalised.
            _ -> normSchema rs -- Otherwise, normalise the schema before inlining.

        -- NamedType but no corresponding record?! Baaad!
      Nothing ->
        error $ "Unable to resolve schema: " <> show (typeName t)

  Array s -> Array <$> normSchema s
  Map s   -> Map <$> normSchema s
  Union l -> Union <$> traverse normSchema l
  Record { name }  -> do
    modify' (M.insert name (NamedType name))
    flds <- mapM (\fld -> setType fld <$> normSchema (fldType fld)) (fields r)
    pure $ r { fields = flds }
  Fixed { name } -> do
    modify' (M.insert name (NamedType name))
    pure r
  Enum { name } -> do
    modify' (M.insert name (NamedType name))
    pure r
  s         -> pure s
  where
    setType fld t = fld { fldType = t}
