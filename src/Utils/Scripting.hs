
-- | scripting stuff

module Utils.Scripting where


import Safe

import Data.List

import Control.Arrow
import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Exception

import System.FilePath
import System.Directory
import System.Exit
import System.Process
import System.Info


logInfo :: String -> IO ()
logInfo msg =
    if System.Info.os == "mingw32" then
        return ()
      else do
        putStrLn "WARNING: logInfo not implemented on windows"
        putStrLn ("INFO: " ++ msg)


-- | executes a unix command on the shell and exits if it does not succeed.
trySystem :: String -> IO ()
trySystem cmd = do
    logInfo ("Executing \"" ++ cmd ++ "\" ...")
    exitcode <- system cmd
    case exitcode of
        ExitSuccess -> return ()
        ExitFailure n -> exitWith $ ExitFailure n

-- | changes the working directory temporarily.
withCurrentDirectory :: FilePath -> IO () -> IO ()
withCurrentDirectory path cmd = do
    bracket first finish (const cmd)
  where
    first = do
        oldWorkingDirectory <- getCurrentDirectory
        setCurrentDirectory path
        return oldWorkingDirectory
    finish = setCurrentDirectory

-- | copy a whole directory recursively
-- excluding hidden files
-- give full paths to both directories, e.g. (copyDirectory "src/dir" "dest/dir")
copyDirectory :: FilePath -> FilePath -> IO ()
copyDirectory src dst = do
    allFiles <- getFilesRecursive src
    forM_ allFiles copy
  where
    copy file = do
        createDirectoryIfMissing True (takeDirectory (dst </> file))
        copyFile (src </> file) (dst </> file)

-- | returns all (unhidden) files in a directory recursively, sorted.
-- Omits the directories.
getFilesRecursive :: FilePath -> IO [FilePath]
getFilesRecursive root =
    map normalise <$> inner "."
  where
    inner dir = do
        content <- map (dir </>) <$> sort <$> getFiles (root </> dir) Nothing
        (directories, files) <- partitionM (doesDirectoryExist . (root </>)) content
        recursive <- mapM inner $ directories
        return $ sort (files ++ concat recursive)

partitionM :: (a -> IO Bool) -> [a] -> IO ([a], [a])
partitionM p (a : r) = do
    condition <- p a
    (yes, no) <- partitionM p r
    return $ if condition then
        (a : yes, no)
      else
        (yes, a : no)
partitionM _ [] = return ([], [])

-- | removes file and directories if they exist
removeIfExists :: FilePath -> IO ()
removeIfExists f = liftIO $ do
    isFile <- doesFileExist f
    isDirectory <- doesDirectoryExist f
    when (isFile || isDirectory) $
        logInfo ("removing: " ++ f)
    if isFile then
        removeFile f
      else if isDirectory then
        removeDirectoryRecursive f
      else
        return ()

-- | Returns all files and directories in a given directory, sorted.
-- Omit "." and "..".
getDirectoryRealContents :: FilePath -> IO [FilePath]
getDirectoryRealContents path =
    liftIO $ sort <$> filter isContent <$> getDirectoryContents path
  where
    isContent "." = False
    isContent ".." = False
    isContent _ = True

-- | Returns if a path starts with a dot.
isHiddenOnUnix :: FilePath -> Bool
isHiddenOnUnix = headMay >>> (== Just '.')

-- | Returns all unhidden (unix) files in a given directory.
-- @getFiles dir (Just extension)@ returns all files with the given extension.
getFiles :: FilePath -> Maybe String -> IO [FilePath]
getFiles dir mExtension =
    sort <$> filter hasRightExtension <$> filter (not . isHiddenOnUnix) <$>
        getDirectoryRealContents dir
  where
    hasRightExtension :: FilePath -> Bool
    hasRightExtension = case mExtension of
        (Just ('.' : '.' : r)) -> error ("don't give extensions that start with two dots: " ++ r)
        (Just extension@('.' : _)) -> takeExtension >>> (== extension)
        (Just extension) -> takeExtension >>> (== ('.' : extension))
        Nothing -> const True