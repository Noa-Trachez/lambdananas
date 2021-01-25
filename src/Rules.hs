module Rules where

import Language.Haskell.Exts.Syntax
import Language.Haskell.Exts.SrcLoc
import Parser
import Control.Monad
import Control.Monad.Writer
import Data.Foldable
import Debug.Trace

type Check = [Decl SrcSpanInfo] -> [Warn]

data Issue = BadIf
           | BadDo
           | BadReturn
           | BadGuard
           | LineTooLong
           | FunctionTooBig
           | NoSig String
           | BadFun String
           | Debug String
           deriving Eq

issues :: Issue -> (String,String)
issues BadIf =          ("C1", "nested IFs")  -- C cond. branching
issues BadGuard =       ("C2", "guard should be a pattern")  -- C cond. branch.
issues BadDo =          ("D1", "useless DO")  -- D do and generators
issues BadReturn =      ("D2", "useless generator")  -- D do and generators
issues LineTooLong =    ("F3", "line too long")  -- D do and generators
issues FunctionTooBig = ("F4", "function too big")  -- D do and generators
issues (BadFun s) =     ("B1", "banned function ("++s++")") -- Banned funcs
issues (NoSig s) =      ("T1", s ++ " has no signature")  -- T types
issues (Debug s) =      ("XX", s) -- DEBUG

instance Show Issue where
  show i = let (idd, msg) = issues i in idd ++ " # " ++ msg
  
data Warn = Warn { what :: Issue
                 , _location :: (String, Int)
                 } deriving Eq

instance Show Warn where
  show (Warn w (f, l)) = f ++ ":" ++ show l ++ ":" ++ show w

instance Ord Warn where
  compare (Warn _ (s1,l1)) (Warn _ (s2,l2)) | s1 == s2 = compare l1 l2
                                            | otherwise = compare s1 s2

{- CHECK CASCADING IFS -}
checkIfs :: Check
checkIfs = join . explore checkIf
  where checkIf (NExp (If ssi _ ift ife)) | countIfs ift ife >= 1 =
                                                  [Warn BadIf (getLoc ssi)]
        checkIf _ = []                                                  
        countIfs ifthen ifelse = inspectExpr countIf ifthen <>
                                 inspectExpr countIf ifelse
        countIf :: Node -> Sum Int
        countIf (NExp If{}) = Sum 1
        countIf _ = Sum 0

{- CHECK USELESS DOs -}
checkDos :: Check
checkDos = join . explore checkDo
  where checkDo (NExp (Do ssi body)) | countGenerators body < 1 =
                                       [Warn BadDo (getLoc ssi)]
        checkDo _ = []
        countGenerators = foldMap (countGenerator . NSmt)
        countGenerator :: Node -> Sum Int
        countGenerator = checkGen (\ _ isRet ->
                                     if isRet then Sum 0 else Sum 1)

{- CHECK USELESS Returns -}
checkReturns :: Check
checkReturns = join . explore checkReturn
  where checkReturn (NExp (Do _ body)) =
          foldMap (badReturns . NSmt) body
        checkReturn _ = []
        badReturns = checkGen toWarn
        toWarn ssi True = [Warn BadReturn (getLoc ssi)]
        toWarn _ _ = []

{- auxiliary functions for checkDos and checkReturns -}
checkGen :: Monoid m => (SrcSpanInfo -> Bool -> m) -> Node -> m
checkGen f (NSmt (Generator ssi _ e1)) = f ssi $ isReturn e1
checkGen _ _ = mempty

isReturn :: Exp SrcSpanInfo -> Bool
isReturn (App _ (Var _ (UnQual _ (Ident _ f))) _) = isRetOrPure f
isReturn (InfixApp _ (Var _ (UnQual _ (Ident _ f))) _ _) = isRetOrPure f
isReturn (Paren _ e) = isReturn e
isReturn _ = False

isRetOrPure :: String -> Bool
isRetOrPure "return" = True
isRetOrPure "pure" = True
isRetOrPure _ = False

{- CHECK IF ALL TOP DECLARATION HAS A TYPE SIGNATURE -}
checkSigs :: Check
checkSigs lst = join $ map genWarn binds
  where sigsAndBinds = explore collectSigs lst
        sigs = foldMap fst sigsAndBinds
        binds = foldMap getBind sigsAndBinds
        getBind (_,l) = if null l then [] else [head l]
        genWarn (fct, ssi) | fct `notElem` sigs =
                             [Warn (NoSig fct) (getLoc ssi)]
        genWarn _ = []

collectSigs :: Node -> ([String], [(String, SrcSpanInfo)])
collectSigs (NDec (TypeSig _ (x:_) _ )) = ([getIdent x],[])
collectSigs (NDec (PatBind ssi (PVar _ idt) _ _ )) =
  ([],[(getIdent idt, ssi)])
collectSigs (NDec (FunBind ssi (Match _ idt _ _ _:_))) =
  ([],[(getIdent idt, ssi)])
collectSigs _ = ([],[])

{- CHECK BAD GUARDS -}
checkGuards :: Check
checkGuards lst = join $ explore checkGuard lst
  where checkGuard (NDec (FunBind _ m)) =
          fold $ zipWith toWarns (vars m) (matchs m)
        checkGuard _ = []
        vars match = map (inspectMatch collectVar) match
        matchs match = map (inspectMatch collectGuards) match
        collectVar (NPat (PVar _ idt)) = [getIdent idt]
        collectVar _ = []
        collectGuards (NSmt (Qualifier _ expr)) = [expr]
        collectGuards _ = []
    
toWarns :: [String] -> [Exp SrcSpanInfo] -> [Warn]
toWarns vars = foldMap (inspectExpr toWarn)
  where toWarn (NExp (InfixApp ssi e1 e2 e3))
          | isBadGuard vars e1 e2 e3 = [Warn BadGuard (getLoc ssi)]
        toWarn _ = []

isBadGuard :: [String] -> Exp SrcSpanInfo -> QOp SrcSpanInfo ->
              Exp SrcSpanInfo -> Bool
isBadGuard vars e1 e2 e3 | isVar e1 && isEq e2 && isLit e3 = True
                         | isLit e1 && isEq e2 && isVar e3 = True
  where isVar (Var _ (UnQual _ (Ident _ x))) | x `elem` vars = True
        isVar _ = False
        isEq (QVarOp _ (UnQual _ (Symbol _ "=="))) = True
        isEq _ = False
isBadGuard _ _ _ _ = False

isLit :: Exp SrcSpanInfo -> Bool
isLit Lit{} = True
isLit Con{} = True
isLit (App _ Con{} _) = True
isLit (List _ []) = True
isLit _ = False

{- CHECK LINES LENGTH AND FUNCTION SIZE -}
checkLines :: Check
checkLines lst = uniqWarn $ join $ explore checkLine lst
  where checkLine (NDec (FunBind _ matches)) = foldMap checkLine' matches
        checkLine (NDec decl@PatBind{}) = checkLine' decl
        checkLine _ = []
        checkLine' decl = uniqFunWarn $ foldMap toWarn decl
        toWarn ssi@(SrcSpanInfo (SrcSpan _f l1 _c1 l2 c2) _) =
          [Warn FunctionTooBig (getLoc ssi) | l2-l1 >= 10]
          ++
          [Warn LineTooLong (getLoc ssi) | l1==l2 && c2 > 80]

uniqFunWarn :: [Warn] -> [Warn]
uniqFunWarn [] = []
uniqFunWarn (w1@(Warn FunctionTooBig _):xs)
  | FunctionTooBig `elem` map what xs = uniqFunWarn xs
  | otherwise = w1 : uniqFunWarn xs
uniqFunWarn (x:xs) = x:uniqFunWarn xs

uniqWarn :: [Warn] -> [Warn]
uniqWarn [] = []
uniqWarn (x:xs) | x `elem` xs  = uniqWarn xs
                | otherwise = x : uniqWarn xs

{- CHECK FORBIDEN FUNCTIONS -}
checkFuncs :: [String] -> Check
checkFuncs banned = join . explore checkFct
  where checkFct (NExp (App _ a _)) = getName a
        checkFct (NExp (InfixApp _ _ a _)) = getQop a
        checkFct (NExp a) = getName a
        checkFct e = [] --trace (">>> "++show e++"\n") []
        getQop (QVarOp ssi (UnQual _ (Symbol _ name))) = check' ssi name
        getQop QConOp{} = [] -- [Warn (BadFun name) (getLoc ssi)]
        getQop e = [] -- trace (show e) [] -- error (show e)
        getName (Con ssi (UnQual _ (Ident _ name))) = check' ssi name
        getName (Var ssi (UnQual _ (Ident _ name))) = check' ssi name
        getName (Var ssi (UnQual _ (Symbol _ name))) = check' ssi name
        getName (Lit ssi (String _ name _)) = check' ssi name
        getName App{} = []
        getName InfixApp{} = []
        getName (ListComp ssi _ _) = [Warn (BadFun "*ListComp*") (getLoc ssi)]
        getName e = [] -- trace (show e) [] -- error (show e)
        check' ssi name = if elem name banned
                          then [Warn (BadFun name) (getLoc ssi)]
                          else []
