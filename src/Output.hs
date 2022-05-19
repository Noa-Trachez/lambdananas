{-|
Higher level module for style checker computations.
-}
module Output (
  outputOne,
  outputOneErr,
  outputVague,
  argoOutputFiles,
  dumpManifest,
  module Parser,
  module Rules,
) where

import Conf
import Rules
import Parser

import Data.Maybe
import Data.List

-- | Table of gravities linked to their filepath dump.
-- Used in argos mode only.
argoOutputFiles :: [(Gravity, FilePath)]
argoOutputFiles = zip gravities fileNames
  where
    fileNames = createArgoFileName <$> ["major", "minor", "info"]
    gravities = [Major, Minor, Info]

-- | Given a 'String' creates a 'FilePath' of form :
-- `style-<string>.txt`
createArgoFileName :: String -> FilePath
createArgoFileName s = "style-" <> s <> ".txt"

-- | Output the result of a single coding style error.
outputOne :: Conf -> Warn -> IO ()
outputOne Conf {mode = Just Silent} _ = return ()
outputOne Conf {mode = Just Argos} w@(Warn _ _ g) =
    appendFile atPath $ showArgo w <> "\n"
  where
    atPath = fromMaybe errorsPath $ lookup g argoOutputFiles
    errorsPath = createArgoFileName "debug"
outputOne _ w = putStrLn $ showVera w

-- TODO : this is very much temporary and should be patched when
-- switching backend parsing library.
-- | Outputs a single error when the file could not be parsed.
outputOneErr :: Conf -> ParseError -> IO ()
outputOneErr Conf {mode = Just Silent} _ =
  return ()
outputOneErr Conf {mode = Just Argos} (ParseError filename loc _ text)
    | "Parse error:" `isPrefixOf` text = appendFile atPath $
      showArgo notParsableIssue <> "\n"
    -- everything not a parse error is an extension error
    | otherwise = appendFile "banned_funcs" $
      showArgo forbiddenExtIssue <> "\n"
  where
    atPath = fromMaybe errorsPath $ lookup Major argoOutputFiles
    errorsPath = createArgoFileName "debug"
    notParsableIssue = Warn (NotParsable filename) (filename, loc) Major
    forbiddenExtIssue = Warn (ForbiddenExt filename) (filename, loc) Major
outputOneErr _ (ParseError filename loc _ text)
    | "Parse error:" `isPrefixOf` text = putStrLn $ showVera issue
    -- everything not a parse error is an extension error
    | otherwise = putStrLn $ snd $ getIssueDesc $ ForbiddenExt filename
  where
    issue = Warn (NotParsable filename) (filename, loc) Major

-- | Dumps a manifest of all coding style issues in format
-- `<code>:<description>`.
dumpManifest :: String
dumpManifest = foldr mergeLines "" (merge <$> getIssuesList)
  where
    merge (a, b) = a ++ ':':b
    mergeLines e acc = e ++ '\n':acc

-- | Appends a vague description of issues to style-student.txt
outputVague :: [Issue] -> IO ()
outputVague i = appendFile "style-student.txt" (toString $ accumulate i)
  where
    accumulate :: [Issue] -> [(Int, Issue)]
    accumulate = foldr (\e acc ->  ) []
    toString :: [(Int, Issue)] -> String
    toString l = concat $ ( \ (x, issue) -> showVague issue x) <$> l

-- | Creates a vague description of a given issue.
showVague :: Issue    -- ^ The issue
          -> Int      -- ^ The number of times it was raised
          -> String
showVague issue n =
  code ++ " rule has been violated " ++ show n ++ " times: " ++ des ++ '\n'
  where
    code = fst $ getIssueDesc issue
    des = snd $ getIssueDesc issue

