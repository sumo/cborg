{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Data.Binary.Serialise.CBOR
-- Copyright   : (c) Duncan Coutts 2015
-- License     : BSD3-style (see LICENSE.txt)
--
-- Maintainer  : duncan@community.haskell.org
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- This module provides functions to serialise and deserialise Haskell
-- values for storage or transmission, to and from lazy
-- @'Data.ByteString.Lazy.ByteString'@s. It also provides a type class
-- and utilities to help you make your types serialisable.
--
-- For a full tutorial on using this module, see
-- "Data.Binary.Serialise.CBOR.Tutorial".
--
module Data.Binary.Serialise.CBOR
  ( -- * High level, one-shot API
    -- $highlevel
    serialise
  , deserialise
  , deserialiseOrFail

    -- * Deserialisation exceptions
  , DeserialiseFailure(..)

    -- * Incremental encoding interface
    -- $primitives
  , serialiseIncremental
  , deserialiseIncremental
  , DecodeIncrementally(..)

    -- * The @'Serialise'@ class
  , Serialise(..)

    -- * IO operations
    -- | Convenient utilities for basic @'IO'@ operations.

    -- ** @'FilePath'@ API
  , writeFileSerialise
  , readFileDeserialise
    -- ** @'Handle'@ API
  , hPutSerialise
  ) where

#include "cbor.h"

import           System.IO                        (Handle, IOMode (..), withFile)
import           Control.Exception                (throw, throwIO)
import           Control.Monad.ST                 (ST, runST)

import qualified Data.ByteString.Builder          as BS
import qualified Data.ByteString.Lazy             as BS
import qualified Data.ByteString.Lazy.Internal    as BS

import           Data.Binary.Serialise.CBOR.Class
import qualified Data.Binary.Serialise.CBOR.Read  as CBOR.Read
import           Data.Binary.Serialise.CBOR.Read  (DecodeIncrementally(..),
                                                   DeserialiseFailure)
import qualified Data.Binary.Serialise.CBOR.Write as CBOR.Write

--------------------------------------------------------------------------------

-- $primitives
-- The following API allows you to encode or decode CBOR values incrementally,
-- which is useful for large structures that require you to stream values in
-- over time.
--

-- | Serialise a Haskell value to an external binary representation.
--
-- The output is represented as a 'BS.Builder' and is constructed incrementally.
-- The representation as a 'BS.Builder' allows efficient concatenation with
-- other data.
serialiseIncremental :: Serialise a => a -> BS.Builder
serialiseIncremental = CBOR.Write.toBuilder . encode

-- | Deserialise a Haskell value from the external binary representation.
--
-- This allows /input/ data to be provided incrementally, rather than all in one
-- go. It also gives an explicit representation of deserialisation errors.
--
-- Note that the incremental behaviour is only for the input data, not the
-- output value: the final deserialised value is constructed and returned as a
-- whole, not incrementally.
deserialiseIncremental :: Serialise a => ST s (DecodeIncrementally s a)
deserialiseIncremental = CBOR.Read.deserialiseIncremental decode

--------------------------------------------------------------------------------

-- $highlevel
-- The following API exposes a high level interface allowing you to quickly
-- convert between arbitrary Haskell values (which are an instance of
-- @'Serialise'@) and lazy @'BS.ByteString'@s.
--

-- | Serialise a Haskell value to an external binary representation.
--
-- The output is represented as a lazy 'BS.ByteString' and is constructed
-- incrementally.
serialise :: Serialise a => a -> BS.ByteString
serialise = CBOR.Write.toLazyByteString . encode

-- | Deserialise a Haskell value from the external binary representation
-- (which must have been made using 'serialise' or related function).
--
-- /Throws/: @'DeserialiseFailure'@ if the given external representation is
-- invalid or does not correspond to a value of the expected type.
deserialise :: Serialise a => BS.ByteString -> a
deserialise = either throw id
            . deserialiseOrFail

-- | Deserialise a Haskell value from the external binary representation,
-- or get back a @'DeserialiseFailure'@.
deserialiseOrFail :: Serialise a => BS.ByteString -> Either DeserialiseFailure a
deserialiseOrFail bs =
    runDecodeIncrementally deserialiseIncremental bs


runDecodeIncrementally :: (forall s. ST s (DecodeIncrementally s a))
                       -> BS.ByteString -> Either DeserialiseFailure a
runDecodeIncrementally d lbs =
    runST (flip go lbs =<< d)
  where
    go :: DecodeIncrementally s a -> BS.ByteString
       -> ST s (Either DeserialiseFailure a)
    go (Fail _ _ err) _                = return (Left err)
    go (Done _ _ x)   _                = return (Right x)
    go (Partial k)  BS.Empty          = k Nothing   >>= flip go BS.Empty
    go (Partial k) (BS.Chunk bs lbs') = k (Just bs) >>= flip go lbs'


--------------------------------------------------------------------------------
-- File-based API

-- | Serialise a @'BS.ByteString'@ (via @'serialise'@) and write it directly
-- to the specified @'Handle'@.
hPutSerialise :: Serialise a
              => Handle       -- ^ The @'Handle'@ to write to.
              -> a            -- ^ The value to be serialised and written.
              -> IO ()
hPutSerialise hnd x = BS.hPut hnd (serialise x)

-- | Serialise a @'BS.ByteString'@ and write it directly to the
-- specified file.
writeFileSerialise :: Serialise a
                   => FilePath     -- ^ The file to write to.
                   -> a            -- ^ The value to be serialised and written.
                   -> IO ()
writeFileSerialise fname x =
    withFile fname WriteMode $ \hnd -> hPutSerialise hnd x

-- | Read the specified file (internally, by reading a @'BS.ByteString'@)
-- and attempt to decode it into a Haskell value using @'deserialise'@
-- (the type of which is determined by the choice of the result type).
--
-- /Throws/: @'DeserialiseFailure'@ iff the file fails to
-- deserialise properly.
readFileDeserialise :: Serialise a
                    => FilePath     -- ^ The file to read from.
                    -> IO a         -- ^ The deserialised value.
readFileDeserialise fname =
    withFile fname ReadMode $ \hnd -> do
      input <- BS.hGetContents hnd
      case deserialiseOrFail input of
        Left  err -> throwIO err
        Right x   -> return x
