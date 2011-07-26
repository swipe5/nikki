
module Base.Sound (
    loadSound,
    withApplicationSounds,
    triggerSound,

    -- * re-exports
    Sound.SFML.PolySound,
    Sound.SFML.freePolySound,
  ) where


import Control.Monad.CatchIO
import Control.Monad.IO.Class

import System.FilePath

import Sound.SFML

import Utils

import Base.Types
import Base.Paths
import Base.Constants


withApplicationSounds :: (ApplicationSounds -> RM a) -> RM a
withApplicationSounds =
    bracket load (io . free)
  where
    load :: RM ApplicationSounds
    load = ApplicationSounds
        <$> loadSound "menu/select" 2
        <*> loadSound "menu/confirm" 2
        <*> loadSound "menu/cancel" 2
        <*> loadSound "menu/error" 2
    free (ApplicationSounds a b c d) =
        forM_ [a, b, c, d] freePolySound


loadSound :: String -> Int -> RM PolySound
loadSound name n = do
    file <- getDataFileName (soundDir </> name <.> "wav")
    io $ newPolySound file n

triggerSound :: MonadIO m => PolySound -> m ()
triggerSound = io . triggerPolySound
