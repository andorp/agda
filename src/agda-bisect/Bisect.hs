import Control.Exception
import Control.Monad
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import GHC.IO.Encoding
import Options.Applicative
import System.Directory
import System.Exit
import System.IO
import System.Process
import System.Timeout
import Text.PrettyPrint.ANSI.Leijen hiding ((<>), (<$>))
import qualified Text.PrettyPrint.ANSI.Leijen as PP

-- | A string used to detect internal errors.

internalErrorString :: String
internalErrorString =
  "An internal error has occurred. Please report this as a bug."

-- | Strings that are used to signal to continuous integration systems
-- that this commit should be skipped.

ciSkipStrings :: [String]
ciSkipStrings = ["[ci skip]", "[skip ci]"]

-- | Default flags given to Agda.

defaultFlags :: [String]
defaultFlags =
  [ "--ignore-interfaces"
  , "--no-default-libraries"
  ]

-- | The path to the Agda executable.

agda :: FilePath
agda = ".cabal-sandbox/bin/agda"

-- | Options.

data Options = Options
  { mustSucceed               :: Bool
  , mustOutput, mustNotOutput :: [String]
  , mustFinishWithin          :: Maybe Int
  , extraArguments            :: Bool
  , compiler                  :: String
  , skipStrings               :: [String]
  , logFile                   :: Maybe String
  , start                     :: Either FilePath (String, String)
  , scriptOrArguments         :: Either (FilePath, [String]) [String]
  }

-- | Parses command-line options. Prints usage information and aborts
-- this program if the options are malformed (or the help flag is
-- given).

options :: IO Options
options =
  execParser
    (info (helper <*> opts)
          (header "Git bisect wrapper script for the Agda code base" <>
           footerDoc (Just msg)))
  where
  opts = Options
    <$> (not <$>
         (switch $
            long "must-fail" <>
            help "The command must fail (by default it must succeed)"))
    <*> many
          (strOption (long "must-output" <>
                      help "The command must output STRING" <>
                      metavar "STRING"))
    <*> ((\ss ms -> maybeToList ms ++ ss) <$>
         many
           (strOption (long "must-not-output" <>
                       help "The command must not output STRING" <>
                       metavar "STRING")) <*>
         optional
           (flag' internalErrorString
                  (long "no-internal-error" <>
                   help ("The command must not output " ++
                         show internalErrorString))))
    <*> (optional $
           option
             (do n <- auto
                 if n < 0 || n > maxBound `div` 10^6 then
                   readerError "Argument out of range"
                  else
                   return (n * 10^6))
             (long "timeout" <>
              metavar "N" <>
              help ("The command must finish in less than " ++
                    "(approximately) N seconds")))
    <*> (not <$>
         switch (long "no-extra-arguments" <>
                 help "Do not give any extra arguments to Agda"))
    <*> strOption (long "compiler" <>
                   help "Use COMPILER to compile Agda" <>
                   metavar "COMPILER" <>
                   value "ghc" <> showDefault <>
                   action "file")
    <*> ((\skip -> if skip then ciSkipStrings else []) <$>
         switch (long "skip-skipped" <>
                 help ("Skip commits with commit messages " ++
                       "containing one of the following strings: " ++
                       intercalate ", " (map show ciSkipStrings))))
    <*> optional
          (strOption (long "log" <>
                      help "Store a git bisect log in FILE" <>
                      metavar "FILE" <>
                      action "file"))
    <*> (((\b g -> Right (b, g)) <$>
          strOption (long "bad" <>
                     metavar "BAD" <>
                     help "Bad commit" <>
                     completer commitCompleter) <*>
          strOption (long "good" <>
                     metavar "GOOD" <>
                     help "Good commit" <>
                     completer commitCompleter))
           <|>
         (Left <$>
          strOption (long "replay" <>
                     metavar "LOG" <>
                     help "Replay the git bisect log in LOG" <>
                     action "file")))
    <*> ((Right <$>
          many (strArgument (metavar "ARGUMENTS..." <>
                             help "The arguments supplied to Agda")))
           <|>
         ((\prog args -> Left (prog, args)) <$>
          strOption (long "script" <>
                     metavar "PROGRAM" <>
                     help ("Do not invoke Agda directly, run " ++
                           "PROGRAM instead") <>
                     action "command") <*>
          many
            (strArgument (metavar "PROGRAM ARGUMENTS..." <>
                          help ("Extra arguments for the " ++
                                "--script program")))))

  paragraph ss      = fillSep (map string $ words $ unlines ss)
  d1 `newline` d2   = d1 PP.<> hardline PP.<> d2
  d1 `emptyLine` d2 = d1 PP.<> hardline PP.<> hardline PP.<> d2

  msg = foldr1 emptyLine
    [ paragraph
        [ "For every step of the bisection process this script tries to"
        , "compile Agda, run the resulting program (if any) with the"
        , "given arguments, and determine if the result is"
        , "satisfactory."
        ]

    , paragraph
        [ "Start the script from the root directory of an Agda"
        , "repository. The script takes care of invoking various"
        , "\"git bisect\" subcommands (start, replay, reset, good,"
        , "bad, skip). Feel free to use \"git bisect visualize\" or"
        , "\"git bisect log\" to inspect the script's progress."
        ]

    , paragraph
        [ "Use \"--\" to signal that the remaining arguments are"
        , "not options to this script (but to Agda or the --script"
        , "program)."
        ]

    , paragraph
        [ "The script inserts the following flags before ARGUMENTS,"
        , "unless --no-extra-arguments has been given (and only if"
        , "agda --help indicates that they are available):"
        ] `newline`
      indent 2 (foldr1 newline $ map string defaultFlags)

    , paragraph
        [ "The --script program, if any, is called with the path to the"
        , "Agda executable as the first argument. Note that usual"
        , "platform conventions (like the PATH) are used to determine"
        , "what program PROGRAM refers to."
        ]

    , paragraph
        [ "You should install suitable versions of the following"
        , "commands before running the script (in addition to the"
        , "COMPILER):"
        ] PP.<$>
      indent 2 (fillSep $ map string ["cabal", "git", "sed"])

    , paragraph
        [ "The script may not work on all platforms." ]
    ]

  commitCompleter = mkCompleter $ \prefix -> do
    -- The man page for one version of git rev-parse states that
    -- "While the ref name encoding is unspecified, UTF-8 is preferred
    -- as some output processing may assume ref names in UTF-8".
    (code, out, _) <- withUTF8Ignore $
                        readProcessWithExitCode
                          "git" ["tag", "--list", "*"] ""
    return $
      if code == ExitSuccess then
        filter (prefix `isPrefixOf`) $ lines out
       else
        []

-- | The top-level program.

main :: IO ()
main = do
  opts <- options

  sandboxExists <- callProcessWithResultSilently
                     "cabal" ["sandbox", "list-sources"]
  unless sandboxExists $
    callProcess "cabal" ["sandbox", "init"]

  bisect opts

-- | Performs the bisection process.

bisect :: Options -> IO ()
bisect opts =
  initialise
    `finally`
  callProcess "git" ["bisect", "reset"]
  where
  initialise :: IO ()
  initialise = do
    case start opts of
      Left log          -> callProcess "git" ["bisect", "replay", log]
      Right (bad, good) -> callProcess "git"
                                       ["bisect", "start", bad, good]

    -- It seems as if git bisect log returns successfully iff
    -- bisection is in progress.
    inProgress <- callProcessWithResultSilently "git" ["bisect", "log"]
    when inProgress run

  currentCommit :: IO String
  currentCommit =
    withEncoding char8 $
      readProcess "git" ["rev-parse", "HEAD"] ""

  run :: IO ()
  run = do
    before <- currentCommit

    msg <- withUTF8Ignore $
             readProcess "git" [ "show"
                               , "--no-patch"
                               , "--pretty=format:%B"
                               , "--encoding=UTF-8"
                               , "HEAD"
                               ] ""
    let skip = any (`isInfixOf` msg) (skipStrings opts)

    r <- if skip then return "skip" else
          uncurry bracket_ makeBuildEasier $ do
            ok <- installAgda opts
            if not ok then
              return "skip"
             else do
              ok <- runAgda opts
              return $ if ok then "good" else "bad"

    ok <- callProcessWithResult "git" ["bisect", r]

    case logFile opts of
      Nothing -> return ()
      Just f  -> do
        s <- withEncoding char8 $
               readProcess "git" ["bisect", "log"] ""
        withBinaryFile f WriteMode $ \h -> hPutStr h s

    when ok $ do
      after <- currentCommit
      when (before /= after) run

-- | Runs Agda. Returns 'True' iff the result is satisfactory.

runAgda :: Options -> IO Bool
runAgda opts = do
  (prog, args) <-
    case scriptOrArguments opts of
      Left (prog, args) -> return (prog, agda : args)
      Right args        -> do
        flags <- if extraArguments opts then do
                   help <- readProcess agda ["--help"] ""
                   return $ filter (`isInfixOf` help) defaultFlags
                  else
                   return []
        return (agda, flags ++ args)

  putStrLn $ "Command: " ++ showCommandForUser prog args

  let maybeTimeout = case mustFinishWithin opts of
        Nothing -> fmap Just
        Just n  -> timeout n
  result <- maybeTimeout (readProcessWithExitCode prog args "")
  case result of
    Nothing -> do
      putStrLn "Timeout"
      return False
    Just (code, out, err) -> do
      let occurs s       = s `isInfixOf` out || s `isInfixOf` err
          success        = code == ExitSuccess
          expectedResult = mustSucceed opts == success
          result         =
            expectedResult
               &&
            all occurs (mustOutput opts)
               &&
            not (any occurs (mustNotOutput opts))

      putStrLn $
        "Result: " ++
        (if success then "Success" else "Failure") ++
        " (" ++ (if expectedResult then "good" else "bad") ++ ")"
      unless (null out) $ putStr $ "Stdout:\n" ++ indent out
      unless (null err) $ putStr $ "Stderr:\n" ++ indent err
      putStrLn $ "Verdict: " ++ if result then "Good" else "Bad"

      return result
  where
  indent = unlines . map ("  " ++) . lines

-- | Tries to install Agda.

installAgda :: Options -> IO Bool
installAgda opts = do
  ok <- cabalInstall opts "Agda.cabal"
  if not ok then
    return False
   else do
    let executable = "src/main/Agda-executable.cabal"
    exists <- doesFileExist executable
    if exists then
      cabalInstall opts executable
     else
      return True

-- | Tries to install the package in the given cabal file.

cabalInstall :: Options -> FilePath -> IO Bool
cabalInstall opts file =
  callProcessWithResult "cabal"
    [ "install"
    , "--force-reinstalls"
    , "--disable-library-profiling"
    , "--disable-documentation"
    , "--with-compiler=" ++ compiler opts
    , file
    ]

-- | The first command tries to increase the chances that Agda will
-- build. The second command undoes any changes performed to the
-- repository.

makeBuildEasier :: (IO (), IO ())
makeBuildEasier =
  (callProcess "sed"
     [ "-ri"
     , "-e", "s/cpphs >=[^,]*/cpphs/"
     , "-e", "s/alex >=[^,]*/alex/"
     , "-e", "s/geniplate[^,]*/geniplate-mirror/"
     , "-e", "s/unordered-containers[^,]*/unordered-containers/"
     , "Agda.cabal"
     ]
  , callProcess "git" ["reset", "--hard"]
  )

-- | Runs the given program with the given arguments. Returns 'True'
-- iff the command exits successfully.

callProcessWithResult :: FilePath -> [String] -> IO Bool
callProcessWithResult prog args = do
  code <- waitForProcess =<< spawnProcess prog args
  return (code == ExitSuccess)

-- | Like 'callProcessWithResult', but the process does not inherit
-- stdin/stdout/stderr (and @"UTF-8//IGNORE"@ is used as the locale
-- encoding).

callProcessWithResultSilently :: FilePath -> [String] -> IO Bool
callProcessWithResultSilently prog args = do
  (code, _, _) <-
    withUTF8Ignore $
      readProcessWithExitCode prog args ""
  return (code == ExitSuccess)

-- | Runs the given action using the given 'TextEncoding' as the
-- locale encoding.

withEncoding :: TextEncoding -> IO a -> IO a
withEncoding enc action = do
  locale <- getLocaleEncoding
  bracket_ (setLocaleEncoding enc)
           (setLocaleEncoding locale)
           action

-- | Runs the given action using @"UTF-8//IGNORE"@ as the locale
-- encoding.

withUTF8Ignore :: IO a -> IO a
withUTF8Ignore action = do
  utf8Ignore <- mkTextEncoding "UTF-8//IGNORE"
  withEncoding utf8Ignore action
