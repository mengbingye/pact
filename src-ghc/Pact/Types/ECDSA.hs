{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Pact.Types.ECDSA
  ( PublicKey
  , PrivateKey
  , Signature
  , genKeyPair
  , getPublicKey
  , hashAlgoETH
  , signETH
  , validETH
  , formatPublicKeyETH
  , exportPublic,    importPublic
  , exportPrivate,   importPrivate
  , exportSignature, importSignature
  ) where


import Data.ByteString  (ByteString)
import Data.Text        (Text)
import Data.Monoid      ((<>))

import Crypto.PubKey.ECC.Generate  (generate, generateQ)
import Crypto.PubKey.ECC.ECDSA     (PublicKey(..), PrivateKey(..), Signature(..))
import Crypto.PubKey.ECC.Prim      (isPointValid, isPointAtInfinity)
import Crypto.Number.Serialize     (i2osp, os2ip)

import qualified Crypto.Hash              as H
import qualified Crypto.PubKey.ECC.Types  as ECDSA
import qualified Crypto.PubKey.ECC.ECDSA  as ECDSA
import qualified Data.ByteArray           as BA
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Base16   as B16


import Pact.Types.Util (parseB16TextOnly, toB16Text)



--------- ETHEREUM SCHEME FUNCTIONS ---------

curveECDSA :: ECDSA.Curve
curveECDSA = ECDSA.getCurveByName ECDSA.SEC_p256k1


hashAlgoETH :: H.SHA3_256 
hashAlgoETH = H.SHA3_256


genKeyPair :: IO (PublicKey, PrivateKey)
genKeyPair = generate curveECDSA


getPublicKey :: PrivateKey -> PublicKey
getPublicKey (PrivateKey curve d) = PublicKey curve (generateQ curve d)


signETH :: ByteString -> PublicKey -> PrivateKey -> IO Signature
signETH msg _ priv = ECDSA.sign priv hashAlgoETH msg


validETH :: ByteString -> PublicKey -> Signature -> Bool
validETH msg pub sig = ECDSA.verify hashAlgoETH pub sig msg


-- Algorithm for transforming ECDSA Public Key into Ethereum address
-- found here: https://kobl.one/blog/create-full-ethereum-keypair-and-address/
-- Assumes ByteString is not base 16.
formatPublicKeyETH :: ByteString -> ByteString
formatPublicKeyETH pub = BS.drop 12 $ keccak256Hash pub




--------- ECDSA KEYS AND SIGNATURES FUNCTIONS ---------

exportPublic :: ECDSA.PublicKey -> ByteString
exportPublic (ECDSA.PublicKey _ point) =
   case point of
      ECDSA.Point x y  -> integerToBS x <> integerToBS y
      ECDSA.PointO     -> BS.empty


-- ECDSA Public Key must be uncompressed and 64 bytes long or 65 bytes with 0x04.
-- Assumes ByteString is not base 16.
-- Source: https://kobl.one/blog/create-full-ethereum-keypair-and-address/

importPublic :: ByteString -> Maybe PublicKey
importPublic bs | BS.length bs == 65 &&
                  startsWithConstant4    = checkIfValid (BS.drop 1 bs)
                | BS.length bs == 64     = checkIfValid bs
                | otherwise              = Nothing
  where  startsWithConstant4 =
           (BS.take 1 bs) == (integerToBS 0x04)
         point b = ECDSA.Point (bsToInteger xBS) (bsToInteger yBS)
           where (xBS, yBS) = BS.splitAt 32 b
         checkIfValid b
           | isPointValid curveECDSA (point b) &&
             not (isPointAtInfinity (point b))      = Just $ PublicKey curveECDSA (point b)
           | otherwise                              = Nothing




exportPrivate :: ECDSA.PrivateKey -> ByteString
exportPrivate (PrivateKey _ p) = integerToBS p


-- ECDSA Private Key must be 32 bytes and not begin with 0x00 (null byte)
-- Assumes ByteString is not base 16.
-- Source: https://kobl.one/blog/create-full-ethereum-keypair-and-address/

importPrivate :: ByteString -> Maybe PrivateKey
importPrivate bs | not startsNullByte &&
                   BS.length bs == 32     = checkIfValid
                 | otherwise              = Nothing
  where startsNullByte =
          (BS.take 1 bs) == (integerToBS 0x00)
        i = bsToInteger bs
        n = ECDSA.ecc_n (ECDSA.common_curve curveECDSA)
        checkIfValid
          | i >= 1 && i <= n   = Just $ PrivateKey curveECDSA i
          | otherwise          = Nothing




exportSignature :: ECDSA.Signature -> ByteString
exportSignature (Signature r s) = (integerToBS r) <> (integerToBS s)


-- Assumes ByteString is not base 16.

importSignature :: ByteString -> Maybe Signature
importSignature bs | BS.length bs == 64   = Just makeSignature
                   | otherwise            = Nothing
  where (rBS, sBS) = BS.splitAt 32 bs
        makeSignature = Signature (bsToInteger rBS) (bsToInteger sBS)




--------- ECDSA HELPER FUNCTIONS ---------

keccak256Hash :: ByteString -> ByteString
keccak256Hash =
  BS.pack . BA.unpack . (H.hash :: BA.Bytes -> H.Digest H.Keccak_256) . BA.pack . BS.unpack


integerToBS :: Integer -> ByteString
integerToBS = i2osp


bsToInteger :: ByteString -> Integer
bsToInteger = os2ip


textToPublic :: Text -> Either String ECDSA.PublicKey
textToPublic t = do
  b' <- parseB16TextOnly t
  case importPublic b' of
    Nothing -> Left "ECDSA Public Key import failed"
    Just p  -> Right p


{--
integralToHexBS :: Integral a => a -> ByteString
integralToHexBS a = BS.pack $ reverse $ go (quotRem a base) where
  go (n,d) | n == 0 = [fromIntegral d]
           | otherwise = (fromIntegral d):go (quotRem n base)
  base = 256


-- Generates an ECDSA nonce (`k`) deterministically according to RFC 6979.
-- https://tools.ietf.org/html/rfc6979#section-3.2
-- Based in this example:
--   https://github.com/btcsuite/btcd/blob/master/btcec/signature.go#L455
-- If k-signature returns zero should re-determine k
deterministicNonce :: PrivateKey -> ByteString -> Int
deterministicNonce = undefined
--}




--------- ECDSA TESTS ---------

-- Example from https://kobl.one/blog/create-full-ethereum-keypair-and-address/
-- "Which gives us the Ethereum address 0x0bed7abd61247635c1973eb38474a2516ed1d884"

_testFormatPublicKeyETH :: Text
_testFormatPublicKeyETH = toB16Text $ formatPublicKeyETH $ fst $ B16.decode
  "836b35a026743e823a90a0ee3b91bf615c6a757e2b60b9e1dc1826fd0dd16106f7bc1e8179f665015f43c6c81f39062fc2086ed849625c06e04697698b21855e"


_testPublicKeyImport64Bytes :: Either String PublicKey
_testPublicKeyImport64Bytes = textToPublic "836b35a026743e823a90a0ee3b91bf615c6a757e2b60b9e1dc1826fd0dd16106f7bc1e8179f665015f43c6c81f39062fc2086ed849625c06e04697698b21855e"

_testPublicKeyImport65Bytes :: Either String PublicKey
_testPublicKeyImport65Bytes = textToPublic "04836b35a026743e823a90a0ee3b91bf615c6a757e2b60b9e1dc1826fd0dd16106f7bc1e8179f665015f43c6c81f39062fc2086ed849625c06e04697698b21855e"

_testSameKey :: Bool
_testSameKey = _testPublicKeyImport64Bytes == _testPublicKeyImport65Bytes


-- Only 65 bytes Public Keys starting with 0x04 are valid.
_testPublicKeyImport65BytesFail :: Either String PublicKey
_testPublicKeyImport65BytesFail = textToPublic "05836b35a026743e823a90a0ee3b91bf615c6a757e2b60b9e1dc1826fd0dd16106f7bc1e8179f665015f43c6c81f39062fc2086ed849625c06e04697698b21855e"
