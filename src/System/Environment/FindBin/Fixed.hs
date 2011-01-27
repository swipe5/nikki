{-# language ForeignFunctionInterface, ScopedTypeVariables #-}

-- | works around a bug in FindBin affecting linux.

module System.Environment.FindBin.Fixed where


import System.Info
import System.FilePath
import System.Directory
import System.Environment
import qualified System.Environment.FindBin

import Foreign.Ptr
import Foreign.C.Types
import Foreign.C.String
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Storable

import Utils


getProgPath :: IO FilePath
getProgPath = case System.Info.os of
    "linux" -> do
        dir <- getCurrentDirectory
        prog <- getProgName
        (fullProgName : _) <- wrap getFullProgArgv
        takeDirectory <$> canonicalizePath (dir </> fullProgName)
    _ -> System.Environment.FindBin.getProgPath

wrap :: (Ptr CInt -> Ptr (Ptr CString) -> IO ()) -> IO [String]
wrap action = alloca $ \ argcPtr -> alloca $ \ argvArrayPtr -> do
    action argcPtr argvArrayPtr
    argc <- peek argcPtr
    argvArray <- peek argvArrayPtr
    argv :: [CString] <- peekArray (fromIntegral argc) argvArray
    mapM peekCString argv

foreign import ccall unsafe "getFullProgArgv"
  getFullProgArgv :: Ptr CInt -> Ptr (Ptr CString) -> IO ()

foreign import ccall unsafe "getProgArgv"
  getProgArgv :: Ptr CInt -> Ptr (Ptr CString) -> IO ()
