-- | Generation of genesis data for testnet.

module Pos.Core.Genesis.Generate
       ( GeneratedGenesisData (..)
       , GeneratedSecrets (..)
       , generateSecrets
       , generateFakeAvvm
       , generateGenesisData
       ) where

import           Universum

import           Crypto.Random                           (MonadRandom, getRandomBytes)
import qualified Data.HashMap.Strict                     as HM
import qualified Data.Map.Strict                         as Map
import           Serokell.Util.Verify                    (VerificationRes (..),
                                                          formatAllErrors, verifyGeneric)

import           Pos.Binary.Class                        (asBinary, serialize')
import           Pos.Binary.Core.Address                 ()
import           Pos.Core.Address                        (Address,
                                                          IsBootstrapEraAddr (..),
                                                          addressHash, deriveLvl2KeyPair,
                                                          makePubKeyAddressBoot)
import           Pos.Core.Coin                           (coinPortionToDouble, mkCoin,
                                                          unsafeIntegerToCoin)
import           Pos.Core.Configuration.BlockVersionData (HasGenesisBlockVersionData,
                                                          genesisBlockVersionData)
import           Pos.Core.Configuration.Protocol         (HasProtocolConstants, vssMaxTTL,
                                                          vssMinTTL)
import qualified Pos.Core.Genesis.Constants              as Const
import           Pos.Core.Genesis.Types                  (FakeAvvmOptions (..),
                                                          GenesisAvvmBalances (..),
                                                          GenesisInitializer (..),
                                                          GenesisNonAvvmBalances (..),
                                                          GenesisVssCertificatesMap (..),
                                                          GenesisWStakeholders (..),
                                                          TestnetBalanceOptions (..),
                                                          TestnetDistribution (..))
import           Pos.Core.Types                          (BlockVersionData (bvdMpcThd),
                                                          Coin)
import           Pos.Core.Vss                            (VssCertificate,
                                                          VssCertificatesMap,
                                                          mkVssCertificate)
import           Pos.Crypto                              (EncryptedSecretKey,
                                                          RedeemPublicKey, SecretKey,
                                                          VssKeyPair, deterministic,
                                                          emptyPassphrase, keyGen,
                                                          randomNumberInRange,
                                                          redeemDeterministicKeyGen,
                                                          safeKeyGen, toPublic,
                                                          toVssPublicKey, vssKeyGen)

-- | Data generated by @genTestnetOrMainnetData@ using genesis-spec.
data GeneratedGenesisData = GeneratedGenesisData
    { ggdNonAvvm          :: !GenesisNonAvvmBalances
    -- ^ Non-avvm balances
    , ggdAvvm             :: !GenesisAvvmBalances
    -- ^ Avvm balances
    , ggdBootStakeholders :: !GenesisWStakeholders
    -- ^ Set of boot stakeholders (richmen addresses or custom addresses)
    , ggdVssCerts         :: !GenesisVssCertificatesMap
    -- ^ Genesis vss data (vss certs of richmen)
    , ggdSecrets          :: !(Maybe GeneratedSecrets)
    }

data GeneratedSecrets = GeneratedSecrets
    { gsSecretKeys    :: ![(SecretKey, EncryptedSecretKey, VssKeyPair)]
    -- ^ Secret keys for non avvm addresses
    , gsFakeAvvmSeeds :: ![ByteString]
    -- ^ Fake avvm seeds (needed only for testnet)
    }

generateGenesisData
    :: (HasProtocolConstants, HasGenesisBlockVersionData)
    => GenesisInitializer
    -> Word64
    -> GeneratedGenesisData
generateGenesisData (TestnetInitializer{..}) maxTnBalance = deterministic (serialize' tiSeed) $ do
    let TestnetBalanceOptions{..} = tiTestBalance
    (fakeAvvmDistr, seeds, fakeAvvmBalance) <- generateFakeAvvmGenesis tiFakeAvvmBalance
    (richmenList, poorsList) <-
        (,) <$> replicateM (fromIntegral tboRichmen)
                           (generateSecretsAndAddress Nothing tboUseHDAddresses)
            <*> replicateM (fromIntegral tboPoors)
                           (generateSecretsAndAddress Nothing tboUseHDAddresses)

    let skVssCerts = map (\(sk, _, _, vc, _) -> (sk, vc)) $ richmenList ++ poorsList
        richSkVssCerts = take (fromIntegral tboRichmen) skVssCerts
        secretKeys = map (\(sk, hdwSk, vssSk, _, _) -> (sk, hdwSk, vssSk))
                         (richmenList ++ poorsList)

        safeZip s a b =
            if length a /= length b
            then error $ s <> " :lists differ in size, " <> show (length a) <>
                         " and " <> show (length b)
            else zip a b

        tnBalance = min maxTnBalance tboTotalBalance

        (richBs, poorBs) =
            genTestnetDistribution tiTestBalance (fromIntegral $ tnBalance - fakeAvvmBalance)
        -- ^ Rich and poor balances
        richAs = map (makePubKeyAddressBoot . toPublic . fst) richSkVssCerts
        -- ^ Rich addresses
        poorAs = map (view _5) poorsList
        -- ^ Poor addresses
        nonAvvmDistr = HM.fromList $ safeZip "rich" richAs richBs ++ safeZip "poor" poorAs poorBs

    let toStakeholders = Map.fromList . map ((,1) . addressHash . toPublic . fst)
    let toVss = HM.fromList . map (_1 %~ addressHash . toPublic)

    let (bootStakeholders, vssCerts) =
            case tiDistribution of
                TestnetRichmenStakeDistr    ->
                    (toStakeholders richSkVssCerts, GenesisVssCertificatesMap $ toVss richSkVssCerts)
                TestnetCustomStakeDistr{..} ->
                    (getGenesisWStakeholders tcsdBootStakeholders, tcsdVssCerts)

    pure $ GeneratedGenesisData
        { ggdNonAvvm = GenesisNonAvvmBalances nonAvvmDistr
        , ggdAvvm = fakeAvvmDistr
        , ggdBootStakeholders = GenesisWStakeholders bootStakeholders
        , ggdVssCerts = vssCerts
        , ggdSecrets = Just $ GeneratedSecrets
              { gsSecretKeys = secretKeys
              , gsFakeAvvmSeeds = seeds
              }
        }
generateGenesisData MainnetInitializer{..} _ =
    GeneratedGenesisData miNonAvvmBalances mempty miBootStakeholders miVssCerts Nothing

generateFakeAvvmGenesis
    :: (MonadRandom m)
    => FakeAvvmOptions -> m (GenesisAvvmBalances, [ByteString], Word64)
generateFakeAvvmGenesis FakeAvvmOptions{..} = do
    fakeAvvmPubkeysAndSeeds <- replicateM (fromIntegral faoCount) generateFakeAvvm
    let oneBalance = mkCoin $ fromIntegral faoOneBalance
        fakeAvvms = map ((,oneBalance) . fst) fakeAvvmPubkeysAndSeeds
    pure ( GenesisAvvmBalances $ HM.fromList fakeAvvms
         , map snd fakeAvvmPubkeysAndSeeds
         , faoOneBalance * fromIntegral faoCount)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

generateSecretsAndAddress
    :: (HasProtocolConstants, MonadRandom m)
    => Maybe (SecretKey, EncryptedSecretKey)  -- ^ plain key & hd wallet root key
    -> Bool                                   -- ^ whether address contains hd payload
    -> m (SecretKey, EncryptedSecretKey, VssKeyPair, VssCertificate, Address)
    -- ^ secret key, vss key pair, vss certificate,
    -- hd wallet account address with bootstrap era distribution
generateSecretsAndAddress mbSk hasHDPayload= do
    (sk, hdwSk, vss) <- generateSecrets mbSk

    expiry <- fromInteger <$>
        randomNumberInRange (vssMinTTL - 1) (vssMaxTTL - 1)
    let vssPk = asBinary $ toVssPublicKey vss
        vssCert = mkVssCertificate sk vssPk expiry
        -- This address is used only to create genesis data. We don't
        -- put it into a keyfile.
        hdwAccountPk =
            if not hasHDPayload then makePubKeyAddressBoot (toPublic sk)
            else
                fst $ fromMaybe (error "generateKeyfile: pass mismatch") $
                deriveLvl2KeyPair (IsBootstrapEraAddr True) emptyPassphrase hdwSk
                    Const.accountGenesisIndex Const.wAddressGenesisIndex
    pure (sk, hdwSk, vss, vssCert, hdwAccountPk)

generateFakeAvvm :: MonadRandom m => m (RedeemPublicKey, ByteString)
generateFakeAvvm = do
    seed <- getRandomBytes 32
    let (pk, _) = fromMaybe
            (error "Impossible - seed is not 32 bytes long") $
            redeemDeterministicKeyGen seed
    pure (pk, seed)

generateSecrets
    :: (MonadRandom m)
    => Maybe (SecretKey, EncryptedSecretKey)
    -> m (SecretKey, EncryptedSecretKey, VssKeyPair)
generateSecrets mbSk = do
    -- plain key & hd wallet root key
    (sk, hdwSk) <-
        case mbSk of
            Just x -> return x
            Nothing ->
                (,) <$> (snd <$> keyGen) <*>
                (snd <$> safeKeyGen emptyPassphrase)
    vss <- vssKeyGen
    pure (sk, hdwSk, vss)

-- | Generates balance distribution for testnet.
genTestnetDistribution ::
       HasGenesisBlockVersionData
    => TestnetBalanceOptions
    -> Integer
    -> ([Coin], [Coin])
genTestnetDistribution TestnetBalanceOptions{..} testBalance =
    checkConsistency (richBalances, poorBalances)
  where
    richs = fromIntegral tboRichmen
    poors = fromIntegral tboPoors

    -- Calculate actual balances
    desiredRichBalance = getShare tboRichmenShare testBalance
    oneRichmanBalance = desiredRichBalance `div` richs +
        if desiredRichBalance `mod` richs > 0 then 1 else 0
    realRichBalance = oneRichmanBalance * richs
    poorsBalance = testBalance - realRichBalance
    onePoorBalance = if poors == 0 then 0 else poorsBalance `div` poors
    realPoorBalance = onePoorBalance * poors

    mpcBalance = getShare (coinPortionToDouble $ bvdMpcThd genesisBlockVersionData) testBalance

    richBalances = replicate (fromInteger richs) (unsafeIntegerToCoin oneRichmanBalance)
    poorBalances = replicate (fromInteger poors) (unsafeIntegerToCoin onePoorBalance)

    -- Consistency checks
    everythingIsConsistent :: [(Bool, Text)]
    everythingIsConsistent =
        [ ( realRichBalance + realPoorBalance <= testBalance
          , "Real rich + poor balance is more than desired."
          )
        , ( oneRichmanBalance >= mpcBalance
          , "Richman's balance is less than MPC threshold"
          )
        , ( onePoorBalance < mpcBalance
          , "Poor's balance is more than MPC threshold"
          )
        ]

    checkConsistency :: a -> a
    checkConsistency = case verifyGeneric everythingIsConsistent of
        VerSuccess        -> identity
        VerFailure errors -> error $ formatAllErrors errors

    getShare :: Double -> Integer -> Integer
    getShare sh n = round $ sh * fromInteger n
