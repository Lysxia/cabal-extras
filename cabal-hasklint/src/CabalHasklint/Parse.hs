module CabalHasklint.Parse (
    parse,
) where

import Peura

import qualified Distribution.ModuleName      as C
import qualified Distribution.Types.BuildInfo as C
import qualified Distribution.Types.Version   as C

import GHC.Data.StringBuffer                      (stringToStringBuffer)
import GHC.Driver.Session                         (parseDynamicFilePragma, parseDynamicFlagsCmdLine, xopt)
import GHC.Hs                                     (HsModule)
import GHC.Parser.Header                          (getOptions)
import GHC.Parser.Lexer                           (ParseResult (..), getMessages)
import GHC.Types.SrcLoc                           (Located, noLoc)
import GHC.Utils.Error                            (printBagOfErrors)
import Language.Haskell.GhclibParserEx.GHC.Parser (parseFile)

import qualified GHC.LanguageExtensions.Type as LangExt

import CabalHasklint.Cpp
import CabalHasklint.GHC.Utils
import CabalHasklint.Trace

-- | Parse module.
--
-- Read file, extract doctest blocks.
--
-- In particular, this runs CPP preprocessing if needed.
parse
    :: TracerPeu r Tr
    -> GhcInfo
    -> Version             -- ^ package version
    -> Path Absolute       -- ^ package directory
    -> [Path Absolute]     -- ^ additional include directories
    -> [PackageIdentifier] -- ^ dependencies
    -> C.BuildInfo
    -> C.ModuleName
    -> Path Absolute
    -> Peu r (Located HsModule)
parse tracer ghcInfo pkgVer pkgDir cppDirs pkgIds bi modname modpath = do
    traceApp tracer $ TraceParse modname modpath
    let dflags0 = fakeDynFlags

    -- set flags from bi
    (dflags1, _, _warns1) <- liftIO $ parseDynamicFlagsCmdLine dflags0 $
        [ noLoc $ "-X" ++ prettyShow ext
        | ext <- C.defaultExtensions bi
        ]

    -- read file
    contents <- fromUTF8BS <$> readByteString modpath

    -- parse in-file options
    let options2 = getOptions dflags1 (stringToStringBuffer contents) (toFilePath modpath)
    (dflags2, _, _warns2) <- liftIO $ parseDynamicFilePragma dflags1 options2

    -- do CPP
    contents' <- if xopt LangExt.Cpp dflags2
        then cpphs tracer pkgVer pkgIds cppIncludes cppDefines modpath contents
        else return contents

    -- reparse in-file options
    let options = getOptions dflags2 (stringToStringBuffer contents) (toFilePath modpath)
    (dflags, _, _warns) <- liftIO $ parseDynamicFilePragma dflags1 options

    -- parse module
    md <- fromParseResult dflags $ parseFile (toFilePath modpath) dflags contents'
    return md
  where
    fromParseResult _dflags (POk _ x)   = return x
    fromParseResult  dflags (PFailed s) = do
        let (_warns, errors) = getMessages s dflags
        liftIO $ printBagOfErrors dflags errors
        die tracer "Parse failure"

    cppIncludes :: [Path Absolute]
    cppIncludes =
        -- if there are absolute dirs, they are converted to relative,
        -- so may break
        [ pkgDir </> fromUnrootedFilePath dir
        | dir <- C.includeDirs bi
        ] ++ cppDirs

    cppDefines :: [(String, String)]
    cppDefines =
        [ ("__GLASGOW_HASKELL__", cppGhcVersion (ghcVersion ghcInfo))
        ] ++
        [ d'
        | d <- C.cppOptions bi
        , Just d' <- return (parseDefineFlag d)
        ]

cppGhcVersion :: Version -> String
cppGhcVersion v = case C.versionNumbers v of
    []      -> "0"
    (x:[])  -> show (x * 100)
    (x:y:_) -> show (x * 100 + y)

parseDefineFlag :: String -> Maybe (String, String)
parseDefineFlag ('-' : 'D' : rest) =
    case after of
        []        -> Nothing
        '=':value -> Just (before, value)
        _         -> Nothing -- shouldn't happen
  where
    (before, after) = span (/= '=') rest

parseDefineFlag _ = Nothing
