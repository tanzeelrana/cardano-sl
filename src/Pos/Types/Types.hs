{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies  #-}

-- | Definitions of the most fundamental types.

module Pos.Types.Types
       (
         NodeId (..)
       , nodeF

       , EpochIndex
       , LocalSlotIndex
       , SlotId (..)

       , Coin (..)
       , coinF

       , Address (..)
       , addressF

       , TxIn (..)
       , TxOut (..)
       , Tx (..)

       , BlockHeader (..)
       , SignedBlockHeader (..)
       , GenericBlock (..)
       , TxsPayload
       , TxsProof (..)
       , Block

       , Entry (..)
       , Blockkk
       , displayEntry
       ) where

import qualified Data.Text           as T (unwords)
import           Data.Text.Buildable (Buildable)
import qualified Data.Text.Buildable as Buildable
import           Data.Word           (Word32, Word64)
import           Formatting          (Format, bprint, build, int, sformat, shown, (%))
import           Universum

import           Pos.Crypto          (Encrypted, Hash, Share, Signature)
import           Pos.Util            (Raw)

----------------------------------------------------------------------------
-- Node. TODO: do we need it?
----------------------------------------------------------------------------

newtype NodeId = NodeId
    { getNodeId :: Int
    } deriving (Show, Eq, Ord, Enum)

instance Buildable NodeId where
    build = bprint ("#"%int) . getNodeId

nodeF :: Format r (NodeId -> r)
nodeF = build

----------------------------------------------------------------------------
-- Slotting
----------------------------------------------------------------------------

-- | Index of epoch.
type EpochIndex = Word64

-- | Index of slot inside a concrete epoch.
type LocalSlotIndex = Word32

-- | Slot is identified by index of epoch and local index of slot in
-- this epoch. This is a global index
data SlotId = SlotId
    { siEpoch :: !EpochIndex
    , siSlot  :: !LocalSlotIndex
    } deriving (Show, Eq, Generic)

----------------------------------------------------------------------------
-- Coin
----------------------------------------------------------------------------

-- | Coin is the least possible unit of currency.
newtype Coin = Coin
    { getCoin :: Int64
    } deriving (Num, Enum, Integral, Show, Ord, Real, Generic, Eq)

instance Buildable Coin where
    build = bprint (int%" coin(s)")

-- | Coin formatter which restricts type.
coinF :: Format r (Coin -> r)
coinF = build

----------------------------------------------------------------------------
-- Address
----------------------------------------------------------------------------

instance Buildable () where
    build () = "patak"  -- TODO: remove

-- | Address is where you can send coins.
newtype Address = Address
    { getAddress :: ()  -- ^ TODO
    } deriving (Show, Eq, Generic, Buildable, Ord)

addressF :: Format r (Address -> r)
addressF = build

----------------------------------------------------------------------------
-- Transaction
----------------------------------------------------------------------------

-- | Transaction input.
data TxIn = TxIn
    { txInHash  :: !(Hash Tx)  -- ^ Which transaction's output is used
    , txInIndex :: !Word32     -- ^ Index of the output in transaction's
                               -- outputs
    } deriving (Eq, Ord, Show, Generic)

-- | Transaction output.
data TxOut = TxOut
    { txOutAddress :: !Address
    , txOutValue   :: !Coin
    } deriving (Eq, Ord, Show, Generic)

-- | Transaction.
data Tx = Tx
    { txInputs  :: ![TxIn]   -- ^ Inputs of transaction.
    , txOutputs :: ![TxOut]  -- ^ Outputs of transaction.
    } deriving (Eq, Ord, Show, Generic)

----------------------------------------------------------------------------
-- Block
----------------------------------------------------------------------------

type family Proof payload :: *

-- | Header of block contains all the information necessary to
-- validate consensus algorithm. It also contains proof of payload
-- associated with it.
-- TODO: should we put public key here?
data BlockHeader proof = BlockHeader
    { bhPrevHash     :: !(Hash (BlockHeader proof))  -- ^ Hash of the previous
                                             -- block's header.
    , bhPayloadProof :: !proof               -- ^ Proof of payload.
    , bhSlot         :: !SlotId              -- ^ Id of slot for which
                                             -- block was generated.
    } deriving (Show, Eq, Generic)

-- | SignedBlockHeader consists of BlockHeader and its signature.
-- TODO: or maybe we should put public key here?
data SignedBlockHeader proof = SignedBlockHeader
    { sbhHeader    :: !(BlockHeader proof)
    , sbhSignature :: !(Signature (BlockHeader proof))
    } deriving (Show, Eq, Generic)

-- | In general Block consists of some payload and header associated
-- with it.
data GenericBlock payload = GenericBlock
    { gbHeader  :: !(SignedBlockHeader (Proof payload))
    , gbPayload :: !payload
    } deriving (Generic)

-- | In our crypto-currency payload is a list of transactions.
type TxsPayload = [Tx]

-- | Proof of transactions list.
data TxsProof = TxsProof
    { tpNumber :: !Word32  -- ^ Number of transactions.
    , tpRoot   :: !()      -- ^ TODO: it should be root of Merkle tree.
    } deriving (Show, Eq, Generic)

type instance Proof TxsPayload = TxsProof

type Block = GenericBlock TxsPayload

----------------------------------------------------------------------------
-- Block. Leftover.
----------------------------------------------------------------------------

-- | An entry in a block
data Entry

      -- | Transaction
    = ETx Tx

      -- | Hash of random string U that a node has committed to
    | EUHash NodeId (Hash Raw)
      -- | An encrypted piece of secret-shared U that the first node sent to
      -- the second node (and encrypted with the second node's pubkey)
    | EUShare NodeId NodeId (Encrypted Share)
      -- | Leaders for a specific epoch
    | ELeaders Int [NodeId]

    deriving (Eq, Ord, Show)

-- | Block
type Blockkk = [Entry]

displayEntry :: Entry -> Text
displayEntry (ETx tx) =
    "transaction " <> show tx
displayEntry (EUHash nid h) =
    sformat (nodeF%"'s commitment = "%shown) nid h
displayEntry (EUShare n_from n_to share) =
    sformat (nodeF%"'s share for "%nodeF%" = "%build) n_from n_to share
displayEntry (ELeaders epoch leaders) =
    sformat ("leaders for epoch "%int%" = "%build)
            epoch
            (T.unwords (map (toS . sformat nodeF) leaders))
