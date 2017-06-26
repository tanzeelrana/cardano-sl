{-# LANGUAGE ScopedTypeVariables #-}

-- | Higher-level functions working with GState DB.

module Pos.DB.GState.GState
       ( prepareGStateDB
       , sanityCheckGStateDB
       , usingGStateSnapshot
       ) where

import           Universum

import           Control.Monad.Catch        (MonadMask)
import qualified Database.RocksDB           as Rocks
import qualified Ether
import           System.Wlog                (WithLogger)

import           Pos.Context.Context        (GenesisUtxo (..))
import           Pos.Context.Functions      (genesisUtxoM)
import           Pos.Core                   (HeaderHash, Timestamp)
import           Pos.DB.Class               (MonadDB, MonadDBRead, MonadRealDB,
                                             getNodeDBs, usingReadOptions)
import           Pos.DB.GState.Balances     (getRealTotalStake)
import           Pos.DB.GState.BlockExtra   (initGStateBlockExtra)
import           Pos.DB.GState.Common       (initGStateCommon, isInitialized,
                                             setInitialized)
import           Pos.DB.Types               (DB (..), NodeDBs (..), Snapshot (..),
                                             gStateDB, usingSnapshot)
import           Pos.Ssc.GodTossing.DB      (initGtDB)
import           Pos.Ssc.GodTossing.Genesis (genesisCertificates)
import           Pos.Txp.DB                 (initGStateBalances, initGStateUtxo,
                                             sanityCheckBalances, sanityCheckUtxo)
import           Pos.Update.DB              (initGStateUS)

-- | Put missing initial data into GState DB.
prepareGStateDB ::
       forall m. (Ether.MonadReader' GenesisUtxo m, MonadDB m)
    => Timestamp
    -> HeaderHash
    -> m ()
prepareGStateDB systemStart initialTip = unlessM isInitialized $ do
    genesisUtxo <- genesisUtxoM

    initGStateCommon initialTip
    initGStateUtxo genesisUtxo
    initGtDB genesisCertificates
    initGStateBalances genesisUtxo
    initGStateUS systemStart
    initGStateBlockExtra initialTip

    setInitialized

-- | Check that GState DB is consistent.
sanityCheckGStateDB
    :: forall m.
       (MonadDBRead m, MonadMask m, WithLogger m)
    => m ()
sanityCheckGStateDB = do
    sanityCheckBalances
    sanityCheckUtxo =<< getRealTotalStake

usingGStateSnapshot :: (MonadRealDB m, MonadMask m) => m a -> m a
usingGStateSnapshot action = do
    db <- _gStateDB <$> getNodeDBs
    let readOpts = rocksReadOpts db
    usingSnapshot db (\(Snapshot sn) ->
        usingReadOptions readOpts {Rocks.useSnapshot = Just sn} gStateDB action)
