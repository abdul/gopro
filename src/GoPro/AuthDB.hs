{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module GoPro.AuthDB (updateAuth, loadAuth) where

import           Control.Monad          (guard)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Text              (Text)
import           Database.SQLite.Simple hiding (bind, close)

import           GoPro.Plus.Auth        (AuthInfo (..))

createStatement :: Query
createStatement = "create table if not exists authinfo (ts, owner_id, access_token, refresh_token, expires_in)"

insertStatement :: Query
insertStatement = "insert into authinfo(ts, owner_id, access_token, refresh_token, expires_in) values(current_timestamp, ?, ?, ?, ?)"

deleteStatement :: Query
deleteStatement = "delete from authinfo"

selectStatement :: Query
selectStatement = "select owner_id, access_token, refresh_token, expires_in from authinfo"

updateAuth :: MonadIO m => Connection -> AuthInfo -> m ()
updateAuth db AuthInfo{..} = liftIO up
  where up = do
          execute_ db createStatement
          withTransaction db $ do
            execute_ db deleteStatement
            execute db insertStatement (_resource_owner_id, _access_token, _refresh_token, _expires_in)

loadAuth :: MonadIO m => Connection -> m AuthInfo
loadAuth db = liftIO up
  where up = do
          rows <- query_ db selectStatement :: IO [(Text, Text, Text, Int)]
          guard (length rows == 1)
          let [(_resource_owner_id, _access_token, _refresh_token, _expires_in)] = rows
          pure $ AuthInfo{..}
