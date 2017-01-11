{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

module Pact.Analyze.Types where

import Control.Monad.Trans.Reader
import Control.Monad.IO.Class (liftIO)
import Control.Lens hiding ((.=))
import Pact.Typecheck
import Pact.Types
import Data.Either
import Data.Decimal
import Data.Aeson hiding (Object)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>),(<$$>))
import GHC.Generics

import SmtLib.Syntax.Syntax
import SmtLib.Parsers.CommandsParsers (parseCommand)
import Text.Parsec (parse)
import qualified SmtLib.Syntax.Syntax as Smt
import qualified SmtLib.Syntax.ShowSL as SmtShow

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Yaml as Yaml
import qualified Text.Parsec as Parsec
import qualified SmtLib.Parsers.CommandsParsers as SmtParser

data SymType = SymInteger
  | SymDecimal
  | SymBool
  | SymString
  deriving (Show, Eq, Ord, Generic, ToJSON)

newtype SymName = SymName { unSymName :: String } deriving (Show, Eq)

instance ToJSON SymName where
  toJSON (SymName s) = toJSON s

data TrackingStatus = Tracked
  | Untracked {_tWhy :: String}
  | LostTrack {_tWhy :: String}
  deriving (Show, Eq, Generic, ToJSON)

data SymVar = SymVar
  { _svName :: SymName
  , _svType :: Maybe SymType
  , _svTracked :: TrackingStatus
  } deriving (Show, Eq, Generic, ToJSON)
makeLenses ''SymVar

data ProverCtx = ProverCtx
  { _pcInputArgs :: Map TcId SymVar
  } deriving (Show, Eq)
makeLenses ''ProverCtx

data ProverState = ProverState
  { _psVars :: Map Node SymVar
  , _psNodeSMT :: [Command]
  } deriving (Show, Eq)
makeLenses ''ProverState

instance ToJSON ProverState where
  toJSON ProverState{..} = do
    let declrs = init . SmtShow.showSL <$> rights (symVarToDeclareConst <$> Map.elems _psVars)
    toJSON $ declrs ++ (SmtShow.showSL <$> _psNodeSMT)

data SymAst =
  IfBranch
    { _ifbrCond :: Smt.Term
    , _ifbrTrue :: SymAst
    , _ifbrFalse :: SymAst
    , _saProverState :: ProverState } |
  EnforceConstraint
    { _ecFailsIf :: String
    , _saRest :: SymAst
    , _saProverState :: ProverState } |
  ErrorLeaf
    { _elWhy :: String
    , _saProverState :: ProverState } |
  ReturnLit
    { _rlResult :: Literal
    , _saProverState :: ProverState } |
  ReturnVar
    { _rvResult :: SymVar
    , _saProverState :: ProverState } |
  ReturnUnit |
  Terminate |
  EnforceKeySet
    { _wkKeySet :: String
    , _saRest :: SymAst
    , _saProverState :: ProverState } |
  WithRead
      { _wrTableName :: String
      , _wrKey :: String
      , _saRest :: SymAst
      , _saProverState :: ProverState } |
  TableInsert
    { _tiTableName :: String
    , _saRest :: SymAst
    , _saProverState :: ProverState } |
  TableUpdate
    { _tiTableName :: String
    , _saRest :: SymAst
    , _saProverState :: ProverState } |
  CannotAnalyze
    { _elWhy :: String
    , _saProverState :: ProverState }
  deriving (Show, Eq)

instance ToJSON SymAst where
  toJSON IfBranch{..} = toJSON
           [ object [ "node" .= ("if" :: String) ]
           , object ["state" .= _saProverState]
           , object ["cond" .= (SmtShow.showSL _ifbrCond)]
           , object ["true" .= _ifbrTrue]
           , object ["false" .= _ifbrFalse]
           ]
  toJSON EnforceConstraint{..} =
    toJSON [ object ["node" .= ("enforce" :: String)]
           , object ["state" .= _saProverState]
           , object ["failsIf" .= _ecFailsIf]
           , object ["rest" .= _saRest]
           ]
  toJSON ErrorLeaf{..} =
    toJSON [ object ["node" .= ("error" :: String)]
           , object ["state" .= _saProverState]
           , object ["why" .= _elWhy]
           ]
  toJSON ReturnLit{..} =
    toJSON [ object ["node" .= ("return-literal" :: String)]
           , object ["state" .= _saProverState]
           , object ["returned_literal" .= _rlResult]
           ]
  toJSON ReturnVar{..} =
    toJSON [ object ["node" .= ("return-variable" :: String)]
           , object ["state" .= _saProverState]
           , object ["returned_variable" .= _rvResult]
           ]
  toJSON ReturnUnit =
    toJSON [ object ["node" .= ("return-unit" :: String)]
           ]
  toJSON Terminate =
    toJSON [ object ["node" .= ("terminate" :: String)]
           ]
  toJSON EnforceKeySet{..} =
    toJSON [ object ["node" .= ("enforce-keyset" :: String)]
           , object ["state" .= _saProverState]
           , object ["required_keyset" .= _wkKeySet]
           , object ["rest" .= _saRest]
           ]
  toJSON WithRead{..} =
    toJSON [ object ["node" .= ("with-read" :: String)]
           , object ["state" .= _saProverState]
           , object ["table" .= _wrTableName]
           , object ["lookup_key" .= _wrKey]
           , object ["rest" .= _saRest]
           ]
  toJSON TableInsert{..} =
    toJSON [ object ["node" .= ("Insert" :: String)]
           , object ["state" .= _saProverState]
           , object ["table" .= _tiTableName]
           , object ["rest" .= _saRest]
           ]
  toJSON TableUpdate{..} =
    toJSON [ object ["node" .= ("Insert" :: String)]
           , object ["state" .= _saProverState]
           , object ["table" .= _tiTableName]
           , object ["rest" .= _saRest]
           ]
  toJSON CannotAnalyze{..} =
    toJSON [ object ["node" .= ("CannotAnalyze" :: String)]
           , object ["state" .= _saProverState]
           , object ["why" .= _elWhy]
           ]

ppSymAst :: SymAst -> IO ()
ppSymAst = BS8.putStrLn . Yaml.encode

type PactAnalysis a = ReaderT ProverState IO a

data LitVal =
    LVDecimal Decimal
  | LVBool Bool
  | LVInteger Integer


isCmpOperator :: String -> Bool
isCmpOperator s = Set.member s $ Set.fromList [">", "<", ">=", "<=", "="]

isLogicalOperator :: String -> Bool
isLogicalOperator s = Set.member s $ Set.fromList ["=", "and", "or", "not"]

isNumericalOperator :: String -> Bool
isNumericalOperator s = Set.member s $ Set.fromList ["+", "-", "*", "/"]

isBasicOperator :: String -> Bool
isBasicOperator s = isCmpOperator s || isLogicalOperator s || isNumericalOperator s

basicOperatorToQualId :: String -> Either String QualIdentifier
basicOperatorToQualId o
  | o == ">" = Right $ QIdentifier $ ISymbol ">"
  | o == ">=" = Right $ QIdentifier $ ISymbol ">="
  | o == "<" = Right $ QIdentifier $ ISymbol "<"
  | o == "<=" = Right $ QIdentifier $ ISymbol "<="
  | o == "=" = Right $ QIdentifier $ ISymbol "="
  | o == "and" = Right $ QIdentifier $ ISymbol "and"
  | o == "or" = Right $ QIdentifier $ ISymbol "or"
  | o == "not" = Right $ QIdentifier $ ISymbol "not"
  | o == "+" = Right $ QIdentifier $ ISymbol "+"
  | o == "-" = Right $ QIdentifier $ ISymbol "-"
  | o == "*" = Right $ QIdentifier $ ISymbol "*"
  | o == "/" = Right $ QIdentifier $ ISymbol "/"
  | otherwise = Left $ "Operator " ++ o ++ " is not yet supported!"

isAppView :: AST Node -> (Bool, AST Node)
isAppView app@(App _ _ _) = (True, app)
isAppView _ = (False, undefined)

isInsertOrUpdate :: Fun Node -> (Bool, String)
isInsertOrUpdate (NativeFunc "insert") = (True, "insert")
isInsertOrUpdate (NativeFunc "update") = (True, "update")
isInsertOrUpdate err = (False, error $ "isInsertOrUpdate view pattern failure, wanted insert or update string, got: " ++ show err)

ofPrimType :: Node -> Maybe PrimType
ofPrimType (Node _ (TyPrim ty)) = Just ty
ofPrimType _ = Nothing

tcIdToUniqueId :: TcId -> String
tcIdToUniqueId (TcId _ name' nonce') = name' ++ show nonce'

tcIdToSymName :: TcId -> SymName
tcIdToSymName = SymName . tcIdToUniqueId

nodeToUniqueId :: Node -> String
nodeToUniqueId (Node tcId _) = tcIdToUniqueId tcId

pattern OfPrimType pType <- (ofPrimType -> Just pType)

pattern RawTableName t <- (Table (Node (TcId _ t _) _))

pattern Obj_Key_Val key' val' <- (Prim _ (PrimLit (LString key')), val')

pattern NativeFunc f <- (FNative _ f _ _)
pattern NativeFuncSpecial f bdy <- (FNative _ f _ (Just (_,bdy)))

pattern AST_Lit lit <- (Prim _ (PrimLit lit))
pattern AST_Obj objNode kvs <- (Object objNode kvs)

pattern Args_Var var <- [Var var]
pattern Args_Lit lit <- [AST_Lit lit]
pattern Args_Var_Var var1 var2 <- [(Var var1),(Var var2)]
pattern Args_Var_Lit var lit <- [(Var var),AST_Lit lit]
pattern Args_Lit_Var lit var <- [AST_Lit lit,(Var var)]
pattern Args_App_App app1 app2 <- [(isAppView -> (True, app1)),(isAppView -> (True, app2))]
pattern Args_App_Lit_Var app' lit var <- [(isAppView -> (True,app')),AST_Lit lit,(Var var)]
pattern Args_App_Lit app' lit' <- [(isAppView -> (True,app')),AST_Lit lit']
pattern Args_App_Lit_Lit app' lit1 lit2 <- [(isAppView -> (True,app')),AST_Lit lit1,AST_Lit lit2]

pattern NativeFunc_Lit_Var f lit' var' <- (App _ (NativeFunc f) (Args_Lit_Var lit' var'))
pattern NativeFunc_Var_Lit f var' lit' <- (App _ (NativeFunc f) (Args_Var_Lit var' lit'))
pattern NativeFunc_Var_Var f var1 var2 <- (App _ (NativeFunc f) (Args_Var_Var var1 var2))
pattern NativeFunc_App_App f app1 app2 <- (App _ (NativeFunc f) (Args_App_App app1 app2))
pattern IF_App_Lit_Lit app' lit1 lit2 <- (App _ (NativeFunc "if") (Args_App_Lit_Lit app' lit1 lit2))
pattern ENFORCE_App_msg app' msg' <- (App _ (NativeFunc "enforce") (Args_App_Lit app' (LString msg')))
pattern BINDING bindings' bdy' <- (Binding _ bindings' bdy' _)
pattern ENFORCEKEYSET keyset' <- (App _ (NativeFunc "enforce-keyset") (Args_Lit (LString keyset')))
pattern INSERT_or_UPDATE fnName' table' key' kvs' <- (App _ (isInsertOrUpdate -> (True, fnName')) [RawTableName table', key', AST_Obj _ kvs'])
pattern WITHREAD table' key' bindings' bdy' <- (App _ (NativeFuncSpecial "with-read" (BINDING bindings' bdy')) [RawTableName table', key'])
-- Unsupported currently
pattern READ <- (App _ (NativeFunc "read") _)

varToTerm :: Node -> PactAnalysis (Either String Smt.Term)
varToTerm n = do
  sVar <- Map.lookup n <$> view psVars
  return $ case sVar of
    Nothing -> Left $ "Variable " ++ show n ++ "not found!"
    Just SymVar{..} -> case _svTracked of
      Tracked -> Right $ TermQualIdentifier $ QIdentifier $ ISymbol $ unSymName _svName
      err -> Left $ "Variable found but tracking has failed: " ++ show err

literalToTerm :: Literal -> Either String Smt.Term
literalToTerm (LBool v) = Right $ TermQualIdentifier $ QIdentifier $ ISymbol (if v then "true" else "false")
literalToTerm (LString v) = Right $ TermSpecConstant $ SpecConstantString $ show v
literalToTerm (LInteger v) = Right $ TermSpecConstant $ SpecConstantNumeral v
literalToTerm (LDecimal v) = Right $ TermSpecConstant $ SpecConstantDecimal $ show v
literalToTerm (LTime _) = Left $ "Time base proving is currently unsupported"

mkPureEquationTerm :: AST Node -> PactAnalysis (Either String Smt.Term)
mkPureEquationTerm (NativeFunc_Var_Lit f v l)
  | isBasicOperator f = do
      varAsTerm <- varToTerm v
      litAsTerm <- return $ literalToTerm l
      op <- return $ basicOperatorToQualId f
      case (op, varAsTerm, litAsTerm) of
        (Right op', Right v', Right l') -> return $ Right $ TermQualIdentifierT op' [v', l']
        err -> return $ Left $ "unable to analyze: " ++ show err
  | otherwise = return $ Left $ "Function " ++ show f ++ " is unsupported"
mkPureEquationTerm (NativeFunc_Lit_Var f l name')
  | isBasicOperator f = do
      varAsTerm <- varToTerm name'
      litAsTerm <- return $ literalToTerm l
      op <- return $ basicOperatorToQualId f
      case (op, litAsTerm, varAsTerm) of
        (Right op', Right l', Right v') -> return $ Right $ TermQualIdentifierT op' [l',v']
        err -> return $ Left $ "unable to analyze: " ++ show err
  | otherwise = return $ Left $ "Function " ++ show f ++ " is unsupported"
mkPureEquationTerm (NativeFunc_Var_Var f name1 name2)
  | isBasicOperator f = do
      var1AsTerm <- varToTerm name1
      var2AsTerm <- varToTerm name2
      op <- return $ basicOperatorToQualId f
      case (op, var1AsTerm, var2AsTerm) of
        (Right op', Right v1, Right v2) -> return $ Right $ TermQualIdentifierT op' [v1, v2]
        err -> return $ Left $ "unable to analyze: " ++ show err
  | otherwise = return $ Left $ "Function " ++ show f ++ " is unsupported"
mkPureEquationTerm (NativeFunc_App_App f app1 app2)
  | isLogicalOperator f = do
      app1' <- mkPureEquationTerm app1
      app2' <- mkPureEquationTerm app2
      op <- return $ basicOperatorToQualId f
      case (op, app1', app2') of
        (Right op', Right app1'', Right app2'') -> return $ Right $ TermQualIdentifierT op' [app1'', app2'']
        err -> return $ Left $ "unable to analyze: " ++ show err
mkPureEquationTerm (AST_Lit l) = return $ literalToTerm l
mkPureEquationTerm (Var name') = varToTerm name'
mkPureEquationTerm err = return $ Left $ "Unsupported construct found when constructing pure-equation term:\n" ++ show err

negatePureEquationTerm :: Smt.Term -> Smt.Term
negatePureEquationTerm t = TermQualIdentifierT (QIdentifier (ISymbol "not")) [t]

pureEquationTermToAssertion :: Smt.Term -> Command
pureEquationTermToAssertion t = Assert t

negateAssertion :: Command -> Command
negateAssertion (Assert t) = Assert $ negatePureEquationTerm t

convertType :: Node -> Maybe SymType
convertType (OfPrimType TyInteger) = Just SymInteger
convertType (OfPrimType TyBool) = Just SymBool
convertType (OfPrimType TyDecimal) = Just SymDecimal
convertType (OfPrimType TyString) = Just SymString
convertType _ = Nothing

symTypeToSortId :: SymType -> Either String Sort
symTypeToSortId SymInteger = Right $ SortId $ ISymbol "Int"
symTypeToSortId SymBool = Right $ SortId $ ISymbol "Bool"
symTypeToSortId SymDecimal = Right $ SortId $ ISymbol "Real"
symTypeToSortId SymString = Right $ SortId $ ISymbol "String"

constructSymVar :: Node -> SymVar
constructSymVar node'@(Node tcId _) = newVar
  where
    convType = convertType node'
    convName = tcIdToSymName tcId
    trackingStatus = case convType of
      Nothing -> Untracked "Unsupported Type"
      Just _ -> Tracked
    newVar = SymVar { _svName = convName, _svType = convType, _svTracked = trackingStatus}

symVarToDeclareConst :: SymVar -> Either String Command
symVarToDeclareConst SymVar{..} = case _svType of
  Nothing -> Left $ "SymVar Type is unsupported"
  Just t' -> symTypeToSortId t' >>= return . DeclareFun (unSymName _svName) []

analyzeFunction :: Fun Node -> IO SymAst
analyzeFunction (FDefun _ name' _ args' bdy') = do
  initialState <- return $ ProverState (Map.fromList $ (\x -> (x, constructSymVar x)) . _nnNamed <$> args') []
  runReaderT (analyze bdy') initialState

analyze :: [AST Node] -> PactAnalysis SymAst
analyze [] = return $ Terminate
analyze ((IF_App_Lit_Lit app' lit1 lit2):rest) = do
  initialState <- ask
  branchPoint <- mkPureEquationTerm app'
  case branchPoint of
    Left err -> error $ err
    Right smtTerm -> do
      trueAssert <- return $ pureEquationTermToAssertion smtTerm
      falseAssert <- return $ negateAssertion trueAssert
      return $ IfBranch
        { _ifbrCond = smtTerm
        , _ifbrTrue = ReturnLit { _rlResult = lit1
                                         , _saProverState = appendSmtCmds [trueAssert] initialState}
        , _ifbrFalse = ReturnLit { _rlResult = lit2
                                         , _saProverState = appendSmtCmds [falseAssert] initialState}
        , _saProverState = initialState
        }
analyze ((ENFORCE_App_msg app' msg'):rest) = do
  initialState <- ask
  branchPoint <- mkPureEquationTerm app'
  case branchPoint of
    Left err -> error $ "from enfoce: " ++ err
    Right smtTerm -> do
      trueAssert <- return $ pureEquationTermToAssertion smtTerm
      if null rest
        then return $ EnforceConstraint
          { _ecFailsIf = msg'
          , _saProverState = appendSmtCmds [trueAssert] initialState
          , _saRest = ReturnUnit
          }
        else do
          rest' <- local (appendSmtCmds [trueAssert]) $ analyze rest
          return $ EnforceConstraint
            { _ecFailsIf = msg'
            , _saProverState = appendSmtCmds [trueAssert] initialState
            , _saRest = rest'
            }
analyze ((BINDING bindings' ast'):rest) = do
  newState <- bindNewVars bindings'
  local (const newState) $ analyze ast'
analyze (AST_Lit lit':[]) = do
  s <- ask
  return $ ReturnLit
    { _rlResult = lit'
    , _saProverState = s}
analyze (AST_Lit lit':rest) = analyze rest -- this has no effect do just pass
analyze (Var var':[]) = do
  s <- ask
  psVars' <- view psVars
  case Map.lookup var' psVars' of
    Nothing -> error $ "Variable not found: " ++ show var' ++ " in " ++ show psVars'
    Just sVar -> return $ ReturnVar
      { _rvResult = sVar
      , _saProverState = s}
analyze (Var var':rest) = analyze rest -- this has no effect do just pass
analyze (ENFORCEKEYSET keyset':rest) = do
  block' <- analyze rest
  state' <- ask
  return $ EnforceKeySet
    { _wkKeySet = keyset'
    , _saProverState = state'
    , _saRest = block' }
analyze (INSERT_or_UPDATE fnName table key kvs:rest) = do
  objKey' <- return $ case key of
    Var node' -> nodeToUniqueId node'
    AST_Lit (LString v) -> v
    err -> error $ "insert's lookup key must be a string literal or a variable and not: " ++ show err
  mangledObjects <- return $ fmap (mangleObjToVar table) kvs
  newState <- bindNewVars mangledObjects
  rest' <- local (const newState) $ analyze rest
  return $ TableInsert
    { _tiTableName = table
    , _saRest = rest'
    , _saProverState = newState}
analyze (WITHREAD table' key' bindings' ast':rest) = do
  newState <- bindNewVars bindings'
  local (const newState) $ do
    st' <- ask
    rest' <- analyze ast'
    return $ WithRead
      { _wrTableName = table'
      , _wrKey = show $ key'
      , _saRest = rest'
      , _saProverState = st' }
analyze (READ:_rest) = error "Objects are not yet supported, which `read` returns. Please use `with-read` instead"
analyze err = error $ "Pattern match failure: " ++ show err

mangleObjToVar :: String -> (AST Node, AST Node) -> (Named Node, AST Node)
mangleObjToVar tableId (Prim (Node pTcId _) (PrimLit (LString field)), ast@(Var (Node varTcId varType))) =
  let node' = Node (TcId (_tiInfo pTcId) (tableId ++ "-insert-" ++ field) (_tiId varTcId)) varType
  in (Named (tableId ++ "insert-key") node',ast)

bindNewVars :: [(Named Node, AST Node)] -> PactAnalysis ProverState
bindNewVars [] = ask
bindNewVars (((Named _ node'), ast'):rest) = do
  curVars <- view psVars
  if Map.member node' curVars
    then error $ "Duplicate Variable Declared: " ++ show node' ++ " already in " ++ show curVars
    else do
      newSymVar <- return $ constructSymVar node'
      curSt <- ask
      local (psVars %~ (Map.insert node' newSymVar)) $ do
        relation <- constructVarRelation node' ast'
        local (psNodeSMT %~ (++ [relation])) $ bindNewVars rest

constructVarRelation :: Node -> AST Node -> PactAnalysis Command
constructVarRelation node' ast' = do
  varAsTerm <- varToTerm node'
  relation <- mkPureEquationTerm ast'
  case (varAsTerm, relation) of
    (Right v, Right r) -> return $ pureEquationTermToAssertion (TermQualIdentifierT (QIdentifier $ ISymbol "=") [v,r])
    err -> error $ "cannot construct var relation in: " ++ show err ++ " in\n" ++ show ast'

appendSmtCmds :: [Command] -> ProverState -> ProverState
appendSmtCmds cmds ps@ProverState{..} = ps { _psNodeSMT = _psNodeSMT ++ cmds }

-- helper stuff
_parseSmtCmd :: String -> Smt.Command
_parseSmtCmd s = let (Right f) = Parsec.parse SmtParser.parseCommand "" s in f

_getSampFunc :: String -> IO (Fun Node)
_getSampFunc s = fst <$> _infer "examples/analyze-tests/analyze-tests.repl" "analyze-tests" s

_analyzeSampFunc :: String -> IO ()
_analyzeSampFunc s = do
  a <- _getSampFunc s
  b <- analyzeFunction a
  ppSymAst b
