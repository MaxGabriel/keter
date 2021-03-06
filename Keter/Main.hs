{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Keter.Main
    ( keter
    ) where

import qualified Codec.Archive.TempTarball as TempFolder
import           Control.Concurrent.Async  (waitAny, withAsync)
import           Control.Monad             (unless)
import qualified Data.Conduit.LogFile      as LogFile
import           Data.Monoid               (mempty)
import qualified Data.Vector               as V
import           Keter.App                 (AppStartConfig (..))
import qualified Keter.AppManager          as AppMan
import qualified Keter.HostManager         as HostMan
import qualified Keter.PortPool            as PortPool
import qualified Keter.Proxy               as Proxy
import           Keter.Types
import           System.Posix.Files        (getFileStatus, modificationTime)
import           System.Posix.Signals      (Handler (Catch), installHandler,
                                            sigHUP)

import           Control.Applicative       ((<$>))
import           Control.Exception         (throwIO, try)
import           Control.Monad             (forM)
import           Data.Conduit.Process.Unix (initProcessTracker)
import qualified Data.Map                  as Map
import qualified Data.Text                 as T
import           Data.Text.Encoding        (encodeUtf8)
import qualified Data.Text.Read
import           Data.Time                 (getCurrentTime)
import           Data.Yaml.FilePath
import qualified Filesystem                as F
import qualified Filesystem.Path.CurrentOS as F
import Filesystem.Path.CurrentOS ((</>), hasExtension)
import qualified Network.HTTP.Conduit      as HTTP (newManager, conduitManagerSettings)
import qualified System.FSNotify           as FSN
import           System.Posix.User         (getUserEntryForID,
                                            getUserEntryForName, userGroupID,
                                            userID, userName)
import Control.Monad (void, when)
import Data.Default (def)
import Prelude hiding (FilePath, log)
import Filesystem (listDirectory, createTree)

keter :: FilePath -- ^ root directory or config file
      -> [FilePath -> IO Plugin]
      -> IO ()
keter input mkPlugins = withManagers input mkPlugins $ \kc hostman appMan log -> do
    launchInitial kc appMan
    startWatching kc appMan log
    startListening kc hostman

-- | Load up Keter config.
withConfig :: FilePath
           -> (KeterConfig -> IO a)
           -> IO a
withConfig input f = do
    exists <- F.isFile input
    config <-
        if exists
            then do
                eres <- decodeFileRelative input
                case eres of
                    Left e -> throwIO $ InvalidKeterConfigFile input e
                    Right x -> return x
            else return def { kconfigDir = input }
    f config

withLogger :: FilePath
           -> (KeterConfig -> (LogMessage -> IO ()) -> IO a)
           -> IO a
withLogger fp f = withConfig fp $ \config -> do
    mainlog <- LogFile.openRotatingLog
        (F.encodeString $ (kconfigDir config) </> "log" </> "keter")
        LogFile.defaultMaxTotal

    f config $ \ml -> do
        now <- getCurrentTime
        let bs = encodeUtf8 $ T.pack $ concat
                [ take 22 $ show now
                , ": "
                , show ml
                , "\n"
                ]
        LogFile.addChunk mainlog bs

withManagers :: FilePath
             -> [FilePath -> IO Plugin]
             -> (KeterConfig -> HostMan.HostManager -> AppMan.AppManager -> (LogMessage -> IO ()) -> IO a)
             -> IO a
withManagers input mkPlugins f = withLogger input $ \kc@KeterConfig {..} log -> do
    processTracker <- initProcessTracker
    hostman <- HostMan.start
    portpool <- PortPool.start kconfigPortPool
    tf <- TempFolder.setup $ kconfigDir </> "temp"
    plugins <- sequence $ map ($ kconfigDir) mkPlugins
    muid <-
        case kconfigSetuid of
            Nothing -> return Nothing
            Just t -> do
                x <- try $
                    case Data.Text.Read.decimal t of
                        Right (i, "") -> getUserEntryForID i
                        _ -> getUserEntryForName $ T.unpack t
                case x of
                    Left (_ :: SomeException) -> error $ "Invalid user ID: " ++ T.unpack t
                    Right ue -> return $ Just (T.pack $ userName ue, (userID ue, userGroupID ue))

    let appStartConfig = AppStartConfig
            { ascTempFolder = tf
            , ascSetuid = muid
            , ascProcessTracker = processTracker
            , ascHostManager = hostman
            , ascPortPool = portpool
            , ascPlugins = plugins
            , ascLog = log
            , ascKeterConfig = kc
            }
    appMan <- AppMan.initialize log appStartConfig
    f kc hostman appMan log

launchInitial :: KeterConfig -> AppMan.AppManager -> IO ()
launchInitial kc@KeterConfig {..} appMan = do
    createTree incoming
    bundles0 <- fmap (filter isKeter) $ listDirectory incoming
    mapM_ (AppMan.addApp appMan) bundles0

    unless (V.null kconfigBuiltinStanzas) $ AppMan.perform
        appMan
        AIBuiltin
        (AppMan.Reload $ AIData $ BundleConfig kconfigBuiltinStanzas mempty)
  where
    incoming = getIncoming kc

getIncoming :: KeterConfig -> FilePath
getIncoming kc = kconfigDir kc </> "incoming"

isKeter :: FilePath -> Bool
isKeter fp = hasExtension fp "keter"

startWatching :: KeterConfig -> AppMan.AppManager -> (LogMessage -> IO ()) -> IO ()
startWatching kc@KeterConfig {..} appMan log = do
    -- File system watching
    wm <- FSN.startManager
    FSN.watchDir wm incoming (const True) $ \e -> do
        e' <-
            case e of
                FSN.Removed fp _ -> do
                    log $ WatchedFile "removed" fp
                    return $ Left fp
                FSN.Added fp _ -> do
                    log $ WatchedFile "added" fp
                    return $ Right fp
                FSN.Modified fp _ -> do
                    log $ WatchedFile "modified" fp
                    return $ Right fp
        case e' of
            Left fp -> when (isKeter fp) $ AppMan.terminateApp appMan $ getAppname fp
            Right fp -> when (isKeter fp) $ AppMan.addApp appMan $ incoming </> fp

    -- Install HUP handler for cases when inotify cannot be used.
    void $ flip (installHandler sigHUP) Nothing $ Catch $ do
        bundles <- fmap (filter isKeter) $ F.listDirectory incoming
        newMap <- fmap Map.fromList $ forM bundles $ \bundle -> do
            time <- modificationTime <$> getFileStatus (F.encodeString bundle)
            return (getAppname bundle, (bundle, time))
        AppMan.reloadAppList appMan newMap
  where
    incoming = getIncoming kc

startListening :: KeterConfig -> HostMan.HostManager -> IO ()
startListening KeterConfig {..} hostman = do
    manager <- HTTP.newManager HTTP.conduitManagerSettings
    runAndBlock kconfigListeners $ Proxy.reverseProxy
        kconfigIpFromHeader
        manager
        (HostMan.lookupAction hostman)

runAndBlock :: NonEmptyVector a
            -> (a -> IO ())
            -> IO ()
runAndBlock (NonEmptyVector x0 v) f =
    loop l0 []
  where
    l0 = x0 : V.toList v

    loop (x:xs) asyncs = withAsync (f x) $ \async -> loop xs $ async : asyncs
    -- Once we have all of our asyncs, we wait for /any/ of them to exit. If
    -- any listener thread exits, we kill the whole process.
    loop [] asyncs = void $ waitAny asyncs
