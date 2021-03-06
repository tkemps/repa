
module Data.Repa.Array.Material.Nested
        ( N     (..)
        , Name  (..)
        , Array (..)
        , U.Unbox

        -- * Conversion
        , fromLists
        , fromListss

        -- * Mapping
        , mapElems

        -- * Slicing
        , slices

        -- * Concatenation
        , concats

        -- * Splitting
        , segment
        , segmentOn

        , dice
        , diceSep

        -- * Trimming
        , trims
        , trimEnds
        , trimStarts

        -- * Transpose
        , ragspose3)
where
import Data.Repa.Array.Meta.Delayed                     as A
import Data.Repa.Array.Meta.Window                      as A
import Data.Repa.Array.Generic.Index                    as A
import Data.Repa.Array.Material.Unboxed                 as A
import Data.Repa.Array.Material.Foreign.Base            as A
import Data.Repa.Array.Internals.Bulk                   as A
import Data.Repa.Array.Internals.Target                 as A
import Data.Repa.Eval.Stream                            as A
import Data.Repa.Stream                                 as S
import qualified Data.Repa.Vector.Generic               as G
import qualified Data.Repa.Vector.Unboxed               as U
import qualified Data.Vector.Unboxed                    as U
import qualified Data.Vector.Fusion.Stream              as S
import qualified Data.Vector.Mutable                    as VM
import qualified Data.Vector                            as VV
import Control.Monad.ST
import Control.Monad
import GHC.Exts hiding (fromList)
import Prelude                                          as P
import Prelude  hiding (concat)
#include "repa-array.h"


-------------------------------------------------------------------------------------------- Layout
-- | Nested array represented as a flat array of elements, and a segment
--   descriptor that describes how the elements are partitioned into
--   the sub-arrays. Using this representation for multidimentional arrays
--   is significantly more efficient than using a boxed array of arrays, 
--   as there is no need to allocate the sub-arrays individually in the heap.
--
--   With a nested type like:
--   @Array N (Array N (Array U Int))@, the concrete representation consists
--   of five flat unboxed vectors: two for each of the segment descriptors
--   associated with each level of nesting, and one unboxed vector to hold
--   all the integer elements.
--
--   UNSAFE: Indexing into raw material arrays is not bounds checked.
--   You may want to wrap this with a Checked layout as well.
--
data N  = Nested 
        { nestedLength  :: !Int }

deriving instance Eq N
deriving instance Show N


-- | Nested arrays.
instance Layout N where
 data Name  N           = N
 type Index N           = Int
 name                   = N
 create N len           = Nested len
 extent (Nested len)    = len
 toIndex   _ ix         = ix
 fromIndex _ ix         = ix
 {-# INLINE_ARRAY name      #-}
 {-# INLINE_ARRAY extent    #-}
 {-# INLINE_ARRAY toIndex   #-}
 {-# INLINE_ARRAY fromIndex #-}

deriving instance Eq   (Name N)
deriving instance Show (Name N)


---------------------------------------------------------------------------------------------- Bulk
-- | Nested arrays.
instance (BulkI l a, Windowable l a)
      =>  Bulk N (Array l a) where

 data Array N (Array l a)
        = NArray 
        { nArrayStarts  :: !(U.Vector Int)      -- ^ Segment start positions.
        , nArrayLengths :: !(U.Vector Int)      -- ^ Segment lengths.
        , nArrayElems   :: !(Array l a)         -- ^ Element values.
        }

 layout (NArray starts _lengths _elems)
        = Nested (U.length starts)
 {-# INLINE_ARRAY layout #-}

 index  (NArray starts lengths elems) ix
        = window (starts  `U.unsafeIndex` ix)
                 (lengths `U.unsafeIndex` ix)
                 elems
 {-# INLINE_ARRAY index #-}


deriving instance Show (Array l a) 
  => Show (Array N (Array l a))


-------------------------------------------------------------------------------------------- Target
-- Nested arrays cannot be constructed directly when the array elements
-- are supplied in random order, as we don't know where each array should
-- be placed in the underlying vector of elements.
-- 
-- We handle this problem by recording all the elements in a boxed vector
-- as they are provided, then concatenating them down to the usual nested
-- array representation on freezing.
--
instance (Bulk l a, Target l a, Index l ~ Int) 
       => Target N (Array l a) where

  data Buffer N (Array l a)
   = NBuffer !(VM.IOVector (Array l a))

  unsafeNewBuffer    (Nested n)          
   = NBuffer `liftM` VM.unsafeNew n
  {-# INLINE_ARRAY unsafeNewBuffer    #-}

  unsafeReadBuffer   (NBuffer mv) i
   = VM.unsafeRead mv i
  {-# INLINE_ARRAY unsafeReadBuffer   #-}

  -- IMPORTANT: the write functinon is strict in the element value so that
  -- we don't write lazy thunks into the buffer. When the buffer is frozen
  -- we'll demanand all the elements anyway, so we want the producer thread
  -- to be responsible for evaluating them.
  unsafeWriteBuffer  (NBuffer mv) i !x
   = VM.unsafeWrite mv i x
  {-# INLINE_ARRAY unsafeWriteBuffer  #-}

  unsafeGrowBuffer   (NBuffer mv) x
   = NBuffer `liftM` VM.unsafeGrow mv x
  {-# INLINE_ARRAY unsafeGrowBuffer   #-}

  unsafeSliceBuffer i n (NBuffer mv)
   = return $ NBuffer (VM.unsafeSlice i n mv)
  {-# INLINE_ARRAY unsafeSliceBuffer  #-}

  touchBuffer _
   = return ()
  {-# INLINE_ARRAY touchBuffer        #-}

  bufferLayout (NBuffer mv)
   = Nested $ VM.length mv
  {-# INLINE_ARRAY bufferLayout       #-}

  unsafeFreezeBuffer (NBuffer mvec)
   = do 
        -- Freeze the mutable vector so we can use the usual boxed vector API.
        !(vec :: VV.Vector (Array l a)) <- VV.unsafeFreeze mvec

        -- Scan through all the boxed array elements to produce the 
        -- lengths vector.
        let !(lengths :: U.Vector Int)  = U.convert    $ VV.map A.length vec
        let !(starts  :: U.Vector Int)  = U.unsafeInit $ U.scanl (+) 0 lengths
        let !(I# lenElems)              = U.sum lengths
        let !(I# lenArrs)               = VV.length vec

        !bufElems <- unsafeNewBuffer (create name (I# lenElems))

        -- Concatenate all the elements from the source arrays
        -- into a single, flat elements buffer.
        let loop_freeze !iDst !iSrcArr
                -- We've finished copying all the arrays
                | I# iSrcArr >= I# lenArrs
                = return ()

                | otherwise
                = do let !arrSrc      = VV.unsafeIndex vec (I# iSrcArr)
                     let !(I# lenSrc) = A.length arrSrc

                     let loop_freeze_copy iDst' iSrc'
                          | I# iSrc' >= I# lenSrc
                          =     loop_freeze iDst' (iSrcArr +# 1#)

                          | otherwise
                          = do  let !x = A.index arrSrc (I# iSrc')
                                unsafeWriteBuffer bufElems (I# iDst') x
                                loop_freeze_copy (iDst' +# 1#) (iSrc' +# 1#)
                         {-# INLINE loop_freeze_copy #-}

                     loop_freeze_copy iDst 0#

            {-# INLINE_INNER loop_freeze #-}

        -- If there are no inner arrays then we can't take the length
        -- of the first one.
        loop_freeze 0# 0#

        !arrElems <- unsafeFreezeBuffer bufElems
        return $ NArray starts lengths arrElems
  {-# INLINE_ARRAY unsafeFreezeBuffer #-}


---------------------------------------------------------------------------------------- Windowable
-- | Windowing Nested arrays.
instance (BulkI l a, Windowable l a)
      => Windowable N (Array l a) where
 window start len (NArray starts lengths elems)
        = NArray  (U.unsafeSlice start len starts)
                  (U.unsafeSlice start len lengths)
                  elems
 {-# INLINE_ARRAY window #-}


---------------------------------------------------------------------------------------------------
-- | O(size src) Convert some lists to a nested array.
fromLists 
        :: TargetI l a
        => Name l -> [[a]] -> Array N (Array l a)
fromLists nDst xss
 = let  xs         = concat xss
        elems      = fromList nDst xs
        lengths    = U.fromList    $ P.map P.length xss
        starts     = U.unsafeInit  $ U.scanl (+) 0 lengths
   in   NArray starts lengths elems
{-# INLINE_ARRAY fromLists #-}
        

-- | O(size src) Convert a triply nested list to a triply nested array.
fromListss 
        :: TargetI l a
        => Name l -> [[[a]]] -> Array N (Array N (Array l a))
fromListss nDst xs
 = let  xs1        = concat xs
        xs2        = concat xs1
        elems      = fromList nDst xs2
        
        lengths1   = U.fromList   $ P.map P.length xs
        starts1    = U.unsafeInit $ U.scanl (+) 0 lengths1

        lengths2   = U.fromList   $ P.map P.length xs1
        starts2    = U.unsafeInit $ U.scanl (+) 0 lengths2

   in   NArray    starts1 lengths1 
         $ NArray starts2 lengths2 
         $ elems
{-# INLINE_ARRAY fromListss #-}


---------------------------------------------------------------------------------------------------
-- | Apply a function to all the elements of a doubly nested array,
--   preserving the nesting structure.
mapElems :: (Array l1 a -> Array l2 b)
         ->  Array N (Array l1 a)
         ->  Array N (Array l2 b)

mapElems f (NArray starts lengths elems)
 = NArray starts lengths (f elems)
{-# INLINE_ARRAY mapElems #-}


---------------------------------------------------------------------------------------------------
-- | O(1). Produce a nested array by taking slices from some array of elements.
--   
--   This is a constant time operation, as the representation for nested 
--   vectors just wraps the starts, lengths and elements vectors.
--
slices  :: Array F Int                  -- ^ Segment starting positions.
        -> Array F Int                  -- ^ Segment lengths.
        -> Array l a                    -- ^ Array elements.
        -> Array N (Array l a)

slices (FArray starts) (FArray lens) !elems
 = NArray (VV.convert starts)
          (VV.convert lens)
          elems
{-# INLINE_ARRAY slices #-}


---------------------------------------------------------------------------------------------------
-- | Segmented concatenation.
--   Concatenate triply nested vector, producing a doubly nested vector.
--
--   * Unlike the plain `concat` function, this operation is performed entirely
--     on the segment descriptors of the nested arrays, and does not require
--     the inner array elements to be copied.
--
-- @
-- > import Data.Repa.Nice
-- > nice $ concats $ fromListss U [["red", "green", "blue"], ["grey", "white"], [], ["black"]]
-- ["red","green","blue","grey","white","black"]
-- @
--
concats :: Array N (Array N (Array l a)) 
        -> Array N (Array l a)

concats (NArray starts1 lengths1 (NArray starts2 lengths2 elems))
 = let
        !starts2'       = U.extract (U.unsafeIndex starts2)
                        $ U.zip starts1 lengths1

        !lengths2'      = U.extract (U.unsafeIndex lengths2)
                        $ U.zip starts1 lengths1

   in   NArray starts2' lengths2' elems
{-# INLINE_ARRAY concats #-}


---------------------------------------------------------------------------------------------------
-- | O(len src). Given predicates which detect the start and end of a segment, 
--   split an vector into the indicated segments.
segment :: (BulkI l a, U.Unbox a)
        => (a -> Bool)          -- ^ Detect the start of a segment.
        -> (a -> Bool)          -- ^ Detect the end of a segment.
        -> Array l a            -- ^ Vector to segment.
        -> Array N (Array l a)  

segment pStart pEnd !elems
 = let  len     = size (extent $ layout elems)
        (starts, lens)  
                = U.findSegments pStart pEnd 
                $ U.generate len (\ix -> index elems ix)

   in   NArray starts lens elems
{-# INLINE_ARRAY segment #-}


-- | O(len src). Given a terminating value, split an vector into segments.
--
--   The result segments do not include the terminator.
--  
-- @
-- > import Data.Repa.Nice
-- > nice $ segmentOn (== ' ') (fromList U "fresh   fried fish  ") 
-- ["fresh "," "," ","fried ","fish "," "]
-- @
--
segmentOn 
        :: (BulkI l a, U.Unbox a)
        => (a -> Bool)          -- ^ Detect the end of a segment.
        -> Array l a            -- ^ Vector to segment.
        -> Array N (Array l a)

segmentOn !pEnd !arr
 = segment (const True) pEnd arr
{-# INLINE_ARRAY segmentOn #-}


---------------------------------------------------------------------------------------------------
-- | O(len src). Like `segment`, but cut the source array twice.
dice    :: (BulkI l a, Windowable l a, U.Unbox a)
        => (a -> Bool)          -- ^ Detect the start of an inner segment.
        -> (a -> Bool)          -- ^ Detect the end   of an inner segment.
        -> (a -> Bool)          -- ^ Detect the start of an outer segment.
        -> (a -> Bool)          -- ^ Detect the end   of an outer segment.
        -> Array l a            -- ^ Array to dice.
        -> Array N (Array N (Array l a))

dice pStart1 pEnd1 pStart2 pEnd2 !arr
 = let  lenArr           = size (extent $ layout arr)

        -- Do the inner segmentation.
        (starts1, lens1) = U.findSegments pStart1 pEnd1 
                         $ U.generate lenArr (index arr)

        -- To do the outer segmentation we want to check if the first
        -- and last characters in each of the inner segments match
        -- the predicates.
        pStart2' arr'    
         = pStart2 $ index arr' 0

        pEnd2'   arr'    
         = pEnd2   $ index arr' (size (extent $ layout arr') - 1)

        -- Do the outer segmentation.
        !lenArrInner     = U.length starts1
        !arrInner        = NArray starts1 lens1 arr
        (starts2, lens2) = U.findSegmentsFrom pStart2' pEnd2'
                                lenArrInner (index arrInner)

   in   NArray starts2 lens2 arrInner
{-# INLINE_ARRAY dice #-}


-- | O(len src). Given field and row terminating values, 
--   split an array into rows and fields.
--
diceSep  :: (BulkI l a, Eq a)
        => a            -- ^ Terminating element for inner segments.
        -> a            -- ^ Terminating element for outer segments.
        -> Array l a    -- ^ Vector to dice.
        -> Array N (Array N (Array l a))

diceSep !xEndCol !xEndRow !arr
 = let  (startsLensCol, startsLensRow)
                = runST
                $ G.unstreamToVector2
                $ S.diceSepS  (== xEndCol) (== xEndRow)
                $ S.liftStream
                $ streamOfArray arr

        (startsCol, endsCol)  = U.unzip startsLensCol
        (startsRow, endsRow)  = U.unzip startsLensRow

   in   NArray startsRow endsRow $ NArray startsCol endsCol arr
{-# INLINE_ARRAY diceSep #-}


---------------------------------------------------------------------------------------------------
-- | For each segment of a nested array, trim elements off the start
--   and end of the segment that match the given predicate.
trims   :: BulkI l a
        => (a -> Bool)
        -> Array N (Array l a)
        -> Array N (Array l a)

trims pTrim (NArray starts lengths elems)
 = let
        loop_trimEnds !start !len 
         | len == 0     = (start, len)
         | pTrim (elems `index` (start + len - 1))
                        = loop_trimEnds   start (len - 1)
         | otherwise    = loop_trimStarts start len
        {-# INLINE_INNER loop_trimEnds #-}

        loop_trimStarts !start !len 
         | len == 0     = (start, len)
         | pTrim (elems `index` (start + len - 1)) 
                        = loop_trimStarts (start + 1) (len - 1)
         | otherwise    = (start, len)
        {-# INLINE_INNER loop_trimStarts #-}

        (starts', lengths')
                = U.unzip $ U.zipWith loop_trimEnds starts lengths

   in   NArray starts' lengths' elems
{-# INLINE_ARRAY trims #-}


-- | For each segment of a nested array, trim elements off the end of 
--   the segment that match the given predicate.
trimEnds :: BulkI l a
         => (a -> Bool)
         -> Array N (Array l a)
         -> Array N (Array l a)

trimEnds pTrim (NArray starts lengths elems)
 = let
        loop_trimEnds !start !len 
         | len == 0     = 0
         | pTrim (elems `index` (start + len - 1)) 
                        = loop_trimEnds start (len - 1)
         | otherwise    = len
        {-# INLINE_INNER loop_trimEnds #-}

        lengths'        = U.zipWith loop_trimEnds starts lengths

   in   NArray starts lengths' elems
{-# INLINE_ARRAY trimEnds #-}


-- | For each segment of a nested array, trim elements off the start of
--   the segment that match the given predicate.
trimStarts :: BulkI l a
           => (a -> Bool)
           -> Array N (Array l a)
           -> Array N (Array l a)

trimStarts pTrim (NArray starts lengths elems)
 = let
        loop_trimStarts !start !len 
         | len == 0     = (start, len)
         | pTrim (elems `index` (start + len - 1))
                        = loop_trimStarts (start + 1) (len - 1)
         | otherwise    = (start, len)
        {-# INLINE_INNER loop_trimStarts #-}

        (starts', lengths')
          = U.unzip $ U.zipWith loop_trimStarts starts lengths

   in   NArray starts' lengths' elems
{-# INLINE_ARRAY trimStarts #-}


---------------------------------------------------------------------------------------------------
-- | Ragged transpose of a triply nested array.
-- 
--   * This operation is performed entirely on the segment descriptors
--     of the nested arrays, and does not require the inner array elements
--     to be copied.
--
ragspose3 :: Array N (Array N (Array l a)) 
          -> Array N (Array N (Array l a))

ragspose3 (NArray starts1 lengths1 (NArray starts2 lengths2 elems))
 = let  
        startStops1       = U.zipWith (\s l -> (s, s + l)) starts1 lengths1
        (ixs', lengths1') = U.ratchet startStops1

        starts2'          = U.map (U.unsafeIndex starts2)  ixs'
        lengths2'         = U.map (U.unsafeIndex lengths2) ixs'

        starts1'          = U.unsafeInit $ U.scanl (+) 0 lengths1'

   in   NArray starts1' lengths1' (NArray starts2' lengths2' elems)
{-# INLINE_ARRAY ragspose3 #-}
--  NOINLINE Because the operation is entirely on the segment descriptor.
--           This function won't fuse with anything externally, 
--           and it does not need to be specialiased.

