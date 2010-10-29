{-# language ViewPatterns, ScopedTypeVariables #-}

-- | There is a problem with multiple shapes forming bigger geometrical structures in chipmunk:
-- shapes, that are moving while touching these shapes, might get stuck on
-- edges between shapes. In our case, this is espacially problematic, as we cannot model everything by hand,
-- cause we have our level editor. Nikki (and probably everthing else that moves) can get stuch in the edges
-- between two tiles, although the two tiles form a geometrical object without these edges. That's happening,
-- Nikkis shapes overlap with one tile and get stuck on the other.
-- This module tries to provide a way o automatically merge Tiles and change them to shapes, that aren't problematic.
-- There is a quickcheck testing framework for this in the testsuite directory.
-- The current version does not produce the correct result for every case yet.

module Physics.Chipmunk.StickyEdges (removeStickyEdges, tests) where


import Prelude hiding (Left, Right)

import Data.Abelian
import Data.Map (Map, fromList, (!), insert)

import Control.Applicative ((<*>))
import Control.Arrow

import Test.QuickCheck
import Test.QuickCheck.Property

import Physics.Hipmunk (ShapeType(Polygon), Vector(Vector))

import Utils hiding (tests)

import Physics.Chipmunk.Types (vectorX, vectorY)

import Base.Directions


x = vectorX
y = vectorY

-- * non-redundant representation of rectangles

data Rectangle
  = Rectangle {
    start :: Vector,
    width :: Double,
    height :: Double
  }
    deriving (Eq, Show)

instance Arbitrary Rectangle where
    arbitrary = Rectangle <$> arbitrary <*> arbitrary <*> arbitrary

-- | returns the lower right corner of rectangles
end :: Rectangle -> Vector
end r = start r +~ Vector (width r) (height r)

modifyWidth :: (Double -> Double) -> Rectangle -> Rectangle
modifyWidth f (Rectangle start w h) =
    Rectangle start (f w) h

-- | rotates the given rectangle by 90 degrees
rotateRectangleHalfPi :: Rectangle -> Rectangle
rotateRectangleHalfPi (Rectangle (Vector x y) w h) =
    Rectangle (Vector (- y - h) x) h w

-- conversions

toRectangle :: ShapeType -> Rectangle
toRectangle (Polygon [Vector x1 y1, Vector x2 y2, Vector x3 y3, Vector x4 y4])
    | x1 == x2 && x3 == x4 && y1 == y4 && y2 == y3 =
        Rectangle (Vector x1 y1) (x3 - x1) (y3 - y1)

fromRectangle :: Rectangle -> ShapeType
fromRectangle (Rectangle (Vector x y) w h) = Polygon [
        Vector x y,
        Vector x (y + h),
        Vector (x + w) (y + h),
        Vector (x + w) y
      ]


-- * actual algorithm

removeStickyEdges :: Double -> [ShapeType] -> [ShapeType]
removeStickyEdges epsilon =
    map toRectangle >>>
    mergePairs removeContained >>>
    moveSides >>>
    mergePairs removeContained >>>
    map fromRectangle >>>
    removeWedges epsilon >>>
    id

-- removes rectangles that are containesd inside others
removeContained :: Rectangle -> Rectangle -> Maybe [Rectangle]
removeContained a b =
    justWhen
        (x (start a) >= x (start b) && y (start a) >= y (start b) && x (end a) <= x (end b) && y (end a) <= y (end b))
        [b]

-- | enlarges or shrinks rectangles.
-- This is actually programmed just for the right side of rectangles,
-- but with rotating is applied to all sides.
moveSides :: [Rectangle] -> [Rectangle]
moveSides =
    map rotateRectangleHalfPi >>>
    moveRightSides >>>
    map rotateRectangleHalfPi >>>
    moveRightSides >>>
    map rotateRectangleHalfPi >>>
    moveRightSides >>>
    map rotateRectangleHalfPi >>>
    moveRightSides >>>
    id


moveRightSides = mergePairs moveRightSide

moveRightSide a b |
    -- rectangles overlap, one horizontal side is flush --> expand rect, form an L-shaped thing
    x (end a) >= x (start b) &&
    x (end a) < x (end b) &&
    ((y (start a) > y (start b) && -- downside is flush
      y (end a) == y (end b)) ||
     (y (start a) == y (start b) && -- upside is flush
      y (end a) < y (end b)))
  = Just [modifyWidth (+ (x (end b) - x (end a))) a, b]

moveRightSide a b |
    -- both horizontal sides are flush --> merge rects
    x (end a) >= x (start b) &&
    x (end a) <= x (end b) &&
    y (start a) == y (start b) &&
    y (end a) == y (end b)
  = Just [Rectangle s w h]
    where
        s = Vector (withView (x . start) min a b) (y (start a))
        w = (withView (x . end) max a b) - x s
        h = height a

moveRightSide a b = Nothing


-- | moves two points (by distance of epsilon) in L-shaped combinations of two shapes to avoid sticky edges
removeWedges epsilon =
    foldr1 (>>>) $ replicate 4 (mergePairs moveUpperLeftCorner >>> map rotateShapeTypeHalfPi)
  where
    moveUpperLeftCorner (Polygon [a, b, c, d]) other@(Polygon [p, q, r, s]) =
        if x a == x p && x a == x q && y a > y p && y a < y q && y b <= y q then
            -- a needs to be moved to the right
            let a' = a +~ Vector epsilon 0
            in Just [Polygon [a', b, c, d], other]
        else if y a == y p && y a == y s && x a > x p && x a < x s then
            -- a needs to be moved down
            let a' = a +~ Vector 0 epsilon
            in Just [Polygon [a', b, c, d], other]
        else
            Nothing

-- | rotates rectangles by 90 degrees
rotateShapeTypeHalfPi :: ShapeType -> ShapeType
rotateShapeTypeHalfPi (Polygon v) = Polygon $ map rotateVectorHalfPi (tail v +: head v)

rotateVectorHalfPi :: Vector -> Vector
rotateVectorHalfPi (Vector x y) = Vector (- y) x

rotateDirection :: Direction -> Direction
rotateDirection DLeft = DUp
rotateDirection DUp = DRight
rotateDirection DRight = DDown
rotateDirection DDown = DLeft

tests :: IO ()
tests = do
    quickCheck $ putTestCase "testRotateVectorHalfPi" testRotateVectorHalfPi
    quickCheck $ putTestCase "testRotateRectangleHalfPi" testRotateRectangleHalfPi

testRotateVectorHalfPi :: Vector -> Bool
testRotateVectorHalfPi v = v == superApply 4 rotateVectorHalfPi v

testRotateRectangleHalfPi :: Rectangle -> Bool
testRotateRectangleHalfPi r =
    equals r r'
  where
    r' = superApply 4 rotateRectangleHalfPi r
    equals (Rectangle (Vector a b) c d) (Rectangle (Vector p q) r s) =
        a ~= p && b ~= q && c ~= r && d ~= s