-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE PatternGuards #-}
module Cryptol.ModuleSystem.Interface (
    Iface(..)
  , IfaceDecls(..)
  , IfaceTySyn, ifTySynName
  , IfaceNewtype
  , IfaceDecl(..), mkIfaceDecl

  , shadowing
  , interpImport
  , unqualified
  , genIface
  ) where

import           Cryptol.ModuleSystem.Name (mkQual)
import           Cryptol.TypeCheck.AST
import           Cryptol.Utils.PP

import qualified Data.Map as Map

#if __GLASGOW_HASKELL__ < 710
import           Data.Monoid (Monoid(..))
#endif

-- | The resulting interface generated by a module that has been typechecked.
data Iface = Iface
  { ifModName :: ModName
  , ifPublic  :: IfaceDecls
  , ifPrivate :: IfaceDecls
  } deriving (Show)

data IfaceDecls = IfaceDecls
  { ifTySyns   :: Map.Map QName [IfaceTySyn]
  , ifNewtypes :: Map.Map QName [IfaceNewtype]
  , ifDecls    :: Map.Map QName [IfaceDecl]
  } deriving (Show)

instance Monoid IfaceDecls where
  mempty      = IfaceDecls Map.empty Map.empty Map.empty
  mappend l r = IfaceDecls
    { ifTySyns   = Map.unionWith (mergeByName ifTySynName) (ifTySyns l)   (ifTySyns r)
    , ifNewtypes = Map.unionWith (mergeByName ntName)      (ifNewtypes l) (ifNewtypes r)
    , ifDecls    = Map.unionWith (mergeByName ifDeclName)  (ifDecls l)    (ifDecls r)
    }
  mconcat ds  = IfaceDecls
    { ifTySyns   = Map.unionsWith (mergeByName ifTySynName) (map ifTySyns ds)
    , ifNewtypes = Map.unionsWith (mergeByName ntName)      (map ifNewtypes ds)
    , ifDecls    = Map.unionsWith (mergeByName ifDeclName)  (map ifDecls  ds)
    }

-- | Merge the entries in the simple case.
mergeByName :: (a -> QName) -> [a] -> [a] -> [a]
mergeByName f ls rs
  | [l] <- ls, [r] <- rs, f l == f r = ls
  | otherwise                        = ls ++ rs

-- | Like mappend for IfaceDecls, but preferring entries on the left.
shadowing :: IfaceDecls -> IfaceDecls -> IfaceDecls
shadowing l r = IfaceDecls
  { ifTySyns   = Map.union (ifTySyns   l) (ifTySyns   r)
  , ifNewtypes = Map.union (ifNewtypes l) (ifNewtypes r)
  , ifDecls    = Map.union (ifDecls    l) (ifDecls    r)
  }

type IfaceTySyn = TySyn

ifTySynName :: TySyn -> QName
ifTySynName = tsName

type IfaceNewtype = Newtype

data IfaceDecl = IfaceDecl
  { ifDeclName    :: QName
  , ifDeclSig     :: Schema
  , ifDeclPragmas :: [Pragma]
  , ifDeclInfix   :: Bool
  , ifDeclFixity  :: Maybe Fixity
  , ifDeclDoc     :: Maybe String
  } deriving (Show)

mkIfaceDecl :: Decl -> IfaceDecl
mkIfaceDecl d = IfaceDecl
  { ifDeclName    = dName d
  , ifDeclSig     = dSignature d
  , ifDeclPragmas = dPragmas d
  , ifDeclInfix   = dInfix d
  , ifDeclFixity  = dFixity d
  , ifDeclDoc     = dDoc d
  }

-- | Like mapIfaceDecls, but gives you back a NameEnv that describes the
-- transformation.
mapIfaceDecls :: (QName -> QName) -> IfaceDecls -> (IfaceDecls,NameEnv)
mapIfaceDecls f decls = (decls',names)
  where
  decls' = IfaceDecls
    { ifTySyns   = Map.mapKeys f (ifTySyns decls)
    , ifNewtypes = Map.mapKeys f (ifNewtypes decls)
    , ifDecls    = Map.mapKeys f (ifDecls decls)
    }

  namesFor :: (a -> Bool) -> (IfaceDecls -> Map.Map QName a) -> NameEnv
  namesFor isInfix prj =
    mkNameEnv [ (k, info) | (k,ds) <- Map.toList (prj decls)
                          , let info = NameInfo (f k) (isInfix ds) ]

  names = mconcat [ namesFor (const False)     ifTySyns
                  , namesFor (const False)     ifNewtypes
                  , namesFor (all ifDeclInfix) ifDecls ]

filterIfaceDecls :: (QName -> Bool) -> IfaceDecls -> IfaceDecls
filterIfaceDecls p decls = IfaceDecls
  { ifTySyns = Map.filterWithKey check (ifTySyns decls)
  , ifNewtypes = Map.filterWithKey check (ifNewtypes decls)
  , ifDecls  = Map.filterWithKey check (ifDecls decls)
  }
  where
  check :: QName -> a -> Bool
  check k _ = p k

unqualified :: IfaceDecls -> (IfaceDecls,NameEnv)
unqualified  = mapIfaceDecls (mkUnqual . unqual)

-- | Generate an Iface from a typechecked module.
genIface :: Module -> Iface
genIface m = Iface
  { ifModName = mName m
  , ifPublic  = IfaceDecls
    { ifTySyns = tsPub
    , ifNewtypes = ntPub
    , ifDecls  = dPub
    }
  , ifPrivate = IfaceDecls
    { ifTySyns = tsPriv
    , ifNewtypes = ntPriv
    , ifDecls  = dPriv
    }
  }
  where

  (tsPub,tsPriv) =
      Map.partitionWithKey (\ qn _ -> qn `isExportedType` mExports m )
      $ fmap return (mTySyns m)

  (ntPub,ntPriv) =
      Map.partitionWithKey (\ qn _ -> qn `isExportedType` mExports m )
      $ fmap return (mNewtypes m)

  (dPub,dPriv) =
      Map.partitionWithKey (\ qn _ -> qn `isExportedBind` mExports m)
      $ Map.fromList [ (qn,[mkIfaceDecl d]) | dg <- mDecls m
                                            , d  <- groupDecls dg
                                            , let qn = dName d
                                            ]

-- | Interpret an import declaration in the scope of the interface it targets.
interpImport :: Import -> Iface -> (Iface,NameEnv)
interpImport i iface = (iface',names)
  where
  iface' = Iface
    { ifModName = ifModName iface
    , ifPublic  = qualified
    , ifPrivate = mempty
    }

  -- the initial set of names is {unqualified => qualified}
  public = ifPublic iface

  -- qualify imported names
  (qualified,names) | Just n <- iAs i = qualifyNames n restricted
                    | otherwise       = unqualified restricted

  -- interpret an import spec to quotient a naming map
  restricted
    | Just (Hiding ns) <- iSpec i =
       filterIfaceDecls (\qn -> not (unqual qn `elem` ns)) public

    | Just (Only ns) <- iSpec i =
       filterIfaceDecls (\qn -> unqual qn `elem` ns) public

    | otherwise = public

  qualifyNames pfx = mapIfaceDecls (\ n -> mkQual pfx (unqual n))
