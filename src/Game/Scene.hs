{-# language NamedFieldPuns, ScopedTypeVariables, ViewPatterns #-}

module Game.Scene (
    Scene,
    stepScene,
    RenderState(..),
    mkRenderState,
    sceneImmutableCopy,
    renderScene,
  ) where

import Prelude hiding (foldr)

import Data.Indexable (Indexable(..), Index, findIndices, fmapMWithIndex, toList, indexA)
import qualified Data.Set as Set
import Data.Foldable (foldr)
import Data.Maybe
import Data.Abelian
import Data.IORef

import Control.Monad
import Control.Monad.State (StateT(..))
import Control.Applicative ((<|>))

import Control.Concurrent.MVar

import Graphics.Qt as Qt

import Physics.Chipmunk as CM hiding (renderPosition)

import Utils

import Base

import Profiling.Physics
import Profiling.FPS (FPSRef, tickFPSRef, initialFPSRef)

import Object

import Game.Scene.Camera
import Game.Scene.OptimizeRenderPixmaps

import Sorts.Nikki.Types
import Sorts.Terminal
import Sorts.Switch
import Sorts.LowerLimit


-- * entry

-- order of one frame step is this:
-- maybe transition to another scene
-- chipmunk stepping
-- updating the objects
-- rendering

stepScene :: Configuration -> Space -> ControlData -> Scene Object_ -> IO (Scene Object_)
stepScene configuration space controlData =
    updateScene (controls configuration) controlData >=>
    stepSpace space >=>
    maybeAbort configuration >=>
    transition (controls configuration) controlData


-- * State automaton stuff

transition :: Controls -> ControlData -> Scene Object_ -> IO (Scene Object_)
transition controls cd scene = do
    controlledPosition :: Maybe CM.Position <-
        fmapM (getPosition . getControlledChipmunk scene) $ getControlled scene
    case mNew controlledPosition of
        Nothing -> return scene
        Just new -> modifyTransitioned new
  where
    -- | Maybe the new scene
    mNew :: Maybe CM.Position -> Maybe (Scene Object_)
    mNew controlledPosition = foldl1 (<|>) [
        nikkiToTerminal controls scene cd,
        terminalExit scene,
        robotToTerminal controls scene cd,
        nikkiMovedAwayFromTerminal scene,
        lowerLimitHandler scene controlledPosition,
        gameOver scene,
        levelPassed scene
      ]

-- | applied to the scene after every transition
modifyTransitioned :: Scene Object_ -> IO (Scene Object_)
modifyTransitioned scene = do
    resetHeldKeys
    return $ case getControlledIndex scene of
      Just controlledIndex ->
        let now = scene ^. spaceTime
        in objects .> gameMainLayer .> indexA controlledIndex ^:
            (startControl now) $ scene
      Nothing -> scene


-- | converts the Scene to TerminalMode, if appropriate
nikkiToTerminal :: Controls -> Scene Object_ -> ControlData -> Maybe (Scene Object_)
nikkiToTerminal config scene@Scene{mode_ = (NikkiMode nikkiIndex)} cd
                                               -- nikki must be in wait mode
    | contextButtonPressed && beforeTerminal && waiting
        = Just $ mode ^= mode' $ scene
  where
    contextButtonPressed = isGameContextPressed config cd
    beforeTerminal = nikkiTouchesTerminal $ scene ^. contacts
    nikki :: Nikki
    Just nikki = unwrapNikki $ scene ^. mainLayerObjectA nikkiIndex
    action_ = action $ state $ nikki
    waiting = isWaitAction action_

    mode' = TerminalMode nikkiIndex terminal
    (terminal : _) = whichTerminalCollides scene
nikkiToTerminal _ _ _ = Nothing


whichTerminalCollides :: Scene Object_ -> [Index]
whichTerminalCollides scene =
    findIndices p allTerminals
  where
    allTerminals :: Indexable (Maybe Terminal)
    allTerminals = fmap unwrapTerminal $ scene ^. objects ^. gameMainLayer

    p :: Maybe Terminal -> Bool
    p Nothing = False
    p (Just t) = any (\ shape -> hasTerminalShape t shape) collidingShapes
    collidingShapes :: [Shape]
    collidingShapes = (scene ^. contacts) |> terminals |> Set.toList

terminalExit :: Scene Object_ -> Maybe (Scene Object_)
terminalExit scene@Scene{mode_ = TerminalMode{nikki, terminal}} =
    case unwrapTerminal $ scene ^. mainLayerObjectA terminal of
        Just t -> case terminalExitMode t of
            DontExit -> Nothing
            ExitToNikki ->
                Just $ mode ^= NikkiMode nikki $ scene
            ExitToRobot robot ->
                Just $ mode ^= RobotMode nikki terminal robot $ scene
terminalExit _ = Nothing


-- | converts from RobotMode to TerminalMode, if appropriate
robotToTerminal :: Controls -> Scene Object_ -> ControlData -> Maybe (Scene Object_)
robotToTerminal config scene@Scene{mode_ = RobotMode{nikki, terminal}} cd
  | bPress =
    Just $ mode ^= TerminalMode nikki terminal $ scene
  where
    bPress = isRobotBackPressed config cd
robotToTerminal _ _ _ = Nothing

-- | if nikki gets moved away from the terminal during robot mode...
nikkiMovedAwayFromTerminal :: Scene Object_ -> Maybe (Scene Object_)
nikkiMovedAwayFromTerminal scene@Scene{mode_} =
    if isRobotMode mode_ || isTerminalMode mode_ then
        if terminal mode_ `elem` whichTerminalCollides scene then
            Nothing
        else
            Just $ mode ^= NikkiMode (nikki mode_) $ scene
    else
        Nothing


gameOver :: Scene Object_ -> Maybe (Scene Object_)
gameOver scene | isGameOver =
    Just $ mode ^= (LevelFinished now Failed) $ scene
  where
    now = scene ^. spaceTime
    isGameOver =
        isGameMode (scene ^. mode)
        && nikkiTouchesLaser (scene ^. contacts)
gameOver _ = Nothing

levelPassed :: Scene Object_ -> Maybe (Scene Object_)
levelPassed scene =
    if allTriggered && isGameMode (scene ^. mode) then
        Just $ mode ^: (const $ LevelFinished now Passed) $ scene
      else
        Nothing
  where
    allSwitches :: [Switch] =
        catMaybes $ map unwrapSwitch $ toList $ scene ^. objects ^. gameMainLayer
    allTriggered = all triggered allSwitches
    now = scene ^. spaceTime


-- * chipmunk stepping

-- | run steps in the physics simulation and update the contacts
-- leaves contacts untouched, if no simulation steps are being done

stepSpace :: Space -> Scene Object_ -> IO (Scene Object_)
stepSpace space scene@Scene{contactRef} = do
    resetContactRef contactRef
    CM.step space stepQuantum
    contacts' <- readContactRef contactRef
    return $
        contacts ^= contacts' $
        spaceTime ^: (+ stepQuantum) $
        scene

-- | aborts the game, when specified by clo --abort_level
maybeAbort :: Configuration -> Scene Object_ -> IO (Scene Object_)
maybeAbort config = case abort_level config of
    Nothing -> return
    Just limit -> \ scene ->
        if scene ^. spaceTime >= limit then error "level aborted" else return scene


-- * object updating

-- | updates every object
updateScene :: Controls -> ControlData -> Scene Object_ -> IO (Scene Object_)
updateScene controlsConfig cd scene = do
    -- NOTE: Currently only the physics layer is updated
    (sceneChange, physicsContent') <- updateMainLayer $ scene ^. objects ^. gameMainLayer
    return $ sceneChange $ objects .> gameMainLayer ^= physicsContent' $ scene
  where
    now = scene ^. spaceTime
    controlled = getControlledIndex scene

    -- update function for all objects in the mainLayer
    updateMainLayer :: Indexable Object_
        -> IO (Scene Object_ -> Scene Object_, Indexable Object_)
    -- each object has to know, if it's controlled
    updateMainLayer ix = do
        ix' <- fmapMWithIndex (\ i o ->
                update DummySort controlsConfig scene now (scene ^. contacts)
                    (Just i == controlled, cd) i o)
                ix
        let changes = foldr (.) id $ fmap fst ix'
            ix'' = fmap snd ix'
        return $ (changes, ix'')


-- * rendering

-- | type for rendering the scene
data RenderState
    = RenderState {
        sceneMVar :: MVar (Scene Object_, DebuggingCommand),
        cameraStateRef :: IORef CameraState,
        fpsRef :: FPSRef
    }

-- | RenderScene (for the rendering thread)
-- Gets created in the logic thread
mkRenderState :: IORef CameraState -> Scene Object_ -> M RenderState
mkRenderState cameraStateRef scene = do
    let noop :: DebuggingCommand = const $ const $ return ()
    newScene <- io $ sceneImmutableCopy scene
    sceneMVar <- io $ newMVar (newScene, noop)
    fpsRef <- initialFPSRef

    return $ RenderState sceneMVar cameraStateRef fpsRef

sceneImmutableCopy :: Scene Object_ -> IO (Scene Object_)
sceneImmutableCopy scene = do
    let old = scene ^. acc
    new <- io $ fmapM Base.immutableCopy old
    return $ acc ^= new $ scene
  where
    acc = objects .> gameMainLayer

-- let renderable_ = renderable (fpsRef, cameraStateRef :: IORef CameraState, sceneMVar :: MVar (RenderScene, DebuggingCommand))
instance Renderable RenderState where
    label = const "RenderScene"
    render ptr app config size (RenderState sceneMVar cameraStateRef fpsRef) = do
        return $ tuple size $ do
            (scene, debugging) <- readMVar sceneMVar
            runStateTFromIORef cameraStateRef $
                Game.Scene.renderScene app config ptr scene debugging

            tickFPSRef app config ptr fpsRef

-- | Well, renders the scene to the screen (to the max :)
-- Happens in the rendering thread.
renderScene :: Application -> Configuration -> Ptr QPainter
    -> Scene Object_ -> DebuggingCommand -> StateT CameraState IO ()
renderScene app configuration ptr scene debugging = do
    let now = scene ^. spaceTime
    center <- getCameraPosition ptr scene
    io $ do
        size <- sizeQPainter ptr
        let Size width height :: Size CpFloat = fmap realToFrac size
            offsetVector = - (center - Vector (width / 2) (height / 2))
            offset = fmap (fromIntegral . truncate) $ vector2position offsetVector

        clearScreen ptr black

        renderObjects configuration size ptr offset now (scene ^. objects)

        renderTerminalOSD ptr now scene

        -- debugging
        when (render_xy_cross configuration) $
            debugDrawCoordinateSystem ptr offset
        when (render_chipmunk_objects configuration) $
            fmapM_ (renderObjectGrid ptr offset) $ scene ^. objects ^. gameMainLayer
        io $ debugging ptr offset
        Profiling.Physics.render app configuration ptr now


renderObjects configuration windowSize ptr offset now gameGrounds =
    when (not $ omit_pixmap_rendering configuration) $ do
        renderPixmaps <- gameGroundsToRenderPixmaps windowSize ptr offset now gameGrounds
        fmapM_ (doRenderPixmap ptr) $ optimize windowSize renderPixmaps
-- development version
renderObjects configuration size ptr offset now gameGrounds =
    when (not $ omit_pixmap_rendering configuration) $ do
        renderPixmaps <- gameGroundsToRenderPixmaps size ptr offset now gameGrounds
        let fakeSize = Size 800 600
            fakeOffset = sizeToPosition $ fmap (/ 2) (size -~ fakeSize)
            fakeMod = fmap (renderPosition ^: (+~ fakeOffset))
        fmapM_ (doRenderPixmap ptr) $ fakeMod $ optimize fakeSize renderPixmaps
        resetMatrix ptr
        setPenColor ptr (alpha ^= 0.5 $ red) 1
        drawRect ptr fakeOffset fakeSize

gameGroundsToRenderPixmaps :: Size Double -> Ptr QPainter -> Offset Double -> Seconds -> GameGrounds Object_ -> IO [RenderPixmap]
gameGroundsToRenderPixmaps size ptr offset now (GameGrounds backgrounds mainLayer foregrounds) = do
    bgs <- layersToRenderPixmaps size ptr offset now backgrounds
    ml <- mainLayerToRenderPixmaps ptr offset now mainLayer
    fgs <- layersToRenderPixmaps size ptr offset now foregrounds
    return (bgs ++ ml ++ fgs)

layersToRenderPixmaps :: Size Double -> Ptr QPainter -> Offset Double -> Seconds -> [GameLayer Object_] -> IO [RenderPixmap]
layersToRenderPixmaps size ptr offset now layers =
    concat <$> fmapM (layerToRenderPixmaps size ptr offset now) layers

layerToRenderPixmaps :: Size Double -> Ptr QPainter -> Offset Double -> Seconds -> GameLayer Object_ -> IO [RenderPixmap]
layerToRenderPixmaps size ptr offset now layer =
    fmap (renderPosition ^: (+~ layerOffset)) <$>
        concat <$> fmapM (\ o -> renderObject_ o ptr layerOffset now) (gameContent layer)
  where
    layerOffset =
        calculateLayerOffset size offset (gameXDistance layer, gameYDistance layer)

-- | rendering of the different Layers.
mainLayerToRenderPixmaps :: Ptr QPainter -> Offset Double -> Seconds
    -> Indexable Object_ -> IO [RenderPixmap]
mainLayerToRenderPixmaps ptr offset now objects =
    fmap (renderPosition ^: (+~ offset)) <$>
        concat <$> fmapM (\ o -> renderObject_ o ptr offset now) (toList objects)


-- * debugging

debugDrawCoordinateSystem :: Ptr QPainter -> Offset Double -> IO ()
debugDrawCoordinateSystem ptr offset = do
    resetMatrix ptr
    translate ptr offset
    setPenColor ptr red 1
    mapM_ inner lines
  where
    inner (a, b, c, d) =
        drawLine ptr (Position a b) (Position c d)
    big = 1000000
    halfScaleLine = 10
    lines =
        (- big, 0, big, 0) :
        (0, - big, 0, big) :
        scale
    scale = map (\ p -> (p, - halfScaleLine, p, halfScaleLine)) scalePositions ++
            map (\ p -> (- halfScaleLine, p, halfScaleLine, p)) scalePositions
    scalePositions = map (* 64) [-100 .. 100]

renderObjectGrid :: Ptr QPainter -> Qt.Position Double -> Object_ -> IO ()
renderObjectGrid ptr offset object = do
    let chips :: [Chipmunk] = chipmunks object
    renderGrids ptr offset chips
