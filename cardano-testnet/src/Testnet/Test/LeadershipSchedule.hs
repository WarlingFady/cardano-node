{-# LANGUAGE BlockArguments #-}
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

module Testnet.Test.LeadershipSchedule
  ( testLeadershipSchedule
  ) where

import           Cardano.CLI.Shelley.Output (QueryTipLocalStateOutput (..))
import           Control.Monad (void)
import           Data.List ((\\))
import           Data.Monoid (Last (..))
import           GHC.Stack (callStack)
import           Prelude
import           System.Environment (getEnvironment)
import           System.FilePath ((</>))

import qualified Data.Aeson as J
import qualified Data.Aeson.Types as J
import qualified Data.List as L
import qualified Data.Time.Clock as DTC
import qualified Hedgehog as H
import qualified Hedgehog.Extras.Stock.IO.Network.Sprocket as IO
import qualified Hedgehog.Extras.Test.Base as H
import qualified Hedgehog.Extras.Test.File as H
import qualified Hedgehog.Extras.Test.Process as H

import           Testnet.Util.Assert
import           Testnet.Util.Cli (TestnetMagic)
import           Testnet.Util.Process
import           Testnet.Util.Runtime

testLeadershipSchedule :: TmpPath -> TestnetMagic -> FilePath -> PoolNode -> H.Integration ()
testLeadershipSchedule tmpPath testnetMagic shelleyGenesisFile poolNode1 = do
  work <- H.note $ getWorkDir tmpPath
  H.createDirectoryIfMissing work
  poolSprocket1 <- H.noteShow $ nodeSprocket $ poolRuntime poolNode1

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
    tip <- H.noteShowM $ H.jsonErrorFail $ J.fromJSON @QueryTipLocalStateOutput tipJson

    currEpoch <- case mEpoch tip of
      Nothing -> H.failMessage callStack "cardano-cli query tip returned Nothing for EpochNo"
      Just currEpoch -> return currEpoch

    H.note_ $ "Current Epoch: " <> show currEpoch
    H.assert $ currEpoch > 2

  stakePoolId <- filter ( /= '\n') <$> execCli
    [ "stake-pool", "id"
    , "--cold-verification-key-file", poolNodeKeysColdVkey $ poolKeys poolNode1
    ]

  let poolVrfSkey = poolNodeKeysVrfSkey $ poolKeys poolNode1

  id do
    scheduleFile <- H.noteTempFile work "schedule.log"

    leadershipScheduleDeadline <- H.noteShowM $ DTC.addUTCTime 180 <$> H.noteShowIO DTC.getCurrentTime

    H.byDeadlineM 5 leadershipScheduleDeadline "Failed to query for leadership schedule" $ do
      void $ execCli' execConfig
        [ "query", "leadership-schedule"
        , "--testnet-magic", show @Int testnetMagic
        , "--genesis", shelleyGenesisFile
        , "--stake-pool-id", stakePoolId
        , "--vrf-signing-key-file", poolVrfSkey
        , "--out-file", scheduleFile
        , "--current"
        ]

    scheduleJson <- H.leftFailM $ H.readJsonFile scheduleFile

    expectedLeadershipSlotNumbers <- H.noteShowM $ fmap (fmap slotNumber) $ H.leftFail $ J.parseEither (J.parseJSON @[LeadershipSlot]) scheduleJson

    maxSlotExpected <- H.noteShow $ maximum expectedLeadershipSlotNumbers

    H.assert $ not (L.null expectedLeadershipSlotNumbers)

    leadershipDeadline <- H.noteShowM $ DTC.addUTCTime 90 <$> H.noteShowIO DTC.getCurrentTime

    -- We need enough time to pass such that the expected leadership slots generated by the
    -- leadership-schedule command have actually occurred.
    leaderSlots <- H.byDeadlineM 10 leadershipDeadline "Wait for chain to surpass all expected leadership slots" $ do
      someLeaderSlots <- getRelevantLeaderSlots (poolNodeStdout poolNode1) (minimum expectedLeadershipSlotNumbers)
      if L.null someLeaderSlots
        then H.failure
        else do
          maxActualSlot <- H.noteShow $ maximum someLeaderSlots
          H.assert $ maxActualSlot >= maxSlotExpected
          pure someLeaderSlots

    H.noteShow_ expectedLeadershipSlotNumbers
    H.noteShow_ leaderSlots

    -- As there are no BFT nodes, the next leadership schedule should match slots assigned exactly
    H.assert $ L.null (expectedLeadershipSlotNumbers \\ leaderSlots)

  id do
    scheduleFile <- H.noteTempFile work "schedule.log"

    leadershipScheduleDeadline <- H.noteShowM $ DTC.addUTCTime 180 <$> H.noteShowIO DTC.getCurrentTime

    H.byDeadlineM 5 leadershipScheduleDeadline "Failed to query for leadership schedule" $ do
      void $ execCli' execConfig
        [ "query", "leadership-schedule"
        , "--testnet-magic", show @Int testnetMagic
        , "--genesis", shelleyGenesisFile
        , "--stake-pool-id", stakePoolId
        , "--vrf-signing-key-file", poolVrfSkey
        , "--out-file", scheduleFile
        , "--next"
        ]

    scheduleJson <- H.leftFailM $ H.readJsonFile scheduleFile

    expectedLeadershipSlotNumbers <- H.noteShowM $ fmap (fmap slotNumber) $ H.leftFail $ J.parseEither (J.parseJSON @[LeadershipSlot]) scheduleJson
    maxSlotExpected <- H.noteShow $ maximum expectedLeadershipSlotNumbers

    H.assert $ not (L.null expectedLeadershipSlotNumbers)

    leadershipDeadline <- H.noteShowM $ DTC.addUTCTime 90 <$> H.noteShowIO DTC.getCurrentTime

    -- We need enough time to pass such that the expected leadership slots generated by the
    -- leadership-schedule command have actually occurred.
    leaderSlots <- H.byDeadlineM 10 leadershipDeadline "Wait for chain to surpass all expected leadership slots" $ do
      someLeaderSlots <- getRelevantLeaderSlots (poolNodeStdout poolNode1) (minimum expectedLeadershipSlotNumbers)
      if L.null someLeaderSlots
        then H.failure
        else do
          maxActualSlot <- H.noteShow $ maximum someLeaderSlots
          H.assert $ maxActualSlot >= maxSlotExpected
      pure someLeaderSlots

    H.noteShow_ expectedLeadershipSlotNumbers
    H.noteShow_ leaderSlots

    -- As there are no BFT nodes, the next leadership schedule should match slots assigned exactly
    H.assert $ L.null (expectedLeadershipSlotNumbers \\ leaderSlots)