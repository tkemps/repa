{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE UndecidableInstances #-}
module Data.Repa.Array.Material.Auto.InstArray where
import Data.Repa.Array.Material.Auto.Base       as A
import Data.Repa.Array.Material.Boxed           as A
import Data.Repa.Array.Material.Nested          as A
import Data.Repa.Array.Meta.Window              as A
import Data.Repa.Array.Generic.Convert          as A
import Data.Repa.Array.Generic.Target           as A
import Data.Repa.Array.Internals.Layout         as A
import Data.Repa.Array.Internals.Bulk           as A
import Data.Repa.Fusion.Unpack                  as A
import Control.Monad
#include "repa-array.h"


instance (Bulk A a, A.Windowable r a, Index r ~ Int)
       => Bulk A (Array r a) where
 data Array A (Array r a)       = AArray_Array !(Array N (Array r a))
 layout (AArray_Array arr)      = Auto (A.length arr)
 index  (AArray_Array arr) ix   = A.index arr ix
 {-# INLINE_ARRAY layout #-}
 {-# INLINE_ARRAY index #-}

deriving instance Show (Array A a) => Show (Array A (Array A a))


instance Convert r1 a1 r2 a2
      => Convert  A (Array r1 a1)  N (Array r2 a2) where
 convert (AArray_Array (NArray starts lens arr)) 
        = NArray starts lens (convert arr)
 {-# INLINE_ARRAY convert #-}


instance Convert r1 a1 r2 a2
      => Convert  N (Array r1 a1)  A (Array r2 a2) where
 convert (NArray starts lens arr)
        = AArray_Array (NArray starts lens (convert arr))
 {-# INLINE_ARRAY convert #-}


instance Convert r1 a1 r2 a2
      => Convert A  (Array r1 a1) A (Array r2 a2) where
 convert (AArray_Array (NArray starts lens arr))
        = AArray_Array (NArray starts lens (convert arr))
 {-# INLINE_ARRAY convert #-}


instance (Bulk l a, A.Target l a, Index l ~ Int) 
       => A.Target A (Array l a) where
 data Buffer A (Array l a)
  = ABuffer_Array !(A.Buffer N (Array l a))

 unsafeNewBuffer (Auto len)     
  = liftM ABuffer_Array $ unsafeNewBuffer (Nested len)
 {-# INLINE_ARRAY unsafeNewBuffer #-}

 unsafeReadBuffer   (ABuffer_Array arr) ix
  = unsafeReadBuffer arr ix
 {-# INLINE_ARRAY unsafeReadBuffer #-}

 unsafeWriteBuffer  (ABuffer_Array arr) ix x
  = unsafeWriteBuffer arr ix x
 {-# INLINE_ARRAY unsafeWriteBuffer #-}

 unsafeGrowBuffer   (ABuffer_Array arr) bump
  = liftM ABuffer_Array $ unsafeGrowBuffer arr bump
 {-# INLINE_ARRAY unsafeGrowBuffer #-}

 unsafeFreezeBuffer (ABuffer_Array arr)
  = liftM AArray_Array  $ unsafeFreezeBuffer arr 
 {-# INLINE_ARRAY unsafeFreezeBuffer #-}

 unsafeThawBuffer   (AArray_Array arr)
  = liftM ABuffer_Array $ unsafeThawBuffer  arr
 {-# INLINE_ARRAY unsafeThawBuffer #-}

 unsafeSliceBuffer st len (ABuffer_Array buf)
  = liftM ABuffer_Array $ unsafeSliceBuffer st len buf
 {-# INLINE_ARRAY unsafeSliceBuffer #-}

 touchBuffer (ABuffer_Array buf)
  = touchBuffer buf
 {-# INLINE_ARRAY touchBuffer #-}

 bufferLayout (ABuffer_Array buf)
  = Auto $ A.extent $ bufferLayout buf
 {-# INLINE_ARRAY bufferLayout #-}


instance Unpack (Buffer N (Array l a)) t
      => Unpack (Buffer A (Array l a)) t where
 unpack (ABuffer_Array buf)   = unpack buf
 repack (ABuffer_Array x) buf = ABuffer_Array (repack x buf)
 {-# INLINE unpack #-}
 {-# INLINE repack #-}


instance (Bulk A a, Windowable l a, Index l ~ Int)
       => Windowable A (Array l a) where
 window st len (AArray_Array arr) 
  = AArray_Array (window st len arr)
 {-# INLINE_ARRAY window #-}

