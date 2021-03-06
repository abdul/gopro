module GoPro.S3 where

import           Codec.Compression.GZip       (compress)
import           Control.Lens
import           Control.Monad                (void)
import           Control.Monad.Catch          (MonadCatch (..))
import           Control.Monad.Reader         (asks)
import           Control.Monad.Trans.AWS      (AWST', Credentials (..), Region (..), envRegion, newEnv, paginate,
                                               runAWST, runResourceT, send, sinkBody)
import           Control.Monad.Trans.Resource (ResourceT)
import qualified Data.ByteString.Lazy         as BL
import           Data.Conduit                 (runConduit, (.|))
import qualified Data.Conduit.Binary          as CB
import qualified Data.Conduit.List            as CL
import           Data.Conduit.Zlib            (ungzip)
import           Data.String                  (fromString)
import           Data.Text                    (Text, isSuffixOf, pack, unpack)
import           Network.AWS.Data.Body        (RqBody (..), ToHashedBody (..))
import qualified Network.AWS.Env              as AWSE
import           Network.AWS.S3
import           System.FilePath.Posix        (takeBaseName, takeDirectory)
import           UnliftIO                     (MonadUnliftIO (..))

import           GoPro.Commands
import           GoPro.Plus.Media

type Derivative = (MediumID, Text)

inAWS :: (MonadCatch m, MonadUnliftIO m) => Region -> AWST' AWSE.Env (ResourceT m) a -> m a
inAWS r a = (newEnv Discover <&> set envRegion r) >>= \awsenv -> (runResourceT . runAWST awsenv) a

s3Bucket :: GoPro BucketName
s3Bucket = do
  b <- asks (BucketName . configItem "bucket")
  if b == "" then fail "s3 bucket is not configured" else pure b

allDerivatives :: GoPro [Derivative]
allDerivatives = s3Bucket >>= \b -> inAWS Oregon $
  runConduit $ paginate (listObjectsV2 b & lovPrefix ?~ "derivatives/")
    .| CL.concatMap (view lovrsContents)
    .| CL.map (view (oKey . _ObjectKey))
    .| CL.filter (not . ("/" `isSuffixOf`))
    .| CL.map toDir
    .| CL.consume

  where toDir t = let s = unpack t in
                    (pack . takeBaseName . takeDirectory $ s, pack $ takeBaseName s)

getMetaBlob :: MediumID -> GoPro BL.ByteString
getMetaBlob mid = do
  b <- s3Bucket
  let key = fromString $ "metablob/" <> unpack mid <> ".gz"
  logDbgL ["Requesting metablob from S3: ", tshow key]
  inAWS Oregon $ do
    rs <- send (getObject b key)
    (rs ^. gorsBody) `sinkBody` (ungzip .| CB.sinkLbs)

storeMetaBlob :: MediumID -> BL.ByteString -> GoPro ()
storeMetaBlob mid blob = do
  b <- s3Bucket
  let key = fromString $ "metablob/" <> unpack mid <> ".gz"
  logInfoL ["Storing metadata blob at ", tshow key]
  inAWS Oregon $ void . send $ putObject b key (Hashed . toHashed . compress $ blob)

listMetaBlobs :: GoPro [MediumID]
listMetaBlobs = s3Bucket >>= \b -> inAWS Oregon $
  runConduit $ paginate (listObjectsV2 b & lovPrefix ?~ "metablob/")
    .| CL.concatMap (view lovrsContents)
    .| CL.map (view (oKey . _ObjectKey))
    .| CL.filter (".gz" `isSuffixOf`)
    .| CL.map (pack . takeBaseName . unpack)
    .| CL.consume
