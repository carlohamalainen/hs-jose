-- This file is part of jose - web crypto library
-- Copyright (C) 2013  Fraser Tweedale
--
-- jose is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}

module Crypto.JOSE.JWS where

import Control.Applicative
import Data.Char
import Data.List
import Data.Maybe
import Data.Word

import Data.Aeson
import qualified Data.ByteString.Lazy as BS
import qualified Data.HashMap.Strict as M
import qualified Data.Text as T
import Data.Traversable (sequenceA)
import qualified Data.Vector as V
import qualified Codec.Binary.Base64Url as B64
import qualified Network.URI

import qualified Crypto.JOSE.JWA.JWS as JWA.JWS
import qualified Crypto.JOSE.JWK as JWK
import qualified Crypto.JOSE.Types as Types


objectPairs (Object o) = M.toList o


critInvalidNames = [
  "alg"
  , "jku"
  , "jwk"
  , "x5u"
  , "x5t"
  , "x5c"
  , "kid"
  , "typ"
  , "cty"
  , "crit"
  ]

data CritParameters
  = CritParameters (M.HashMap T.Text Value)
  | NullCritParameters
  deriving (Eq, Show)

critObjectParser o (String s)
  | s `elem` critInvalidNames = fail "crit key is reserved"
  | otherwise                 = (\v -> (s, v)) <$> o .: s
critObjectParser _ _          = fail "crit key is not text"

-- TODO implement array length >= 1 restriction
instance FromJSON CritParameters where
  parseJSON (Object o)
    | Just (Array paramNames) <- M.lookup "crit" o
    = fmap (CritParameters . M.fromList)
      $ sequenceA
      $ map (critObjectParser o)
      $ V.toList paramNames
    | Just _ <- M.lookup "crit" o
    = fail "crit is not an array"
    | otherwise  -- no "crit" param at all
    = pure NullCritParameters

instance ToJSON CritParameters where
  toJSON (CritParameters m) = Object $ M.insert "crit" (toJSON $ M.keys m) m
  toJSON (NullCritParameters) = object []


data Header = Header {
  alg :: JWA.JWS.Alg
  , jku :: Maybe Network.URI.URI  -- JWK Set URL
  , jwk :: Maybe JWK.Key
  , x5u :: Maybe Network.URI.URI
  , x5t :: Maybe Types.Base64SHA1
  , x5c :: Maybe [Types.Base64X509] -- TODO implement min len of 1
  , kid :: Maybe String  -- interpretation unspecified
  , typ :: Maybe String  -- Content Type (of object)
  , cty :: Maybe String  -- Content Type (of payload)
  , crit :: CritParameters
  }
  deriving (Eq, Show)

instance FromJSON Header where
  parseJSON = withObject "JWS Header" (\o -> Header
    <$> o .: "alg"
    <*> o .:? "jku"
    <*> o .:? "jwk"
    <*> o .:? "x5u"
    <*> o .:? "x5t"
    <*> o .:? "x5c"
    <*> o .:? "kid"
    <*> o .:? "typ"
    <*> o .:? "cty"
    <*> parseJSON (Object o))

instance ToJSON Header where
  toJSON (Header alg jku jwk x5u x5t x5c kid typ cty crit) = object $ catMaybes [
    Just ("alg" .= alg)
    , fmap ("jku" .=) jku
    , fmap ("jwk" .=) jwk
    , fmap ("x5u" .=) x5u
    , fmap ("x5t" .=) x5t
    , fmap ("x5c" .=) x5c
    , fmap ("kid" .=) kid
    , fmap ("typ" .=) typ
    , fmap ("cty" .=) cty
    ]
    ++ objectPairs (toJSON crit)


-- construct a minimal header with the given alg
algHeader alg = Header alg
  Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  NullCritParameters


data EncodedHeader
  = EncodedHeader Header
  | MockEncodedHeader [Word8]
  deriving (Eq, Show)

instance FromJSON EncodedHeader where
  parseJSON = withText "JWS Encoded Header" (\s ->
    case B64.decode $ T.unpack s of
      Just bytes ->  case decode $ BS.pack bytes of
        Just h -> pure $ EncodedHeader h
        Nothing -> fail "signature header: invalid JSON"
      Nothing -> fail "signature header: invalid base64url")

instance ToJSON EncodedHeader where
  toJSON (MockEncodedHeader s) = String $ T.pack $ B64.encode s
  toJSON encodedHeader = String $ T.pack $ encode' encodedHeader


-- TODO: implement following restriction
--
-- §7.2. JWS JSON Serialization
--
--  Of these members, only the "payload", "signatures", and "signature"
--  members MUST be present.  At least one of the "protected" and
--  "header" members MUST be present for each signature/MAC computation
--  so that an "alg" Header Parameter value is conveyed.
--
data Headers =
  Protected EncodedHeader
  | Unprotected Header
  | Both EncodedHeader Header
  deriving (Eq, Show)

instance FromJSON Headers where
  parseJSON (Object o) =
    Both            <$> o .: "protected" <*> o .: "header"
    <|> Protected   <$> o .: "protected"
    <|> Unprotected <$> o .: "header"

instance ToJSON Headers where
  toJSON (Both p u)       = object ["protected" .= p, "header" .= u]
  toJSON (Protected p)    = object ["protected" .= p]
  toJSON (Unprotected u)  = object ["header" .= u]


data Signature = Signature Headers String
  deriving (Eq, Show)

instance FromJSON Signature where
  parseJSON (Object o) = Signature
    <$> o .: "protected"
    <*> parseJSON (Object o)

instance ToJSON Signature where
  toJSON (Signature h s) = object $ ("signature" .= s) : objectPairs (toJSON h)


data Signatures = Signatures Types.Base64Octets [Signature]
  deriving (Eq, Show)

instance FromJSON Signatures where
  parseJSON (Object o) = Signatures
    <$> o .: "payload"
    <*> o .: "signatures"

instance ToJSON Signatures where
  toJSON (Signatures p ss) = object ["payload" .= p, "signatures" .= ss]


-- Convert Signatures to compact serialization.
--
-- The operation is defined only when there is exactly one
-- signature and returns Nothing otherwise
--
encodeCompact :: Signatures -> Maybe String
encodeCompact (Signatures p [Signature h s]) = Just $ cat' (signingInput h p) s
encodeCompact _ = Nothing


-- §5.1. Message Signing or MACing

cat' p p' = intercalate "." [p, p']
encode'   = map (chr . fromIntegral) . init . tail . BS.unpack . encode
encode''  = map (chr . fromIntegral) . init . tail . BS.unpack . encode

signingInput :: Headers -> Types.Base64Octets -> String
signingInput (Both p _) p' = cat' (encode' p) (encode'' p')
signingInput (Protected p) p' = cat' (encode' p) (encode'' p')
signingInput (Unprotected _) p' = cat' "" (encode'' p')

alg' (Both (EncodedHeader h) _)     = alg h
alg' (Protected (EncodedHeader h))  = alg h
alg' (Unprotected h)                = alg h

sign :: Signatures -> Headers -> JWK.Key -> Signatures
sign (Signatures p sigs) h k = Signatures p (sig:sigs) where
  sig = Signature h $ B64.encode $ sign' (alg' h) (signingInput h p) k

sign' :: JWA.JWS.Alg -> String -> JWK.Key -> [Word8]
sign' JWA.JWS.None i _ = []
sign' _ _ _ = undefined


verify :: Signature -> JWK.Key -> Bool
verify = undefined

data VerifyData = Good | Bad | VerifyData [Word8]

runVerify :: Signature -> JWK.Key -> Maybe VerifyData
runVerify = undefined
