
-- | Drivers used to run the various jobs.
--
--   These drivers are used by the code that runs at query execution time.
--   We have a driver for each of the job types defined in "Data.Repa.Query.Job".
--
module Data.Repa.Query.Runtime.Driver
        ( execQuery
        , execExtract
        , pattern ExtractTargetFile)
where
import Data.Word
import Data.Maybe
import System.IO
import qualified Data.Repa.Flow                         as F
import qualified Data.Repa.Query.Job.Spec               as QJ
import qualified Data.Repa.Flow.Generic                 as FG
import qualified Data.Repa.Array.Generic                as AG
import qualified Data.Repa.Array.Material.Auto          as AA
import qualified System.Environment                     as System
import Prelude                                          as P
#include "repa-query.h"


---------------------------------------------------------------------------------------------------
-- | Top level driver for a query job.
--
--   The query takes the path to the root data directory as its first argument.
--
execQuery :: (FilePath -> IO (F.Sources Word8)) -> IO ()
execQuery makeSources
 = do
        -- Parse command-line arguments.
        args    <- System.getArgs
        config  <- parseArgs args configZero
        let Just pathRootData = configRootData config

        -- Build the flow sources.
        ss      <- makeSources pathRootData

        -- Stream data from flow sources to stdout.
        streamSourcesToStdout ss
        return  ()
{-# INLINE execQuery #-}


---------------------------------------------------------------------------------------------------
-- | Top level driver for an extract job.
--
--   The query takes the path to the root data directory as its first argument.
--
execExtract
        :: (FilePath -> IO (F.Sources Word8)) 
        -> QJ.ExtractTarget 
        -> IO ()

execExtract makeSources target
 = do
        -- Parse command-line arguments.
        args    <- System.getArgs
        config  <- parseArgs args configZero
        let Just pathRootData = configRootData config

        -- Build the flow sources.
        ss      <- makeSources pathRootData

        -- Stream data from flow sources to stdout.
        case target of
         QJ.ExtractTargetFile fileOut
          -> streamSourcesToFile ss fileOut

{-# INLINE execExtract #-}


-- Pattern synonyms for extract targets so that generated
-- code that uses them only needs to import this module.
pattern ExtractTargetFile file  = QJ.ExtractTargetFile file


---------------------------------------------------------------------------------------------------
-- | Read data from a bundle of sources and write it to stdout.
streamSourcesToStdout :: F.Sources Word8 -> IO ()
streamSourcesToStdout ss
 = do   ss0     <- FG.funnel_i ss
        ss1     <- FG.mapIndex_i (\_ -> 1) (\_ -> ()) ss0

        b       <- F.hBucket stdout
        let bs  =  AG.fromList AA.B [b]
        ks      <- F.sinkBytes bs 
        F.drainP ss1 ks
{-# INLINE_FLOW streamSourcesToStdout #-}


-- | Read data from a bundle of sources and write it to a single file.
streamSourcesToFile :: F.Sources Word8 -> FilePath -> IO ()
streamSourcesToFile ss filePath
 = do   ss0     <- FG.funnel_i ss
        ss1     <- FG.mapIndex_i (\_ -> 1) (\_ -> ()) ss0
        ks      <- F.toFiles [filePath] F.sinkBytes
        F.drainP ss1 ks
{-# INLINE_FLOW streamSourcesToFile #-}


---------------------------------------------------------------------------------------------------
-- | Parse command line arguments given to query.
parseArgs :: [String] -> Config -> IO Config
parseArgs [] config
 | isJust $ configRootData config
 = return config
 | otherwise = dieUsage

parseArgs args config
 | "-root-data" : path : rest   <- args
 = parseArgs rest $ config { configRootData = Just path }

 | otherwise
 = dieUsage

dieUsage 
 = error $ P.unlines
 [ "Usage: query -root-data <PATH>"
 , "Execute a Repa query."
 , ""
 , "OPTIONS:"
 , " -root-data PATH    (required) Root path containing table data." ]


-- | Query command-line config.
data Config
        = Config
        { configRootData        :: Maybe FilePath }

configZero 
        = Config Nothing

