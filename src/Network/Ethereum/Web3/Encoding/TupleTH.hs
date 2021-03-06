{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module      :  Network.Ethereum.Web3.Encoding.TupleTH
-- Copyright   :  Alexander Krupenkin 2016
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  portable
--
-- Tuple ABI encoding instance TH generator.
--
module Network.Ethereum.Web3.Encoding.TupleTH (
    mkTupleInst
  , ABIData(..)
  , sParser
  , dParser
  ) where

import           Control.Monad                           (replicateM)
import           Data.Attoparsec.Text                    (Parser)
import qualified Data.Attoparsec.Text                    as P
import qualified Data.Text.Lazy                          as LT
import           Data.Text.Lazy.Builder                  (Builder, toLazyText)
import           Language.Haskell.TH
import           Network.Ethereum.Web3.Encoding
import           Network.Ethereum.Web3.Encoding.Internal

-- | Argument offset calculator
offset :: Int
       -- ^ Count of arguments
       -> [Builder]
       -- ^ Previous dynamic arguments
       -> Int
       -- ^ Offset
offset totalArgs args = headerOffset + dataOffset
  where
    headerOffset = totalArgs * 32
    dataOffset   = builderLen (mconcat args)
    builderLen   = fromIntegral . (`div` 2) . LT.length . toLazyText

-- | ABI data multiparam internal serializer
class ABIData a where
    _serialize :: (Int, [(Builder, Builder)]) -> a
    -- ^ Serialize with accumulator:
    -- pair of argument count and list of pair header and
    -- data part (for dynamic arguments)

instance (EncodingType b, ABIEncoding b, ABIData a) => ABIData (b -> a) where
    _serialize (n, l) x
        | isDynamic x = _serialize (n, (toDataBuilder dynOffset, toDataBuilder x) : l)
        | otherwise   = _serialize (n, (toDataBuilder x        , mempty) : l)
      where dynOffset = offset n (fmap snd l)

instance ABIData Builder where
    _serialize = uncurry mappend . mconcat . reverse . snd

-- | Static argument parser
sParser :: (EncodingType a, ABIEncoding a) => a -> Parser a
sParser x | isDynamic x = P.take 64 >> return undefined
          | otherwise   = fromDataParser

-- | Dynamic argument parser
dParser :: (EncodingType a, ABIEncoding a) => a -> Parser a
dParser x | isDynamic x = fromDataParser
          | otherwise   = return x

-- | Generator for tupleP{N} function signature
mkTuplePType :: Int -> DecQ
mkTuplePType n = do
    varsT <- fmap varT <$> replicateM n (newName "t")
    let contextT   = concat
            [[[t|ABIEncoding $x|], [t|EncodingType $x|]] | x <- varsT]
        varsTupleT = foldl appT (tupleT n) varsT
    sigD (mkName $ "tupleP" ++ show n)
         (forallT [] (cxt contextT) [t|Parser $(varsTupleT)|])

-- | Generator for tupleP{N} function
mkTupleP :: Int -> DecQ
mkTupleP n = do
    vars <- replicateM n (newName "t")
    funD (mkName $ "tupleP" ++ show n) $ pure $
        clause []
               (normalB [|$(varE withPN) $(varE staticPN) >>= $(varE dynamicPN)|])
               (decs vars)
  where
    withPN    = mkName "withParser"
    staticPN  = mkName "staticParser"
    dynamicPN = mkName "dynamicParser"
    fun       = mkName "f"
    decs vars = [ withPFun, staticPFun vars, dynamicPFun vars ]

    withPFun  = funD withPN $ pure $
        clause [varP fun]
            (normalB [|$(varE fun) $(tupE (replicate n [|undefined|]))|]) []

    staticPFun vars = funD staticPN $ pure $
        clause [tupP $ fmap varP vars]
            (normalB (mkAppSeq (eTupleE n : fmap (\x -> [|sParser $(varE x)|]) vars))) []

    dynamicPFun vars = funD dynamicPN $ pure $
        clause [tupP $ fmap varP vars]
            (normalB (mkAppSeq (eTupleE n : fmap (\x -> [|dParser $(varE x)|]) vars))) []

mkAppSeq :: [ExpQ] -> ExpQ
mkAppSeq = infixApps . dollarFirst . sparse
  where sparse [x]      = [x]
        sparse (x : xs) = x : [|(<*>)|] : sparse xs
        dollarFirst (x : _ : xs) = x : [|(<$>)|] : xs
        infixApps (x : xs) = go x xs
        go acc []           = acc
        go acc (f : x : xs) = go (infixApp acc f x) xs

eTupleE :: Int -> ExpQ
eTupleE 2  = [|(,)|]
eTupleE 3  = [|(,,)|]
eTupleE 4  = [|(,,,)|]
eTupleE 5  = [|(,,,,)|]
eTupleE 6  = [|(,,,,,)|]
eTupleE 7  = [|(,,,,,,)|]
eTupleE 8  = [|(,,,,,,,)|]
eTupleE 9  = [|(,,,,,,,,)|]
eTupleE 10 = [|(,,,,,,,,,)|]
eTupleE 11 = [|(,,,,,,,,,,)|]
eTupleE 12 = [|(,,,,,,,,,,,)|]
eTupleE 13 = [|(,,,,,,,,,,,,)|]
eTupleE 14 = [|(,,,,,,,,,,,,,)|]
eTupleE 15 = [|(,,,,,,,,,,,,,,)|]
eTupleE _  = error "Unsupported tuple size"

mkEncodingInst :: Int -> DecQ
mkEncodingInst n = do
    vars <- replicateM n (newName "t")
    let varsT      = fmap varT vars
        contextT   = concat
            [[[t|ABIEncoding $x|], [t|EncodingType $x|]] | x <- varsT]
        varsTupleT = foldl appT (tupleT n) varsT
    instanceD (cxt contextT) (appT [t|ABIEncoding|] varsTupleT)
      [ funD (mkName "toDataBuilder") [
            clause [tupP (fmap varP vars)]
                (normalB (appsE ([|_serialize (n, [])|] : fmap varE vars))) [] ]
      , funD (mkName "fromDataParser") [
            clause [] (normalB $ varE $ mkName $ "tupleP" ++ show n) [] ]
      ]

-- | Make a ABIEncoding tuple instance with given count of arguments
mkTupleInst :: Int -> Q [Dec]
mkTupleInst n = sequence
  [ mkTuplePType n
  , mkTupleP n
  , mkEncodingInst n ]
