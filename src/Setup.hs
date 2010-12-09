

import Data.List

import Control.Applicative
import Control.Monad

import System.Directory
import System.FilePath
import System.Info
import System.Process

import Distribution.Simple
import Distribution.MacOSX


main =
  case os of
    "darwin" -> defaultMainWithHooks =<< macDeploymentHooks
    _ -> defaultMain

macDeploymentHooks :: IO UserHooks
macDeploymentHooks = do
    -- this is a hack to convince cabal-macosx not to flatten the resource files
    e <- doesDirectoryExist "resources"
    when (not e) $ do
        system "ln -s ../data resources"
        return ()
    resourceFiles <- getFilesRecursive "resources"
    return $ simpleUserHooks{postBuild = appBundleBuildHook [(macApp resourceFiles)]}

-- | deployment on a mac
macApp :: [FilePath] -> MacApp
macApp resourceFiles = MacApp {
    appName = "Nikki",
    appIcon = Just "../data/png/icon-128.png",
    appPlist = Nothing,
    resources = resourceFiles,
    otherBins = [],
    appDeps = DoNotChase -- ChaseWithDefaults
  }

-- | returns all (unhidden) files in a directory recursively,
-- excluding all directories
getFilesRecursive :: FilePath -> IO [FilePath]
getFilesRecursive dir = do
    content <- filter (not . ("." `isPrefixOf`)) <$> getDirectoryContents dir
    let here = map (dir </>) content
    files <- filterM (\ p -> not <$> doesDirectoryExist p) here
    directories <- filterM doesDirectoryExist here
    recursive <- mapM getFilesRecursive directories
    return $ sort (files ++ concat recursive)
