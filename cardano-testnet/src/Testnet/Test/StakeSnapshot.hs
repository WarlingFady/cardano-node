{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{- HLINT ignore "Redundant id" -}
{- HLINT ignore "Redundant return" -}
{- HLINT ignore "Use head" -}
{- HLINT ignore "Use let" -}

module Testnet.Test.StakeSnapshot
  ( testStakeSnapshot
  ) where

import           Prelude

import           Control.Monad (void)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import           Data.Monoid (Last (..))
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Time.Clock as DTC
import           GHC.Stack (callStack)
import           System.Environment (getEnvironment)
import           System.FilePath ((</>))

import           Cardano.CLI.Shelley.Output (QueryTipLocalStateOutput (..))

import           Hedgehog ((===))
import qualified Hedgehog as H
import qualified Hedgehog.Extras.Stock.IO.Network.Sprocket as IO
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H
import qualified Hedgehog.Extras.Test.Process as H
import           Testnet.Util.Cli (TestnetMagic)
import           Testnet.Util.Process
import           Testnet.Util.Runtime

testStakeSnapshot :: TmpPath -> TestnetMagic -> IO.Sprocket -> H.Integration ()
testStakeSnapshot tmpPath testnetMagic poolSprocket1 = do
  work <- H.note $ getWorkDir tmpPath
  H.createDirectoryIfMissing work

  env <- H.evalIO getEnvironment

  execConfig <- H.noteShow H.ExecConfig
    { H.execConfigEnv = Last $ Just $
      [ ("CARDANO_NODE_SOCKET_PATH", IO.sprocketArgumentName poolSprocket1)
      ]
      -- The environment must be passed onto child process on Windows in order to
      -- successfully start that process.
      <> env
    , H.execConfigCwd = Last $ Just $ getTmpBaseAbsPath tmpPath
    }

  tipDeadline <- H.noteShowM $ DTC.addUTCTime 210 <$> H.noteShowIO DTC.getCurrentTime

  H.byDeadlineM 10 tipDeadline "Wait for two epochs" $ do
    void $ execCli' execConfig
      [ "query", "tip"
      , "--testnet-magic", show @Int testnetMagic
      , "--out-file", work </> "current-tip.json"
      ]

    tipJson <- H.leftFailM . H.readJsonFile $ work </> "current-tip.json"
    tip <- H.noteShowM $ H.jsonErrorFail $ Aeson.fromJSON @QueryTipLocalStateOutput tipJson

    currEpoch <- case mEpoch tip of
      Nothing -> H.failMessage callStack "cardano-cli query tip returned Nothing for EpochNo"
      Just currEpoch -> return currEpoch

    H.note_ $ "Current Epoch: " <> show currEpoch
    H.assert $ currEpoch > 2

  result <- execCli' execConfig
    [ "query", "stake-snapshot"
    , "--testnet-magic", show @Int testnetMagic
    , "--all-stake-pools"
    ]

  json <- H.leftFail $ Aeson.eitherDecode @Aeson.Value (LBS.fromStrict (Text.encodeUtf8 (Text.pack result)))

  -- There are three stake pools so check that "pools" has three entries
  case json of
    Aeson.Object kmJson -> do
      pools <- H.nothingFail $ KM.lookup "pools" kmJson
      case pools of
        Aeson.Object kmPools -> KM.size kmPools === 3
        _ -> H.failure
    _ -> H.failure