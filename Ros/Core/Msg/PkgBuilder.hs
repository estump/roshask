{-# LANGUAGE OverloadedStrings #-}
-- |Build all messages defined in a ROS package.
module Ros.Core.Msg.PkgBuilder where
import Control.Applicative
import Control.Monad (when)
import qualified Data.ByteString.Char8 as B
import Data.Char (toUpper)
import Data.Either (rights)
import Data.List (findIndex, intercalate)
import System.Directory (createDirectoryIfMissing, getDirectoryContents)
import System.FilePath
import System.Process (createProcess, proc, CreateProcess(..), waitForProcess)
import System.Exit (ExitCode(..))
import Ros.Core.Build.DepFinder (findMessages, findPackageDeps)
import Ros.Core.Msg.Analysis
import Ros.Core.Msg.Gen (generateMsgType)
import Ros.Core.Msg.Parse (parseMsg)
import Data.ByteString.Char8 (ByteString)

-- Build all messages defined by a package.
buildPkgMsgs :: FilePath -> MsgInfo ()
buildPkgMsgs fname = do liftIO . putStrLn $ "Generating package " ++ fname
                        liftIO $ createDirectoryIfMissing True destDir
                        pkgMsgs <- liftIO $ findMessages fname
                        let pkgMsgs' = map (B.pack . cap . dropExtension . takeFileName)
 
                                           pkgMsgs
                            checkErrors xs = case findIndex isLeft xs of
                                               Nothing -> rights xs
                                               Just i -> err (pkgMsgs !! i)
                            names = map ((destDir </>) .
                                        flip replaceExtension ".hs" . 
                                        takeFileName)
                                        pkgMsgs
                            gen = generateMsgType pkgHier pkgMsgs'
                        parsed <- liftIO $ checkErrors <$> mapM parseMsg pkgMsgs
                        mapM_ (\(n, m) -> gen m >>= 
                                          liftIO . B.writeFile n)
                              (zip names parsed)
                        liftIO $ 
                          do cpath <- genMsgCabal fname pkgName
                             let cpath' = dropFileName cpath
                             (_,_,_,proc) <- 
                               createProcess (proc "cabal" ["install"])
                                             { cwd = Just cpath' }
                             code <- waitForProcess proc
                             when (code /= ExitSuccess)
                                  (error $ "Building messages for "++
                                           pkgName++" failed")
    where err pkg = error $ "Couldn't parse message " ++ pkg
          destDir = fname </> "msg" </> "haskell" </> "Ros" </> pkgName
          pkgName = cap . last . splitDirectories $ fname
          pkgHier = B.pack $ "Ros." ++ pkgName ++ "."
          isLeft (Left _) = True
          isLeft _ = False

-- Convert a ROS package name to valid Cabal package name
rosPkg2CabalPkg :: String -> String
rosPkg2CabalPkg = (\x -> concat ["ROS-",x,"Msg"]) . map sanitize
  where sanitize '_' = '-'
        sanitize c   = c

-- Extract a Package name from the path to its directory.
path2Pkg :: FilePath -> String
path2Pkg = cap . last . splitPath

-- Capitalize the first letter in a string.
cap :: String -> String
cap [] = []
cap (h:t) = toUpper h : t

-- Extract a Msg module name from a Path
path2MsgModule :: FilePath -> String
path2MsgModule = intercalate "." . map cap . reverse . take 3 .
                 reverse . splitDirectories . dropExtension

getHaskellMsgFiles :: FilePath -> String -> IO [FilePath]
getHaskellMsgFiles pkgPath pkgName = 
  map (dir </>) . filter ((== ".hs") . takeExtension) <$> getDirectoryContents dir
  where dir = pkgPath </> "msg" </> "haskell" </> "Ros" </> pkgName

-- Generate a .cabal file to build this ROS package's messages.
genMsgCabal :: FilePath -> String -> IO FilePath
genMsgCabal pkgPath pkgName = 
  do deps <- map (B.pack . rosPkg2CabalPkg . path2Pkg) <$> 
             findPackageDeps pkgPath
     msgFiles <- getHaskellMsgFiles pkgPath pkgName
     let msgModules = map (B.pack . path2MsgModule) msgFiles
         target = B.intercalate "\n" $
                  [ "Library"
                  , B.append "  Exposed-Modules: " 
                             (if (not (null msgModules))
                              then B.concat [ head msgModules
                                            , "\n" 
                                            , B.intercalate "\n" 
                                                (map indent (tail msgModules)) ]
                              else "")
                  , ""
                  , "  Build-Depends:   base >= 4.2 && < 6,"
                  , "                   vector == 0.7.*,"
                  , "                   time == 1.1.*,"
                  , B.append "                   roshask == 0.1.*"
                             (if null deps then ""  else ",")
                  , B.intercalate ",\n" $
                    map (B.append "                   ") deps
                  , "  GHC-Options:     -Odph" ]
         pkgDesc = B.concat [preamble, "\n", target]
         cabalFilePath = pkgPath</>"msg"</>"haskell"</>cabalPkg++".cabal"
     B.writeFile cabalFilePath pkgDesc
     return cabalFilePath
  where cabalPkg = rosPkg2CabalPkg pkgName
        preamble = format [ ("Name", B.pack cabalPkg)
                          , ("Version", "0.1.0")
                          , ("Synopsis", B.append "ROS Messages from " 
                                                  (B.pack pkgName))
                          , ("Cabal-version", ">=1.6")
                          , ("Category", "Robotics")
                          , ("Build-type", "Simple") ]
        indent = let spaces = B.replicate 19 ' ' in B.append spaces

format :: [(ByteString, ByteString)] -> ByteString
format fields = B.concat $ map indent fields
  where indent (k,v) = let spaces = flip B.replicate ' ' $ 
                                    21 - B.length k - 1
                       in B.concat [k,":",spaces,v,"\n"]