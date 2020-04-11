{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module GoPro.DB (storeMedia, loadMediaIDs, loadMedia, loadThumbnail,
                 MediaRow(..), row_media, row_thumbnail,
                 storeMoments, loadMoments, momentsTODO,
                 metaBlobTODO, insertMetaBlob, selectMetaBlob, clearMetaBlob,
                 metaTODO, insertMeta, selectMeta,
                 Area(..), area_id, area_name, area_nw, area_se, selectAreas,
                 HasGoProDB(..),
                 initTables) where

import           Control.Applicative              (liftA2)
import           Control.Lens
import           Control.Monad.IO.Class           (MonadIO (..))
import           Data.Aeson                       (FromJSON (..), ToJSON (..),
                                                   defaultOptions,
                                                   fieldLabelModifier,
                                                   genericToEncoding)
import qualified Data.Aeson                       as J
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Lazy             as BL
import           Data.Coerce                      (coerce)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (fromJust)
import qualified Data.Text.Encoding               as TE
import           Data.Typeable                    (Typeable)
import           Database.SQLite.Simple           hiding (bind, close)
import           Database.SQLite.Simple.FromField
import           Database.SQLite.Simple.Ok
import           Database.SQLite.Simple.ToField
import           Generics.Deriving.Base           (Generic)
import           Text.RawString.QQ                (r)

import           GoPro.Plus.Media                 (Medium (..), MediumID,
                                                   MediumType (..), Moment (..),
                                                   ReadyToViewType (..))
import           GoPro.Resolve                    (MDSummary (..))

class Monad m => HasGoProDB m where
  goproDB :: m Connection

initTables :: Connection -> IO ()
initTables db = mapM_ (execute_ db)
                [[r|create table if not exists media (media_id primary key, camera_model,
                                                      captured_at, created_at, file_size,
                                                      moments_count, source_duration,
                                                      media_type, width, height,
                                                      ready_to_view, thumbnail)|],
                 [r|create table if not exists
                           meta (media_id primary key, camera_model, captured_at,
                                 lat, lon, max_speed_2d, max_speed_3d, max_faces, main_scene, main_scene_prob)|],
                 "create table if not exists metablob (media_id primary key, meta blob, format text, backedup boolean)",
                 [r|create table if not exists areas (area_id integer primary key autoincrement,
                                                      name text,
                                                      lat1 real, lon1 real,
                                                      lat2 real, lon2 real)|],
                 "create table if not exists moments (media_id, moment_id integer, timestamp integer)",
                 "create index if not exists moments_by_medium on moments(media_id)"]

upsertMediaStatement :: Query
upsertMediaStatement = [r|insert into media (media_id, camera_model, captured_at, created_at,
                                             file_size, moments_count, source_duration, media_type,
                                             width, height, ready_to_view, thumbnail)
                                      values(?,?,?,?,?,?,?,?,?,?,?,?)
                            on conflict (media_id)
                               do update
                                 set moments_count = excluded.moments_count,
                                     ready_to_view = excluded.ready_to_view
                              |]

data MediaRow = MediaRow {
  _row_media     :: Medium,
  _row_thumbnail :: BL.ByteString
  }

makeLenses ''MediaRow

jsonToField :: ToJSON a => a -> SQLData
jsonToField v = case toJSON v of
                  J.String x -> SQLText x
                  e          -> error ("wtf is " <> show e)

instance ToField ReadyToViewType where
  toField = jsonToField

instance ToField MediumType where
  toField = jsonToField

jsonFromField :: (Typeable j, FromJSON j) => String -> Field -> Ok j
jsonFromField lbl f =
  case fieldData f of
    (SQLText t) -> Ok . fromJust . J.decode . BL.fromStrict . TE.encodeUtf8 $ ("\"" <> t <> "\"")
    _ -> returnError ConversionFailed f ("invalid type for " <>  lbl)

instance FromField ReadyToViewType where
  fromField = jsonFromField "ready to view"

instance FromField MediumType where
  fromField = jsonFromField "medium type"

instance ToRow MediaRow where
  toRow (MediaRow Medium{..} thumbnail) = [
    toField _medium_id,
    toField _medium_camera_model,
    toField _medium_captured_at,
    toField _medium_created_at,
    toField _medium_file_size,
    toField _medium_moments_count,
    toField _medium_source_duration,
    toField _medium_type,
    toField _medium_width,
    toField _medium_height,
    toField _medium_ready_to_view,
    toField thumbnail
    ]

storeMedia :: (HasGoProDB m, MonadIO m) => [MediaRow] -> m ()
storeMedia media = liftIO . up =<< goproDB
  where up db = executeMany db upsertMediaStatement media

loadMediaIDs :: (HasGoProDB m, MonadIO m) => m [MediumID]
loadMediaIDs = coerce <$> (liftIO . sel =<< goproDB)
  where
    sel :: Connection -> IO [Only MediumID]
    sel db = query_ db "select media_id from media order by captured_at desc"

selectMediaStatement :: Query
selectMediaStatement = [r|select media_id,
                                 camera_model,
                                 captured_at,
                                 created_at,
                                 file_size,
                                 moments_count,
                                 ready_to_view,
                                 source_duration,
                                 media_type,
                                 width,
                                 height
                             from media
                             order by captured_at desc|]

instance FromRow Medium where
  fromRow =
    Medium <$> field -- medium_id
    <*> field -- _medium_camera_model
    <*> field -- _medium_captured_at
    <*> field -- _medium_created_at
    <*> field -- _medium_file_size
    <*> field -- _medium_moments_count
    <*> field -- _medium_ready_to_view
    <*> field -- _medium_source_duration
    <*> field -- _medium_type
    <*> pure "" -- _medium_token
    <*> field -- _medium_width
    <*> field -- _medium_height

loadMedia :: (HasGoProDB m, MonadIO m) => m [Medium]
loadMedia = goproDB >>= \db -> liftIO $ query_ db selectMediaStatement

loadThumbnail :: (HasGoProDB m, MonadIO m) => MediumID -> m BL.ByteString
loadThumbnail imgid = liftIO . sel =<< goproDB
  where
    sel db = do
      [Only t] <- query db "select thumbnail from media where media_id = ?" (Only imgid)
      pure t

metaBlobTODO :: (HasGoProDB m, MonadIO m) => m [(MediumID, String)]
metaBlobTODO = liftIO . sel =<< goproDB
  where
    sel db = query_ db [r|select media_id, media_type
                         from media
                         where media_id not in (select media_id from metablob)
                         order by created_at desc|]

insertMetaBlob :: (HasGoProDB m, MonadIO m) => MediumID -> String -> Maybe BS.ByteString -> m ()
insertMetaBlob mid fmt blob = liftIO . ins =<< goproDB
  where ins db = execute db "insert into metablob (media_id, meta, format) values (?, ?, ?)" (mid, blob, fmt)

metaTODO :: (HasGoProDB m, MonadIO m) => m [(MediumID, String, BS.ByteString)]
metaTODO = liftIO . sel =<< goproDB
  where
    sel db = query_ db [r|
                         select b.media_id, b.format, b.meta
                         from metablob b join media m on (m.media_id = b.media_id)
                         where b.meta is not null
                               and b.media_id not in (select media_id from meta)
                         |]

selectMetaBlob :: (HasGoProDB m, MonadIO m) => m [(MediumID, BS.ByteString)]
selectMetaBlob = liftIO . sel =<< goproDB
  where sel db = query_ db "select media_id, meta from metablob where meta is not null"

clearMetaBlob :: (HasGoProDB m, MonadIO m) => [MediumID] -> m ()
clearMetaBlob ms = liftIO . up =<< goproDB
  where up db = executeMany db "update metablob set meta = null, backedup = true where media_id = ?" [Only m | m <- ms]

insertMeta :: (HasGoProDB m, MonadIO m) => MediumID -> MDSummary -> m ()
insertMeta mid MDSummary{..} = liftIO . up =<< goproDB
  where
    q = [r|
          insert into meta (media_id, camera_model, captured_at, lat, lon,
                            max_speed_2d, max_speed_3d, max_faces,
                            main_scene, main_scene_prob)
                      values (:mid, :cam, :ts, :lat, :lon,
                              :speed2, :speed3, :maxface,
                              :scene, :scene_prob)
          |]
    up db = executeNamed db q
      [":cam" := _cameraModel,
       ":ts" := _capturedTime,
       ":lat" := _lat,
       ":lon" := _lon,
       ":speed2" := _maxSpeed2d,
       ":speed3" := _maxSpeed3d,
       ":maxface" := _maxFaces,
       ":scene" := (show . fst <$> _mainScene),
       ":scene_prob" := (snd <$> _mainScene),
       ":mid" := mid]

newtype NamedSummary = NamedSummary (MediumID, MDSummary)

instance FromRow NamedSummary where
  fromRow = do
    mid <- field
    _cameraModel <- field
    _capturedTime <- field
    _lat <- field
    _lon <- field
    _maxSpeed2d <- field
    _maxSpeed3d <- field
    _maxFaces <- field
    loc <- fmap read <$> field
    prob <- field
    let _mainScene = liftA2 (,) loc prob
    pure $ NamedSummary (mid, MDSummary{..})

selectMeta :: (HasGoProDB m, MonadIO m) => m (Map MediumID MDSummary)
selectMeta = goproDB >>= \db ->  Map.fromList . coerce <$> liftIO (sel db)
  where
    sel :: Connection -> IO [NamedSummary]
    sel db = query_ db [r|select media_id, camera_model, captured_at, lat, lon,
                              max_speed_2d, max_speed_3d,
                              max_faces, main_scene, main_scene_prob
                          from meta
                          where camera_model is not null |]

data Area = Area {
  _area_id   :: Int,
  _area_name :: String,
  _area_nw   :: (Double, Double),
  _area_se   :: (Double, Double)
  } deriving (Generic, Show)

makeLenses ''Area

instance FromRow Area where
  fromRow = do
    _area_id <- field
    _area_name <- field
    _area_nw <- liftA2 (,) field field
    _area_se <- liftA2 (,) field field
    pure Area{..}

instance ToJSON Area where
  toEncoding = genericToEncoding defaultOptions { fieldLabelModifier = drop 6}

selectAreas :: (HasGoProDB m, MonadIO m) => m [Area]
selectAreas = liftIO . sel =<< goproDB
  where
    sel db = query_ db "select area_id, name, lat1, lon1, lat2, lon2 from areas"

storeMoments :: (HasGoProDB m, MonadIO m) => MediumID -> [Moment] -> m ()
storeMoments mid ms = liftIO . up =<< goproDB
  where
    up db = do
      execute db "delete from moments where media_id = ?" (Only mid)
      let vals = [(mid, _moment_id, _moment_time) | Moment{..} <- ms]
      executeMany db "insert into moments (media_id, moment_id, timestamp) values (?,?,?)" vals

loadMoments :: (HasGoProDB m, MonadIO m) => m (Map MediumID [Moment])
loadMoments = goproDB >>= \db -> Map.fromListWith (<>) . map (\(a,b,c) -> (a,[Moment b c])) <$> liftIO (sel db)
  where sel db = query_ db "select media_id, moment_id, timestamp from moments"

momentsTODO :: (HasGoProDB m, MonadIO m) => m [MediumID]
momentsTODO = liftIO . coerce . sel =<< goproDB
  where
    sel :: Connection -> IO [Only MediumID]
    sel db = query_ db [r|
                         select m.media_id from media m left outer join
                           (select media_id, count(*) as moco from moments group by media_id) as mo
                           on (m. media_id = mo.media_id)
                          where m.moments_count != ifnull(moco, 0) ;
                         |]
