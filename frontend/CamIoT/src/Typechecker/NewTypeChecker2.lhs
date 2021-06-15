\documentclass{article}

%include lhs2TeX.fmt
%include lhs2TeX.sty
%include spacing.fmt

\long\def\ignore#1{}

\begin{document}

\ignore{
\begin{code}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
module Typechecker.NewTypeChecker2 where

import Data.Maybe
import Data.Foldable
import Data.List
import Data.Char
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Map as Map
import qualified Data.Set as Set

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer

import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as Lexer
import Text.Megaparsec.Debug

import Control.Applicative hiding (many, some, Const)
import Control.Monad.Combinators.Expr
import Control.Monad.Identity
import Data.Void

import System.Exit
import System.IO
import System.IO.Unsafe

trace :: Show a => a -> a
trace x = unsafePerformIO $ putStrLn (show x) >> return x
\end{code}
}

\begin{code}
data Type = TVar Ident
          | TInt
          | TFloat
          | TBool
          | TNil
          | TTup [Type]
          | TAdt UIdent [Type]
          | TLam Type Type
  deriving (Eq, Show)

args :: Type -> [Type]
args (TLam t1 t2) = t1 : args t2
args _            = []

construction :: Type -> Type
construction (TLam t1 t2) = construction t2
construction t            = t

funtype :: [Type] -> Type
funtype [t]        = t
funtype (t1:t2:ts) = TLam t1 (funtype (t2:ts))

data Ident = Ident String
  deriving (Eq, Show, Ord)

data UIdent = UIdent String
  deriving (Eq, Show, Ord)

data Pat a = PVar a Ident
           | PNil a
           | PConst a Lit
           | PWild a
           | PAs a Ident (Pat a)
           | PAdt a UIdent [Pat a]
           | PTup a [Pat a]
  deriving (Eq, Show)

patVar :: Pat a -> a
patVar p = case p of
  PVar a _   -> a
  PNil a     -> a
  PConst a _ -> a
  PWild a    -> a
  PAs a _ _  -> a
  PAdt a _ _ -> a
  PTup a _   -> a

data Lit = LInt Int
         | LFloat Double
         | LBool Bool
         | LNil
  deriving (Eq, Show)

data Exp a = EVar a Ident
           | ECon a UIdent
           | ELit a Lit
           | ECase a (Exp a) [(Pat a, Exp a)]
           | ETup a [(Exp a)]
           | EBin a (Exp a) (Exp a) (Binop a)
           | EUn a (Exp a) (Unop a)
           | ELam a (Pat a) (Exp a)
           | EApp a (Exp a) (Exp a)
           | ELet a (Pat a) (Exp a) (Exp a)
           | EIf a (Exp a) (Exp a) (Exp a)
  deriving (Eq, Show)

expVar :: Exp a -> a
expVar e = case e of
  EVar a _     -> a
  ECon a _     -> a
  ELit a _     -> a
  ECase a _ _  -> a
  ETup a _     -> a
  EBin a _ _ _ -> a
  EUn a _ _    -> a
  ELam a _ _   -> a
  EApp a _ _   -> a
  ELet a _ _ _ -> a
  EIf a _ _ _  -> a

data Binop a = Add a
             | Sub a
             | Mul a
             | Div a
             | OLT a
             | OLE a
             | OGT a
             | OGE a
             | OEQ a
             | And a
             | Or a
  deriving (Eq, Ord, Show)

binopVar :: Binop a -> a
binopVar op = case op of
  Add a -> a
  Sub a -> a
  Mul a -> a
  Div a -> a
  OLT a -> a
  OLE a -> a
  OGT a -> a
  OGE a -> a
  OEQ a -> a
  And a -> a
  Or  a -> a

setBinopVar :: a -> Binop b -> Binop a
setBinopVar a op = case op of
  Add _ -> Add a
  Sub _ -> Sub a
  Mul _ -> Mul a
  Div _ -> Div a
  OLT _ -> OLT a
  OLE _ -> OLE a
  OGT _ -> OGT a
  OGE _ -> OGE a
  OEQ _ -> OEQ a
  And _ -> And a
  Or _  -> Or a

data Unop a = Not a
  deriving (Eq, Show, Ord)

unopVar :: Unop a -> a
unopVar op = case op of
  Not a -> a

setUnopVar :: a -> Unop b -> Unop a
setUnopVar a op = case op of
  Not _ -> Not a

data Def a = DTypeSig Ident Type
           | DEquation a Ident [Pat a] (Exp a)
           | DDataDec UIdent [Ident] [(UIdent, Type)]
  deriving (Eq, Show)

getName :: Def a -> Ident
getName (DTypeSig id _)      = id
getName (DEquation _ id _ _) = id

defVar :: Def a -> Maybe a
defVar d = case d of
  DTypeSig _ _      -> Nothing
  DEquation a _ _ _ -> Just a

data Function a = Function
  { name      :: Ident
  , equations :: [Def a]
  , typesig   :: Maybe Type
  }
  deriving (Eq)

instance Print a => Show (Function a) where
  show = printTree

data Program a = Program
  { datatypes :: [ADT]
  , functions :: [Function a]
  , main      :: Function a
  }

type ADT = (UIdent, [Ident], [(UIdent, Type)])

instance Print a => Show (Program a) where
  show = printTree

mkProgram :: Eq a => [Def a] -> Program a
mkProgram defs =
  let (datadecs,funs)    = partitionDataDecs defs
      functions          = mkFunctions funs
      (main, functions') = partitionMain functions
  in Program (map unwrapDataDec datadecs) functions' main
  where
      unwrapDataDec (DDataDec uid vars cons) = (uid, vars, cons)

partitionDataDecs :: [Def a] -> ([Def a], [Def a])
partitionDataDecs ds = partition pred ds
  where
      pred d = case d of
        DDataDec _ _ _ -> True
        _              -> False

mkFunctions :: [Def a] -> [Function a]
mkFunctions defs = map toFunction $ groups defs

partitionMain :: Eq a => [Function a] -> (Function a, [Function a])
partitionMain funs = let main  = find ((==) (Ident "main") . name) funs
                         funs' = delete (fromJust main) funs
                     in (fromJust main, funs')

pred :: Def a -> Def a -> Bool
pred d1 d2 = getName d1 == getName d2

groups :: [Def a] -> [[Def a]]
groups defs = groupBy Typechecker.NewTypeChecker2.pred defs

-- assuming a singleton list is a DEquation, and that there are no
-- type signatures without equations
toFunction :: [Def a] -> Function a
toFunction [x]    = Function (getName x) [x] Nothing
toFunction (d:ds) = case d of
  DTypeSig id t -> Function id ds (Just t)
  -- In this case there was no declared type signature
  _             -> Function (getName d) (d:ds) Nothing

{-
exitcodes:
  1 - parse error
  2 - typecheck error
  3 - rename error
  4 - lambdalift error
  5 - monomorphise error
-}
compile :: String -> IO (Program Type, Subst)
compile fp = do
  contents <- TIO.readFile fp
  let processed = process contents
  let parsed    = parse pProgram fp processed
  case parsed of
    Left e  -> do hPutStrLn stderr $ show e
                  exitWith $ ExitFailure 1
    Right r -> do
      tc <- typecheck r
      case tc of
        Left e -> do hPutStrLn stderr e
                     exitWith $ ExitFailure 2
        Right r -> return r

tryParse :: String -> IO String
tryParse fp = do
  contents      <- TIO.readFile fp
  let processed = process contents
  let parsed    = parse pProgram fp processed
  case parsed of
    Left e  -> return $ show e
    Right t -> return $ printTree t

tryProcess :: String -> IO ()
tryProcess fp = do
  contents <- TIO.readFile fp
  TIO.putStrLn $ process contents

type Subst = Map.Map Ident Type

unitsub :: Subst
unitsub = Map.empty

instance {-# OVERLAPPING #-} Show Subst where
  show s = unlines $
           map (\(t1,t2) -> concat [ printTree t1
                                   , " ~> "
                                   , printTree t2]) $
           Map.toList s

class Substitutable a where
  apply :: Subst -> a -> a
  ftv :: a -> Set.Set Ident -- free type variables

instance Substitutable a => Substitutable [a] where
  apply s = map (apply s)
  ftv     = foldr (Set.union . ftv) Set.empty

-- Left biased substitution
compose :: Subst -> Subst -> Subst
s1 `compose` s2 = Map.map (apply s1) s2 `Map.union` s1

instance Substitutable Type where
  apply s t = case t of
    TVar id     -> Map.findWithDefault (TVar id) id s
    TInt        -> TInt
    TFloat      -> TFloat
    TBool       -> TBool
    TNil        -> TNil
    TLam t1 t2  -> TLam (apply s t1) (apply s t2)
    TAdt uid ts -> TAdt uid (apply s ts)
    TTup ts     -> TTup $ map (apply s) ts

  ftv t = case t of
    TVar id     -> Set.singleton id
    TInt        -> Set.empty
    TFloat      -> Set.empty
    TBool       -> Set.empty
    TNil        -> Set.empty
    TLam t1 t2  -> Set.union (ftv t1) (ftv t2)
    TAdt uid ts -> Set.unions $ map ftv ts
    TTup ts     -> Set.unions $ map ftv ts

instance Substitutable (Pat Type) where
  apply s p = case p of
    PVar a id     -> PVar (apply s a) id
    PNil a        -> PNil (apply s a)
    PConst a l    -> PConst (apply s a) l
    PWild a       -> PWild (apply s a)
    PAs a id p    -> PAs (apply s a) id (apply s p)
    PAdt a uid ps -> PAdt (apply s a) uid $ map (apply s) ps
    PTup a ps     -> PTup (apply s a) $ map (apply s) ps

  -- We will never actually need this function for patterns, or anything other
  -- than types for that matter.
  ftv p = undefined

instance Substitutable (Exp Type) where
  apply s e = case e of
    EVar a id      -> EVar (apply s a) id
    ECon a uid     -> ECon (apply s a) uid
    ELit a l       -> ELit (apply s a) l
    ECase a e pms  -> ECase a (apply s e) $ map (\(p,e) -> (apply s p, apply s e)) pms
    ETup a es      -> ETup (apply s a) $ map (apply s) es
    EBin a e1 e2 o -> EBin (apply s a) (apply s e1) (apply s e2) (apply s o)
    EUn a e o      -> EUn (apply s a) (apply s e) (apply s o)
    ELam a p e     -> ELam (apply s a) (apply s p) (apply s e)
    EApp a e1 e2   -> EApp (apply s a) (apply s e1) (apply s e2)
    ELet a p e1 e2 -> ELet (apply s a) (apply s p) (apply s e1) (apply s e2)
    EIf a e1 e2 e3 -> EIf (apply s a) (apply s e1) (apply s e2) (apply s e3)

  ftv e = undefined

instance Substitutable (Binop Type) where
  apply s op = case op of
    Add a -> Add $ apply s a
    Sub a -> Sub $ apply s a
    Mul a -> Mul $ apply s a
    Div a -> Div $ apply s a
    OLT a -> OLT $ apply s a
    OLE a -> OLE $ apply s a
    OGT a -> OGT $ apply s a
    OGE a -> OGE $ apply s a
    OEQ a -> OEQ $ apply s a
    And a -> And $ apply s a
    Or  a -> Or  $ apply s a

  ftv op = undefined

instance Substitutable (Unop Type) where
  apply s op = case op of
    Not a -> Not $ apply s a

  ftv op = undefined

instance Substitutable (Def Type) where
  apply s d = case d of
    DTypeSig id t         -> DTypeSig id t
    DEquation t id args e -> DEquation (apply s t) id (map (apply s) args) (apply s e)

  ftv = undefined

instance Substitutable (Function Type) where
  apply s f = f { equations = map (apply s) (equations f)
                , typesig   = maybe Nothing (Just . apply s) (typesig f)
                }

  ftv = undefined

instance Substitutable (Program Type) where
  apply s p = p { functions = map (apply s) (functions p)
                , main      = apply s (main p)
                }

  ftv = undefined

refine :: [Function Type] -> Subst -> [Function Type]
refine funs subst = map (apply subst) funs

unify :: Type -> Type -> TC Subst
unify (TTup ts1) (TTup ts2) = unifyMany ts1 ts2

unify (TLam t1 t2) (TLam t1' t2') = do
  s1 <- unify t1 t1'
  s2 <- unify (apply s1 t2) (apply s1 t2')
  return $ s2 `compose` s1

unify t1@(TAdt uid1 []) t2@(TAdt uid2 []) | uid1 == uid2 = return unitsub
unify (TAdt uid1 ts1) (TAdt uid2 ts2)
  | uid1 == uid2 = unifyMany ts1 ts2 

unify (TVar id) t   = bind id t
unify t (TVar id)   = bind id t
unify TInt TInt     = return unitsub
unify TFloat TFloat = return unitsub
unify TBool TBool   = return unitsub
unify TNil TNil     = return unitsub
unify t1 t2         = throwError $ UnificationError t1 t2

bind :: Ident -> Type -> TC Subst
bind id t
  | t == TVar id          = return unitsub
  | id `Set.member` ftv t = throwError $ OccursError id t
  | otherwise             = return $ Map.singleton id t

unifyMany :: [Type] -> [Type] -> TC Subst
unifyMany [] [] = return unitsub
unifyMany [] _ = error ""
unifyMany _ [] = error ""
unifyMany (t1:ts1) (t2:ts2) = do
  sub  <- unify t1 t2
  sub' <- unifyMany (apply sub ts1) (apply sub ts2)
  return $ sub `compose` sub'

unifyWithAtleastOne :: Type -> [Type] -> TC Subst
unifyWithAtleastOne t []       = error "can not unify with empty list of types"
unifyWithAtleastOne t1 [t2]    = unify t1 t2
unifyWithAtleastOne t1 (t2:ts) = catchError (unify t1 t2) $ \_ -> unifyWithAtleastOne t1 ts

unifyAll :: [Type] -> TC Subst
unifyAll []         = return unitsub
unifyAll [t]        = return unitsub
unifyAll (t1:t2:ts) = do
  sub  <- unify t1 t2
  sub' <- unifyAll $ apply sub (t2:ts)
  return $ sub `compose` sub'

data Schema = Forall [Ident] Type
  deriving Show

instance Substitutable Schema where
  -- Since the variable in `vars` are bound by the forall any mapping involving
  -- them in the substitution must be removed before the substitution is applied.
  apply s (Forall vars t) = Forall vars $ apply s' t
    where s' = foldr Map.delete s vars

  ftv (Forall vars t) = ftv t `Set.difference` Set.fromList vars

data Env = Env (Map.Map Ident Schema) (Map.Map UIdent Schema)
  deriving Show

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty

instance Substitutable Env where
  apply s (Env m1 m2) = Env (Map.map (apply s) m1) m2

  -- Not sure we need to account for the FTV in the constructors, they will
  -- be constant
  ftv (Env m1 m2) = ftv $ Map.elems m1

generalize :: Type -> Env -> Schema
generalize t env = Forall vars t
  where
      vars :: [Ident]
      vars = Set.toList $ ftv t `Set.difference` ftv env

data TCError = UnboundVariable Ident
             | UnknownConstructor UIdent
             | UnknownBinop (Binop ())
             | OccursError Ident Type
             | UnificationError Type Type
             | UndeclaredTycon UIdent
             | DuplicateTycon UIdent
             | DuplicateDataConstructor UIdent
             | PartiallyAppliedTycon UIdent Int Int
             | UnboundADTVariable UIdent [Ident] UIdent Type Ident
             | NonADTConstruction UIdent Type Type
             | TypeSignatureTooGeneral Ident Type Type
             | TypesigError Ident Type Type

instance Show TCError where
  show e = case e of
    UnboundVariable id     -> "can not resolve symbol: " ++ show id
    UnknownConstructor uid -> "can not resolve constructor: " ++ show uid
    UnknownBinop op        -> "can not resolve binop: " ++ printTree op
    OccursError id t       ->
      concat ["Can not substitute ", show id
             , " for ", show t
             , "! the type does not become more concrete."
             ]
    UnificationError t1 t2 ->
      concat ["Can not unify the two types "
             , show t1, " and ", show t2
             ]
    UndeclaredTycon uid    -> concat ["Undeclared type constructor: ", printTree uid]
    DuplicateTycon uid     -> concat ["Type constructor ", printTree uid, " already declared"]
    DuplicateDataConstructor uid -> concat ["Data constructor ", printTree uid, " already declared"]
    PartiallyAppliedTycon uid expectedarity actualarity ->
      concat [ "Type constructor ", printTree uid, " is partially applied; expected arity is "
             , show expectedarity, " but actual arity is ", show actualarity]
    UnboundADTVariable tycon vars datacon t unexpected ->
      concat [ "The data constructor ", printTree datacon, " declared with "
             , printTree tycon, " ", printTree vars, ", is declared to have type ", printTree t
             , ", but the data declaration only binds variables [", printTree vars, "]. The "
             , "variable ", printTree unexpected, " is unbound and unexpected"]
    NonADTConstruction datacon expected actual ->
      concat [ "The data constructor ", printTree datacon, " constructs a value of type "
             , printTree actual, ", but the expected type is ", printTree expected]
    TypeSignatureTooGeneral fun declared inferred ->
      concat [ "The type signature of ", printTree fun, " is too general:\n"
             , "  declared: ", printTree declared, "\n"
             , "  inferred: ", printTree inferred]
    TypesigError fun declared inferred ->
      concat [ "Type error in function ", printTree fun, ":\n"
             , "  declared type: ", printTree declared, "\n"
             , "  inferred: ", printTree inferred]

data TCState = TCState { namegen :: Int
                       , tycons  :: Map.Map UIdent Int  -- ^ ADT arity
                       }

type TC a = ExceptT TCError (
            StateT TCState (
            ReaderT Env IO))
            a

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: TC Type
fresh = do
  s <- get
  put $ s { namegen = namegen s + 1}
  return $ TVar (Ident (letters !! namegen s))

-- Notice that if the Schema doesn't contain any free variables the result of this
-- function is just the type `t` in `Forall vars t`, unchanged
instantiate :: Schema -> TC Type
instantiate (Forall vars t) = do
  freshtypevars <- mapM (const fresh) vars
  let s = Map.fromList $ zip vars freshtypevars
  return $ apply s t

lookupVar :: Ident -> TC Type
lookupVar id = do
  (Env env _) <- ask
  case Map.lookup id env of
    Just schema -> instantiate schema
    Nothing     -> throwError $ UnboundVariable id

lookupCon :: UIdent -> TC Type
lookupCon uid = do
  (Env _ env) <- ask
  case Map.lookup uid env of
    Just schema -> instantiate schema
    Nothing -> throwError $ UnknownConstructor uid

-- | Does a constructor already exist? Used for verifying data type declarations,
-- that the constructors are unique.
existsCon :: UIdent -> TC Bool
existsCon uid = do
  (Env _ env) <- ask
  case Map.lookup uid env of
    Just _  -> return True
    Nothing -> return False 

lookupTyconArity :: UIdent -> TC Int
lookupTyconArity uid = do
  st <- get
  case Map.lookup uid (tycons st) of
    Just i  -> return i
    Nothing -> throwError $ UndeclaredTycon uid

extendTyconArity :: UIdent -> Int -> TC ()
extendTyconArity uid arity = do
  st <- get
  case Map.lookup uid (tycons st) of
    Just _ -> throwError $ DuplicateTycon uid
    Nothing -> put $ st { tycons = Map.insert uid arity (tycons st) }

lookupBinop :: Binop () -> TC Type
lookupBinop op =
  case Map.lookup op binoptypes of
    Just schema -> instantiate schema
    Nothing     -> throwError $ UnknownBinop op

binoptypes :: Map.Map (Binop ()) Schema
binoptypes = Map.fromList $
     [ (Add (), Forall [a] $ TLam ta (TLam ta ta))
     , (Sub (), Forall [a] $ TLam ta (TLam ta ta))
     , (Mul (), Forall [a] $ TLam ta (TLam ta ta))
     , (Div (), Forall [a] $ TLam ta (TLam ta ta))
     , (OLT (), Forall [a] $ TLam ta (TLam ta TBool))
     , (OLE (), Forall [a] $ TLam ta (TLam ta TBool))
     , (OGT (), Forall [a] $ TLam ta (TLam ta TBool))
     , (OGE (), Forall [a] $ TLam ta (TLam ta TBool))
     , (OEQ (), Forall [a] $ TLam ta (TLam ta TBool))
     , (And (), Forall [] $ TLam TBool (TLam TBool TBool))
     , (Or  (), Forall [] $ TLam TBool (TLam TBool TBool))
     ]
  where
     a :: Ident
     a = Ident "a"

     ta :: Type
     ta = TVar a

binopCandidates :: Binop () -> [Type]
binopCandidates op = case op of
  Add _ -> [intintint, floatfloatfloat]
  Sub _ -> [intintint, floatfloatfloat]
  Mul _ -> [intintint, floatfloatfloat]
  Div _ -> [floatfloatfloat]
  OLT _ -> [intintbool, floatfloatbool]
  OLE _ -> [intintbool, floatfloatbool]
  OGT _ -> [intintbool, floatfloatbool]
  OGE _ -> [intintbool, floatfloatbool]
  OEQ _ -> [intintbool, floatfloatbool, boolboolbool]
  And _ -> [boolboolbool]
  Or  _ -> [boolboolbool]
  where
    intintint       = TLam TInt   (TLam TInt   TInt)
    floatfloatfloat = TLam TFloat (TLam TFloat TFloat)
    intintbool      = TLam TInt   (TLam TInt   TBool)
    floatfloatbool  = TLam TFloat (TLam TFloat TBool)
    boolboolbool    = TLam TBool  (TLam TBool  TBool)

lookupUnop :: Unop () -> TC Type
lookupUnop op = undefined

unoptypes :: Map.Map (Unop ()) Schema
unoptypes = Map.fromList $
  [ (Not (), Forall [] $ TLam TBool TBool)
  ]

unopCandidates :: Unop () -> [Type]
unopCandidates op = case op of
  Not () -> [TLam TBool TBool]

extend :: Env -> Ident -> Schema -> Env
extend (Env m1 m2) id schema = Env (Map.insert id schema m1) m2

restrict :: Env -> Ident -> Env
restrict (Env m1 m2) id = Env (Map.delete id m1) m2

inEnv :: Ident -> Schema -> TC a -> TC a
inEnv id schema ma = inEnvMany [(id,schema)] ma

inEnvMany :: [(Ident, Schema)] -> TC a -> TC a
inEnvMany xs ma =
  let scope e = foldl (\e' (id,schema) -> extend (restrict e' id) id schema) e xs
  in local scope ma

withConstructors :: [ADT] -> TC a -> TC a
withConstructors adts = local (\(Env m1 m2) -> Env m1 $ Map.fromList allConsSchemas)
  where
      adtToCons :: ADT -> [(UIdent, Schema)]
      adtToCons (_,vars,cons) = map (\(con,t) -> (con, Forall vars t)) cons

      allConsSchemas :: [(UIdent, Schema)]
      allConsSchemas = concat $ map adtToCons adts

-- | Can use this for type signatures to make sure all types are
-- fully applied.
containsFullyAppliedTycons :: Type -> TC ()
containsFullyAppliedTycons t = case t of
  TAdt uid ts -> do
    arity <- lookupTyconArity uid
    if arity == length ts
      then return ()
      else throwError $ PartiallyAppliedTycon uid arity (length ts)

  TTup ts     -> mapM_ containsFullyAppliedTycons ts
  TLam t1 t2  -> containsFullyAppliedTycons t1 >> containsFullyAppliedTycons t2
  _           -> return ()

whenM :: Monad m => m Bool -> m a -> a -> m a
whenM mb ma d = do
  b <- mb
  if b
    then ma
    else return d

checkPat :: Pat () -> TC (Pat Type)
checkPat p = case p of
  PVar () id    -> do
    t <- fresh
    return $ PVar t id
  PNil () -> return $ PNil TNil
  PConst () l   ->
    return $ PConst (constType l) l
  PWild () -> do
    t <- fresh
    return $ PWild t
  PAs () id p -> do
    p' <- checkPat p
    return $ PAs (patVar p') id p'
  PAdt () uid ps -> do
    -- look up the type of the constructor
    t            <- lookupCon uid
    -- typecheck the constructor arguments
    ps'          <- mapM checkPat ps

    -- fetch the types of the constructor arguments and construct a function
    -- type from the argument types to the constructor target
    let ptyps    = map patVar ps'
    let targ     = construction t
    let functype = funtype $ ptyps ++ [targ]

    -- unify the type of the constructor with the inferred types of the
    -- constructor arguments and the constructor target
    sub          <- unify t functype

    -- apply the substitution to the constructor arguments and the constructor
    -- target, and then return the annotated pattern
    let ps''     = apply sub ps'
    let targ'    = apply sub targ
    return $ PAdt targ' uid ps''
  PTup () ps -> do
    ps' <- mapM checkPat ps
    let tuptype = TTup $ map patVar ps'
    return $ PTup tuptype ps'

constType :: Lit -> Type
constType (LInt _)   = TInt
constType (LFloat _) = TFloat
constType (LBool _)  = TBool
constType LNil       = TNil

patBindings :: Pat Type -> [(Ident, Type)]
patBindings p = case p of
  PVar t id     -> [(id,t)]
  PNil _        -> []
  PConst _ l    -> []
  PWild _       -> []
  PAs t id p    -> (id, t) : patBindings p
  PAdt _ uid ps -> concat $ map patBindings ps
  PTup _ ps     -> concat $ map patBindings ps

checkPatAndBindings :: Pat () -> TC (Pat Type, [(Ident, Type)])
checkPatAndBindings p = do
  p' <- checkPat p
  let bindings = patBindings p'
  return (p', bindings)

checkDef :: Def () -> TC (Subst, Def Type)
checkDef d = case d of
  DTypeSig id t             -> return $ (unitsub, DTypeSig id t)
  DEquation () id pargs body -> do
    -- annotate arguments with type information
    args'           <- mapM checkPat pargs
    -- fetch the declared variables and their types from the arguments
    let argbindings = concat $ map patBindings args'
    -- convert them to schemas, to extend the environment with
    let argschemas  = map (\(id,t) -> (id, Forall [] t)) argbindings
    -- typecheck the equation body
    (sub, body')    <- inEnvMany argschemas $ checkExp body
--    liftIO $ putStrLn $ printTree args'
--    liftIO $ putStrLn $ printTree $ map patVar args'
--    liftIO $ putStrLn $ show sub
    -- create the inferred type of the entire definition
    let functype    = apply sub $ foldr TLam (expVar body') $ map patVar args'
    return (sub, DEquation functype id args' body')

-- | t1 `moreGeneralThan` t2 returns True if t1 is a more general type than t2.
-- This is used to make sure that e.g a function of type Int -> Int is not
-- given the type signature a -> b by the developer.
moreGeneralThan :: Type -> Type -> Bool
moreGeneralThan (TVar _) (TVar _)     = False
moreGeneralThan (TVar _) _            = True
moreGeneralThan (TTup ts1) (TTup ts2) =
  or $ zipWith moreGeneralThan ts1 ts2
moreGeneralThan (TAdt _ ts1) (TAdt _ ts2) =
  or $ zipWith moreGeneralThan ts1 ts2
moreGeneralThan (TLam t1 t2) (TLam t1' t2') =
  moreGeneralThan t1 t1' || moreGeneralThan t2 t2'
moreGeneralThan _ _ = False

-- | Check if the declared type of a function is more general than the
-- inferred type. If that is the case, raise a type error.
checkTooGeneralType :: Ident -> Maybe Type -> Type -> TC ()
checkTooGeneralType _ Nothing _      = return ()
checkTooGeneralType fun (Just sig) t = do
  e <- ask
  let sch = generalize sig e
  sig' <- instantiate sch
  if sig' `moreGeneralThan` t
    then do let inft = renameTVars sig t
            throwError $ TypeSignatureTooGeneral fun sig inft 
    else return ()
  where
    renameTVars :: Type -> Type -> Type
    renameTVars t1 t2 = case (t1, t2) of
      (TVar id, TVar _)          -> TVar id
      (TTup ts1, TTup ts2)       -> TTup (zipWith renameTVars ts1 ts2)
      (TAdt uid ts1, TAdt _ ts2) -> TAdt uid $ zipWith renameTVars ts1 ts2
      (TLam t1 t2, TLam t1' t2') -> TLam (renameTVars t1 t1') (renameTVars t2 t2')
      (_,t)                      -> t

-- | Make sure that an inferred type can unify with a type signature, if
-- any exist.
unifyWithTypesig :: Ident -> Maybe Type -> Type -> TC ()
unifyWithTypesig _ Nothing _      = return ()
unifyWithTypesig fun (Just sig) t = do
  catchError (unify sig t >> return ()) $ \_ ->
    throwError $ TypesigError fun sig t

checkFunction :: Function () -> TC (Subst, Function Type)
checkFunction f = do
  -- typecheck equations and fetch their types
  subneqs <- case (typesig f) of
    Just t -> do
      env     <- ask
      let sch = generalize t env
      inEnv (name f) sch $ mapM checkDef $ equations f
    Nothing -> mapM checkDef $ equations f
  -- [(substitutions for each equation, the equation)]
  let (subs, eqs) = unzip subneqs
  -- [inferred Type of equation]
  let types       = map (fromJust . defVar) $ filter (isJust . defVar) eqs

  -- create the mega-substitution for everything by unification
  let sub    = foldl compose unitsub subs
  sub'       <- unifyAll types
  let finsub = sub `compose` sub'

  -- apply the substitution to the equations and fetch the finished type
  -- of the entire function
  let eqs'        = apply finsub eqs
  let eqt         = fromJust $ defVar $ head eqs'

  -- does the inferred type unify with the type signature, if any exist?
  unifyWithTypesig    (name f) (typesig f) eqt
  -- is the declared type not more general than the inferred one?
  checkTooGeneralType (name f) (typesig f) eqt

  let f'          = f { equations = eqs'
                      , typesig   = maybe (Just eqt) Just (typesig f)
                      }

  -- return annotated, substituted function
  return $ (finsub, f')

-- | Check that the declaration of an ADT is okay.
checkDataDeclaration :: ADT -> TC ()
checkDataDeclaration (tycon, vars, cons) = do
  extendTyconArity tycon (length vars)
  let constructors = map fst cons

  -- make sure that each constructor is okay
  forM_ cons $ \(con,t) -> do

    -- was this constructor already declared with another ADT?
    whenM (existsCon con) (throwError $ DuplicateDataConstructor con) ()

    -- are we currently declaring two constructors with the same name?
    whenM (return $ con `elem` (delete con constructors))
          (throwError $ DuplicateDataConstructor con)
          ()

    -- are any ADTs in this type fully applied?
    containsFullyAppliedTycons t

    {----------- The checks below this relate to ADTs vs GADTs -----------}

    -- does it only use the variables bound by the data declaration?
    let vars = tvars t
    forM_ vars $ \v ->
      whenM (return $ not $ v `elem` vars)
            (throwError $ UnboundADTVariable tycon vars con t v)
            ()

    -- does it construct something of the declared type? E.g constructors in the
    -- type `data Test a b where ...` may only construct values of type `Test a b`.
    let restype = construction t -- this just unwraps a function type
    let types   = map TVar vars
    whenM (return $ not $ restype == (TAdt tycon types))
          (throwError $ NonADTConstruction con (TAdt tycon types) restype)
          ()

  where
      tvars :: Type -> [Ident]
      tvars t = nub $ allvars t

      allvars :: Type -> [Ident]
      allvars t = case t of
        TVar a      -> [a]
        TTup ts     -> concat $ map tvars ts
        TAdt uid ts -> concat $ map tvars ts
        TLam t1 t2  -> tvars t1 ++ tvars t2
        _           -> []

checkProgram :: Program () -> TC (Subst, Program Type)
checkProgram p = do
  -- check that the declared ADTs are not GADTs and that they are
  -- well formed etc
  foldM (\acc d -> do withConstructors acc $ checkDataDeclaration d
                      return $ d : acc)
        []
        (datatypes p)

  -- extend the environment with the data constructors in scope and then
  -- type check all functions in the program
  let allfunctions = functions p ++ [main p]
  (sub, funs) <- withConstructors (datatypes p) $ checkFunctions allfunctions

  let main' = last funs
  let funs' = init funs
  return (sub, p { functions = funs'
                 , main      = main'
                 }
         )

checkFunctions :: [Function ()] -> TC (Subst, [Function Type])
checkFunctions fs = checkFunctions_ fs unitsub

checkFunctions_ :: [Function ()] -> Subst -> TC (Subst, [Function Type])
checkFunctions_ [] s     = return (s, [])
checkFunctions_ (f:fs) s = do
  (sub, f')   <- checkFunction f
  let id      = name f'
  let ty      = fromJust $ defVar $ head $ equations f'
  env         <- ask
  let schema  = generalize (apply (s `compose` sub) ty) env
  (sub', fs') <- inEnv id schema $ checkFunctions_ fs (s `compose` sub)
  return $ (sub', f' : fs')

typecheck :: [Def ()] -> IO (Either String (Program Type, Subst))
typecheck defs = do
  let excepted = runExceptT $ checkProgram program
  let stated   = evalStateT excepted (TCState 0 Map.empty)
  readed       <- runReaderT stated initialEnv
  case readed of
    Left err -> return $ Left $ show err
    Right (subs,annotated) -> return (Right (annotated, subs))
  where
      program :: Program ()
      program = mkProgram defs

      funs :: [Function ()]
      funs = mkFunctions defs

      initialEnv :: Env
      initialEnv = Env (Map.fromList entries) Map.empty

      entries :: [(Ident, Schema)]
      entries = [ (Ident "add2", Forall [] $ TLam TInt TInt)
                , (Ident "prim_id", Forall [a] $ TLam ta ta)
                ]
        where
            a = Ident "a"
            ta = TVar a

instance {-# OVERLAPPING #-} Show ([Function Type], Subst) where
  show (funs, subst) = unlines [pfuns, psubs]
    where
       pfuns = unlines $ map printTree funs
       psubs = unlines $
                          map
                            (\(id,t) -> printTree id ++ " -> " ++ printTree t)
                            (Map.toList subst)

instance {-# OVERLAPPING #-} Print a => Show [Function a] where
  show funs = intercalate "\n\n" $ map printTree funs

runTC :: TC a -> IO (Either TCError a)
runTC tca = let excepted = runExceptT tca
                stated   = evalStateT excepted (TCState 0 Map.empty)
            in runReaderT stated (Env Map.empty Map.empty)

checkCaseClauses :: Type -> [(Pat (), Exp ())] -> TC (Subst, [(Pat Type, Exp Type)])
checkCaseClauses t []     = return (unitsub, [])
checkCaseClauses t (c:cs) = do
  (sub,c')   <- checkCaseClause t c
  (sub',cs') <- checkCaseClauses t cs
  return (sub `compose` sub', c':cs')

checkCaseClause :: Type -> (Pat (), Exp ()) -> TC (Subst, (Pat Type, Exp Type))
checkCaseClause ct (p,e) = do
  p'          <- checkPat p
  s1          <- unify ct (patVar p')
  let p''     = apply s1 p'
  let vars    = patBindings p''
  let schemas = map (\(id,t) -> (id, Forall [] t)) vars
  (s2,e')     <- inEnvMany schemas $ checkExp e
  return (s1 `compose` s2, (p'', e'))

checkExp :: Exp () -> TC (Subst, Exp Type)
checkExp e = case e of
  EVar () id      -> do
    t <- lookupVar id
    return (unitsub, EVar t id)

  ECon () uid     -> do
    t <- lookupCon uid
    return (unitsub, ECon t uid)

  ELit () l       -> return (unitsub, ELit (constType l) l)

  ECase () e pms  -> do
    (s1,e')      <- checkExp e
    (s2, pms')   <- checkCaseClauses (expVar e') pms
    s3           <- unifyAll $  map (expVar . snd) pms'
    let finsub   = s1 `compose` s2 `compose` s3
    let casetyps = expVar $ (snd . head) pms'
    return (finsub, ECase casetyps e' pms')

  ETup () es      -> do
    (subs, es') <- unzip <$> mapM checkExp es
    let typs = map expVar es'
    let sub = foldl1 compose subs
    return (sub, ETup (TTup typs) es')

  EBin () e1 e2 o -> do
    (s1, e1')      <- checkExp e1
    (s2, e2')      <- checkExp e2
    tv             <- fresh
    let inftype    = TLam (expVar e1') (TLam (expVar e2') tv)
    let candidates = binopCandidates o
    s3             <- unifyWithAtleastOne inftype candidates
    let sub        = s1 `compose` s2 `compose` s3
    return (sub, EBin (apply sub tv) e1' e2' (setBinopVar (apply sub inftype) o))

  EUn () e o      -> do
    (s1,e')        <- checkExp e
    tv             <- fresh
    let inftype    = TLam (expVar e') tv
    let candidates = unopCandidates o
    s2             <- unifyWithAtleastOne inftype candidates
    let sub        = s1 `compose` s2
    return (sub, EUn (apply sub tv) e' (setUnopVar (apply sub inftype) o))

  ELam () p e     -> do
    (p', vars)     <- checkPatAndBindings p
    let varschemas = map (\(id,t) -> (id, Forall [] t)) vars
    (sub,e')       <- inEnvMany varschemas $ checkExp e
    let lamtyp     = TLam (patVar p') (expVar e')
    return (sub, ELam lamtyp p' e')

  EApp () e1 e2   -> do
    tv          <- fresh
    (s1, e1')   <- checkExp e1
    (s2, e2')   <- local (apply s1) $ checkExp e2
    let t1      = expVar e1'
    let t2      = expVar e2'
    let inftyp  = TLam t2 tv
    s3          <- unify (apply s2 t1) inftyp
    let sub     = s3 `compose` s2 `compose` s1
    return (sub, EApp (apply sub tv) e1' e2')

  ELet () p e1 e2 -> do
      (s1, e1')      <- checkExp e1
      (p', vars)     <- checkPatAndBindings p
      s2             <- unify (patVar p') (expVar e1')
      env            <- ask
      let env'       = apply (s1 `compose` s2) env
      let varschemas = map (\(id,t) -> (id, generalize (apply (s1 `compose` s2) t) env')) vars
      let env''      = foldl (\e' (id,sc) -> extend (restrict e' id) id sc) env' varschemas
      (s3,e2')       <- local (const env'') $ checkExp e2
      return (s1 `compose` s2 `compose` s3, ELet (expVar e2') p' e1' e2')

  EIf () e1 e2 e3 -> do
--    (s1,e1') <- checkExp e1
--    (s2,e2') <- checkExp e2
--    (s3,e3') <- checkExp e3
--    s4 <- unify (expVar e1') TBool
--    s5 <- unify (expVar e2') (expVar e3')
--    let sub = s1 `compose` s2 `compose` s3 `compose` s4 `compose` s5
    tv <- fresh
    (sub, [e1',e2',e3'], t) <- inferPrim [e1,e2,e3] (TLam TBool (TLam tv (TLam tv tv)))
    return (sub, EIf t e1' e2' e3')

-- | The code that's commented out on the checkExp-if case is from stephen diehls blog,
-- but it clearly does not work. If e1 decides the type of some variable i to be bool and
-- then i is used as an integer in the branches, this is not detected. Clearly the
-- substitutions need to be applied as we go. This code below is borrowed and modified
-- from his repository.
inferPrim :: [Exp ()] -> Type -> TC (Subst, [Exp Type], Type)
inferPrim l t = do
  env <- ask
  tv <- fresh
  (s1, tf, _, exps) <- foldM inferStep (unitsub, id, env, []) l
  s2 <- unify (apply s1 (tf tv)) t
  return (s2 `compose` s1, reverse exps, apply s2 tv)
  where
  inferStep (s, tf, env, exps) exp = do
    (s', t) <- local (apply s) $ checkExp exp
    return (s' `compose` s, tf . (TLam (expVar t)), env, t:exps)

{-********** Start of tokenizer **********-}

-- | To preprocess a file, apply layout resolution
process :: T.Text -> T.Text
process t = printTokPos $ resolveLayout True $ tokenize t

-- | Data type of tokens (definition stolen from the stuff BNFC generates)
data Tok =
   TS T.Text !Int    -- reserved words and symbols (not sure what the unique int is for)
 | TL T.Text         -- string literals
 | TI T.Text         -- integer literals
 | TV T.Text         -- identifiers
 | TD T.Text         -- double precision float literals
 | T_UIdent T.Text
 deriving Show

type TokPos = (Tok, Int, Int)

toktext :: TokPos -> T.Text
toktext (t,_,_) = case t of
  TS t _     -> t
  TL t       -> t
  TI t       -> t
  TV t       -> t
  TD t       -> t
  T_UIdent t -> t

-- | Turn a list of TokPos into a line of Text. Prepend the line with the
-- indentation level as specified by the first token. The list of tokens are
-- assumed to all be on the same line.
tokline :: [TokPos] -> T.Text
tokline [] = ""
tokline (tok@(_,_,c):ts) = T.append first $ T.unwords $ map toktext ts
  where
    first = T.snoc (T.append (T.replicate (c-1) " ") (toktext tok)) ' '

-- | Turn a list of tokens back into a source file
printTokPos :: [TokPos] -> T.Text
printTokPos ts = T.unlines $ map tokline $ groupBy pred ts
  where
    pred (_,l1,_) (_,l2,_) = l1 == l2

-- | Compute the length of a token
toklength :: Tok -> Int
toklength t = case t of
  TS t _     -> T.length t
  TL t       -> T.length t
  TI t       -> T.length t
  TV t       -> T.length t
  TD t       -> T.length t
  T_UIdent t -> T.length t

-- | Split a source file up into its tokens. I am guessing this is grossly inefficient.
tokenize :: T.Text -> [TokPos]
tokenize t = concat $ zipWith tokenizeLine [1..] (T.lines t)
  where
    -- | Input text starts at (line, col), and tokenizes a single line
    tokenizeLine :: Int -> T.Text -> [TokPos]
    tokenizeLine line row = case sptb row of
      Just (count, rest) -> go line (count + 1) rest
      Nothing            -> []
      where
        go :: Int -> Int -> T.Text -> [TokPos]
        go line col row = case nextToken row of
          Just (tok, rest) -> case sptb rest of
            Just (count, rest') -> (tok, line, col) : go line (col + toklength tok + count) rest'
            Nothing             -> [(tok, line, col)]
          Nothing          -> []

    -- | Tries the tokenize functions one by one until one succeeds
    nextToken :: T.Text -> Maybe (Tok, T.Text)
    nextToken t = fetchToken [ tokuiden t
                             , tokint t
                             , tokfloat t
                             , tokiden t
                             , tokreserved t
                             ]
      where
        fetchToken :: [Maybe (Tok, T.Text)] -> Maybe (Tok, T.Text)
        fetchToken []     = Nothing
        fetchToken (x:xs) = if isJust x then x else fetchToken xs

    -- int literals
    tokint :: T.Text -> Maybe (Tok, T.Text)
    tokint t = let (token, rest) = T.span (\c -> isDigit c) t
               in if T.null token then Nothing else Just (TI token, rest)
    
    -- float literals
    tokfloat :: T.Text -> Maybe (Tok, T.Text)
    tokfloat t = do
      (TI big, rest)  <- tokint t
      assertB $ T.head rest == '.'
      (TI low, rest') <- tokint $ T.tail rest
      return (TD $ T.concat [big, ".", low], rest')

    -- identifiers    
    tokiden :: T.Text -> Maybe (Tok, T.Text)
    tokiden t = do
      assertB $ isLetter $ T.head t
      let (token, rest) = T.span pred t
      assertB $ not (T.unpack token `elem` pkeywords)
      return (TV token, rest)
      where
        pred c = isLetter c || isDigit c || c == '\'' || c == '_'

    -- uppercase identifiers
    tokuiden :: T.Text -> Maybe (Tok, T.Text)
    tokuiden t = do
      assertB $ isUpper $ T.head t
      let (restuid, rest) = T.span pred t
      return (T_UIdent restuid, rest)
      where
        pred c = isLetter c || isUpper c || c == '\'' || c == '_'

    -- reserved words and keywords
    tokreserved :: T.Text -> Maybe (Tok, T.Text)
    tokreserved t
      | "Bool"  `T.isPrefixOf` t = Just (TS "Bool" 18,  T.drop (T.length "Bool") t)
      | "Int"   `T.isPrefixOf` t = Just (TS "Int" 21,   T.drop (T.length "Int") t)
      | "Float" `T.isPrefixOf` t = Just (TS "Float" 20, T.drop (T.length "Float") t)
      | "True"  `T.isPrefixOf` t = Just (TS "True" 22,  T.drop (T.length "True") t)
      | "False" `T.isPrefixOf` t = Just (TS "False" 19, T.drop (T.length "False") t)
      | "data"  `T.isPrefixOf` t = Just (TS "data" 27,  T.drop (T.length "data") t)
      | "where" `T.isPrefixOf` t = Just (TS "where" 34, T.drop (T.length "where") t)
      | "case"  `T.isPrefixOf` t = Just (TS "case" 26,  T.drop (T.length "case") t)
      | "of"    `T.isPrefixOf` t = Just (TS "of" 32,    T.drop (T.length "of") t)
      | "let"   `T.isPrefixOf` t = Just (TS "let" 31,   T.drop (T.length "let") t)
      | "in"    `T.isPrefixOf` t = Just (TS "in" 30,    T.drop (T.length "in") t)
      | "if"    `T.isPrefixOf` t = Just (TS "if" 29,    T.drop (T.length "if") t)
      | "then"  `T.isPrefixOf` t = Just (TS "then" 33,  T.drop (T.length "then") t)
      | "else"  `T.isPrefixOf` t = Just (TS "else" 28,  T.drop (T.length "else") t)
      | ":"     `T.isPrefixOf` t = Just (TS ":" 12,     T.drop (T.length ":") t)
      | "->"    `T.isPrefixOf` t = Just (TS "->" 10,    T.drop (T.length "->") t)
      | "{"     `T.isPrefixOf` t = Just (TS "{" 35,     T.drop (T.length "{") t)
      | "}"     `T.isPrefixOf` t = Just (TS "}" 37,     T.drop (T.length "}") t)
      | ";"     `T.isPrefixOf` t = Just (TS ";" 13,     T.drop (T.length ";") t)
      | "()"    `T.isPrefixOf` t = Just (TS "()" 4,     T.drop (T.length "()") t)
      | "("     `T.isPrefixOf` t = Just (TS "(" 3,      T.drop (T.length "(") t)
      | ")"     `T.isPrefixOf` t = Just (TS ")" 5,      T.drop (T.length ")") t)
      | "+"     `T.isPrefixOf` t = Just (TS "+" 7,      T.drop (T.length "+") t)
      | "-"     `T.isPrefixOf` t = Just (TS "-" 9,      T.drop (T.length "-") t)
      | "*"     `T.isPrefixOf` t = Just (TS "*" 6,      T.drop (T.length "*") t)
      | "/"     `T.isPrefixOf` t = Just (TS "/" 11,     T.drop (T.length "/") t)
      | "&&"    `T.isPrefixOf` t = Just (TS "&&" 2,     T.drop (T.length "&&") t)
      | "||"    `T.isPrefixOf` t = Just (TS "||" 36,    T.drop (T.length "||") t)
      | "!"     `T.isPrefixOf` t = Just (TS "!" 1,      T.drop (T.length "!") t)
      | ","     `T.isPrefixOf` t = Just (TS "," 8,      T.drop (T.length ",") t)
      | "<="    `T.isPrefixOf` t = Just (TS "<=" 38,    T.drop (T.length "<=") t)
      | "<"     `T.isPrefixOf` t = Just (TS "<" 14,     T.drop (T.length "<") t)
      | ">="    `T.isPrefixOf` t = Just (TS ">=" 39,    T.drop (T.length ">=") t)
      | ">"     `T.isPrefixOf` t = Just (TS ">" 17,     T.drop (T.length ">") t)
      | "=="    `T.isPrefixOf` t = Just (TS "==" 16,    T.drop (T.length "==") t)
      | "="     `T.isPrefixOf` t = Just (TS "=" 15,     T.drop (T.length "=") t)
      | "\\"    `T.isPrefixOf` t = Just (TS "\\" 23,    T.drop (T.length "\\") t)
      | "_"     `T.isPrefixOf` t = Just (TS "_" 24,     T.drop (T.length "_") t)
      | "as"    `T.isPrefixOf` t = Just (TS "as" 25,    T.drop (T.length "as") t)
    tokreserved _ = Nothing

    -- consume whitespace and tabs
    sptb :: T.Text -> Maybe (Int, T.Text)
    sptb t = let (chunk, rest) = T.span pred t
             in if T.null rest then Nothing else Just (T.length chunk, rest)
      where
        pred c = c == ' ' || c == '\t'

assertB :: Bool -> Maybe ()
assertB True  = Just ()
assertB False = Nothing

{-********** End of tokenizer **********-}
{-********** Start of layout resolver (stolen from BNFC) **********-}

-- | This bool says that we definitely want to apply top layout. This means that
-- top level definitions are delimited by semi-colons.
topLayout :: Bool
topLayout = True

-- | These words initiate/terminate layout blocks
layoutWords, layoutStopWords :: [T.Text]
layoutWords     = ["where","of"]
layoutStopWords = []

layoutOpen, layoutClose, layoutSep :: T.Text
layoutOpen  = "{"
layoutClose = "}"
layoutSep   = ";"

-- | Replace layout syntax with explicit layout tokens.
resolveLayout :: Bool    -- ^ Whether to use top-level layout.
              -> [TokPos] -> [TokPos]
resolveLayout tp = res Nothing [if tl then Implicit 1 else Explicit] [0]
  where
  -- Do top-level layout if the function parameter and the grammar say so.
  tl = tp && topLayout

  res :: Maybe TokPos -- ^ The previous token, if any.
      -> [Block] -- ^ A stack of layout blocks.
      -> [Int]
      -> [TokPos] -> [TokPos]

  -- The stack should never be empty.
  res _ [] _ ts = error $ "Layout error: stack empty. Tokens: " ++ show ts

  res _ st c (t0:ts)
    -- We found an open brace in the input,
    -- put an explicit layout block on the stack.
    -- This is done even if there was no layout word,
    -- to keep opening and closing braces.
    | isLayoutOpen t0 = moveAlong (Explicit:st) [t0] ts c

  -- We are in an implicit layout block
  res pt st@(Implicit n:ns) c (t0:ts)

      -- End of implicit block by a layout stop word
    | isStop t0 =
           -- Exit the current block and all implicit blocks
           -- more indented than the current token
       let (ebs,ns') = span (`moreIndent` column t0) ns
           moreIndent (Implicit x) y = x > y
           moreIndent Explicit _ = False
           -- the number of blocks exited
           b = 1 + length ebs
           bs = replicate b layoutClose
           -- Insert closing braces after the previous token.
           (ts1,ts2) = splitAt (1+b) $ addTokens (afterPrev pt) bs (t0:ts)
        in moveAlong ns' ts1 ts2 (drop b c)

    -- End of an implicit layout block
    | newLine pt t0 && column t0 < n  =
           -- Insert a closing brace after the previous token.
       let b:t0':ts' = addToken (afterPrev pt) layoutClose (t0:ts)
           -- Repeat, with the current block removed from the stack
        in moveAlong ns [b] (t0':ts') $ tail c

    -- see opening parentheses
    | isParenthesesOpen t0 = moveAlong st [t0] ts $ incOpening c

    | isParenthesesClose t0 =
        if head c == 0
          then let b:t0':ts' = addToken (afterPrev pt) layoutClose (t0:ts)
               in moveAlong ns [b] (t0':ts') $ tail c
          else moveAlong st [t0] ts $ decOpening c

  res pt st c (t0:ts)
    -- Start a new layout block if the first token is a layout word
    | isLayout t0 =
        case ts of
            -- Explicit layout, just move on. The case above
            -- will push an explicit layout block.
            t1:_ | isLayoutOpen t1 -> moveAlong st [t0] ts c
                 -- The column of the next token determines the starting column
                 -- of the implicit layout block.
                 -- However, the next block needs to be strictly more indented
                 -- than the previous block.
            _ -> let col = max (indentation st + 1) $
                       -- at end of file, the start column doesn't matter
                       if null ts then column t0 else column (head ts)
                     -- insert an open brace after the layout word
                     b:ts' = addToken (nextPos t0) layoutOpen ts
                     -- save the start column
                     st' = Implicit col:st
                 in -- Do we have to insert an extra layoutSep?
                case st of
                  Implicit n:_
                    | newLine pt t0 && column t0 == n
                      && not (isNothing pt ||
                              isTokenIn [layoutSep,layoutOpen] (fromJust pt)) ->
                     let b':t0':b'':ts'' =
                           addToken (afterPrev pt) layoutSep (t0:b:ts')
                     in moveAlong st' [b',t0',b''] ts' (0:c)
                  _ -> moveAlong st' [t0,b] ts' (0:c)

    -- If we encounter a closing brace, exit the first explicit layout block.
    | isLayoutClose t0 =
          let tod = dropWhile isImplicit st
              st' = drop 1 tod
              c'  = drop (length c - length tod) c
           in if null st'
                 then error $ "Layout error: Found " ++ (T.unpack layoutClose) ++ " at ("
                              ++ show (line t0) ++ "," ++ show (column t0)
                              ++ ") without an explicit layout block."
                 else moveAlong st' [t0] ts c'

  -- Insert separator if necessary.
  res pt st@(Implicit n:ns) c (t0:ts)
    -- Encounted a new line in an implicit layout block.
    | newLine pt t0 && column t0 == n =
       -- Insert a semicolon after the previous token.
       -- unless we are the beginning of the file,
       -- or the previous token is a semicolon or open brace.
       if isNothing pt || isTokenIn [layoutSep,layoutOpen] (fromJust pt)
          then moveAlong st [t0] ts c
          else let b:t0':ts' = addToken (afterPrev pt) layoutSep (t0:ts)
                in moveAlong st [b,t0'] ts' c

  -- Nothing to see here, move along.
  res _ st c (t:ts)  = moveAlong st [t] ts c

  -- At EOF: skip explicit blocks.
  res (Just t) (Explicit:bs) c [] | null bs = []
                                  | otherwise = res (Just t) bs c []

  -- If we are using top-level layout, insert a semicolon after
  -- the last token, if there isn't one already
  res (Just t) [Implicit _n] _ []
      | isTokenIn [layoutSep] t = []
      | otherwise = addToken (nextPos t) layoutSep []

  -- At EOF in an implicit, non-top-level block: close the block
  res (Just t) (Implicit _n:bs) (_:co) [] =
     let c = addToken (nextPos t) layoutClose []
      in moveAlong bs c [] co

  -- This should only happen if the input is empty.
  res Nothing _st _ [] = []

  -- | Move on to the next token.
  moveAlong :: [Block] -- ^ The layout stack.
            -> [TokPos] -- ^ Any tokens just processed.
            -> [TokPos] -- ^ the rest of the tokens.
            -> [Int]   -- ^ Opening counts
            -> [TokPos]
  moveAlong _  [] _  _ = error "Layout error: moveAlong got [] as old tokens"
  moveAlong st ot ts c = ot ++ res (Just $ last ot) st c ts

  newLine :: Maybe TokPos -> TokPos -> Bool
  newLine pt t0 = case pt of
    Nothing -> True
    Just t  -> line t /= line t0

data Block
   = Implicit Int -- ^ An implicit layout block with its start column.
   | Explicit
   deriving Show

-- | Get current indentation.  0 if we are in an explicit block.
indentation :: [Block] -> Int
indentation (Implicit n : _) = n
indentation _ = 0

-- | Check if s block is implicit.
isImplicit :: Block -> Bool
isImplicit (Implicit _) = True
isImplicit _ = False

type Position = (Int, Int)

-- | Insert a number of tokens at the begninning of a list of tokens.
addTokens :: Position -- ^ Position of the first new token.
          -> [T.Text] -- ^ Token symbols.
          -> [TokPos]  -- ^ The rest of the tokens. These will have their
                      --   positions updated to make room for the new tokens .
          -> [TokPos]
addTokens p ss ts = foldr (addToken p) ts ss

-- | Insert a new symbol token at the begninning of a list of tokens.
addToken :: Position -- ^ Position of the new token.
         -> T.Text   -- ^ Symbol in the new token.
         -> [TokPos]  -- ^ The rest of the tokens. These will have their
                     --   positions updated to make room for the new token.
         -> [TokPos]
addToken p s ts = sToken p s : map (incrGlobal p (T.length s)) ts

-- | Get the position immediately to the right of the given token.
--   If no token is given, gets the first position in the file.
afterPrev :: Maybe TokPos -> Position
afterPrev = maybe (1,1) nextPos

-- | Get the position immediately to the right of the given token.
nextPos :: TokPos -> Position
nextPos (t,l,c) = (l, c + s + 1) --    Pn (g + s) l (c + s + 1)
  where s = toklength t

-- | Add to the global and column positions of a token.
--   The column position is only changed if the token is on
--   the same line as the given position.
incrGlobal :: Position -- ^ If the token is on the same line
                       --   as this position, update the column position.
           -> Int      -- ^ Number of characters to add to the position.
           -> TokPos -> TokPos
incrGlobal (l0, _) i (t, l, c) = --(PT (Pn g l c) t) =
  if l /= l0 then (t, l, c) --    PT (Pn (g + i) l c) t
             else (t, l, c + i) --    PT (Pn (g + i) l (c + i)) t
--incrGlobal _ _ p = error $ "cannot add token at " ++ show p

-- | Create a symbol token.
sToken :: Position -> T.Text -> TokPos
sToken (l,c) s = (TS s i, l, c)
  where
    i = case s of
      "!" -> 1
      "&&" -> 2
      "(" -> 3
      "()" -> 4
      ")" -> 5
      "*" -> 6
      "+" -> 7
      "," -> 8
      "-" -> 9
      "->" -> 10
      "/" -> 11
      ":" -> 12
      ";" -> 13
      "<" -> 14
      "=" -> 15
      "==" -> 16
      ">" -> 17
      "Bool" -> 18
      "False" -> 19
      "Float" -> 20
      "Int" -> 21
      "True" -> 22
      "\\" -> 23
      "_" -> 24
      "as" -> 25
      "case" -> 26
      "data" -> 27
      "else" -> 28
      "if" -> 29
      "in" -> 30
      "let" -> 31
      "of" -> 32
      "then" -> 33
      "where" -> 34
      "{" -> 35
      "||" -> 36
      "}" -> 37
      "<=" -> 38
      ">=" -> 39
      _ -> error $ "not a reserved word: " ++ show s

-- | Get the position of a token.
position :: TokPos -> Position
position (_,l,c) = (l,c)

-- | Get the line number of a token.
line :: TokPos -> Int
line t = case position t of (l,_) -> l

-- | Get the column number of a token.
column :: TokPos -> Int
column t = case position t of (_,c) -> c

-- | Check if a token is one of the given symbols.
isTokenIn :: [T.Text] -> TokPos -> Bool
isTokenIn ts t = case t of
  (TS r _, _, _) | r `elem` ts -> True
  _                            -> False

-- | Check if a word is a layout start token.
isLayout :: TokPos -> Bool
isLayout = isTokenIn layoutWords

-- | Check if a token is a layout stop token.
isStop :: TokPos -> Bool
isStop = isTokenIn layoutStopWords

-- | Check if a token is the layout open token.
isLayoutOpen :: TokPos -> Bool
isLayoutOpen = isTokenIn [layoutOpen]

-- | Check if a token is the layout close token.
isLayoutClose :: TokPos -> Bool
isLayoutClose = isTokenIn [layoutClose]

isParenthesesOpen :: TokPos -> Bool
isParenthesesOpen = isTokenIn ["("]

isParenthesesClose :: TokPos -> Bool
isParenthesesClose = isTokenIn [")"]

incOpening :: [Int] -> [Int]
incOpening (x:xs) = (x+1:xs)
incOpening []     = error "tried to increment opening count on empty count stack"

decOpening :: [Int] -> [Int]
decOpening (x:xs) = (x-1:xs)

{-**********  End of layout resolver **********-}

-- | Custom parser type - synonym for Parsec Void Text a
type Parser a = Parsec Void T.Text a

-- | Parser that parses a program
pProgram :: Parser [Def ()]
pProgram = many $ pDataDec <|> try pTypeSignature <|> pEquation

-- parse types
pClosed :: Parser Type
pClosed = choice [ TInt    <$ pSymbol "Int"
                 , TFloat  <$ pSymbol "Float"
                 , TBool   <$ pSymbol "Bool"
                 , TVar    <$> pIdent
                 , flip TAdt [] <$> pUIdent
                 , do pChar '('
                      ts <- sepBy pFun (pChar ',') <* pChar ')'
                      case ts of
                          []      -> pure TNil
                          [t]     -> pure t
                          (_:_:_) -> pure (TTup ts)
                 ]

pApp :: Parser Type
pApp = choice [ TAdt <$> pUIdent <*> many pClosed
              , pClosed
              ]

pFun :: Parser Type
pFun = foldr1 TLam <$> sepBy1 pApp (pSymbol "->")

pType :: Parser Type
pType = pSpace *> pFun

-- parse expressions

pExpClosed :: Parser (Exp ())
pExpClosed = choice [ ELit () <$> pConst
                    , EVar () <$> pIdent
                    , ECon () <$> pUIdent
                    , do pChar '('
                         es <- sepBy1 pExpVerbose (pChar ',') <* pChar ')'
                         case es of
                             []    -> undefined
                             [e]   -> pure e
                             (_:_:_) -> pure (ETup () es)
                    ]

pExpApp :: Parser (Exp ())
pExpApp = foldl1 (EApp ()) <$> some pExpClosed

pExpNot :: Parser (Exp ())
pExpNot = choice [ do pChar '!'
                      e <- pExpApp
                      pure $ EUn () e (Not ())
                 , pExpApp
                 ]

pExpMul :: Parser (Exp ())
pExpMul = pExpNot >>= go where
  go e1 = choice [ do pChar '*'
                      e2 <- pExpNot
                      go $ EBin () e1 e2 (Mul ())
                 , do pChar '/'
                      e2 <- pExpNot
                      go $ EBin () e1 e2 (Div ())
                 , pure e1
                 ]

pExpAdd :: Parser (Exp ())
pExpAdd = pExpMul >>= go where
  go e1 = choice [ do pChar '+'
                      e2 <- pExpMul
                      go $ EBin () e1 e2 (Add ())
                 , do pChar '-'
                      e2 <- pExpMul
                      go $ EBin () e1 e2 (Sub ())
                 , pure e1
                 ]

pExpRel :: Parser (Exp ())
pExpRel = pExpAdd >>= go where
    go e1 = choice [ do pChar '<'
                        choice [ do pChar '='
                                    e2 <- pExpAdd
                                    pure $ EBin () e1 e2 (OLE ())
                               , do e2 <- pExpAdd
                                    pure $ EBin () e1 e2 (OLT ())
                               ]
                   , do pChar '>'
                        choice [ do pChar '='
                                    e2 <- pExpAdd
                                    pure $ EBin () e1 e2 (OGE ())
                               , do e2 <- pExpAdd
                                    pure $ EBin () e1 e2 (OGT ())
                               ]
                   , do pSymbol "=="
                        e2 <- pExpAdd
                        pure $ EBin () e1 e2 (OEQ ())
                   , pure e1
                   ]

pExpAnd :: Parser (Exp ())
pExpAnd = foldr1 (\e1 e2 -> EBin () e1 e2 (And ())) <$> sepBy1 pExpRel (pSymbol "&&")

pExpOr :: Parser (Exp ())
pExpOr = foldr1 (\e1 e2 -> EBin () e1 e2 (Or ())) <$> sepBy1 pExpAnd (pSymbol "||")

pExpVerbose :: Parser (Exp ())
pExpVerbose = choice [
    do pSymbol "let"
       p <- pPat False False
       pSymbol "="
       e1 <- pExpVerbose
       pSymbol "in"
       ELet () p e1 <$> pExpVerbose
  , do pChar '\\'
       p <- pPat False False
       pSymbol "->"
       ELam () p <$> pExpVerbose
  , do pSymbol "if"
       e1 <- pExpVerbose
       pSymbol "then"
       e2 <- pExpVerbose
       pSymbol "else"
       e3 <- pExpVerbose
       return $ EIf () e1 e2 e3
  , do pSymbol "case"
       e <- pExpVerbose
       pSymbol "of"
       pChar '{'
       branches <- sepBy1 (do
         p <- pPat True True
         pSymbol "->"
         e <- pExpVerbose
         return (p,e)) (pChar ';')
       pChar '}'
       return $ ECase () e branches
  , pExpOr]

pExp :: Parser (Exp ())
pExp = pSpace *> pExpVerbose

  -- parse type signatures
pTypeSignature :: Parser (Def ())
pTypeSignature = do
    name <- pIdent
    pChar ':'
    t <- pType
    pChar ';'
    return $ DTypeSig name t

pDataDec :: Parser (Def ())
pDataDec = do
  pSymbol "data"
  uid <- pUIdent
  vars <- many pIdent
  pSymbol "where"
  pChar '{'
  constructors <- sepBy (do
    con <- pUIdent
    pChar ':'
    typ <- pType
    return (con,typ)) (pChar ';')
  pChar '}'
  pChar ';'
  return $ DDataDec uid vars constructors

  -- parse function clauses
pEquation :: Parser (Def ())
pEquation = do
    name <- pIdent
    patterns <- many (pPat True False)
    pSymbol "="
    exp <- pExp
    pChar ';'
    return $ DEquation () name patterns exp

-- parse patterns

pPatClosed :: Bool -> Bool -> Parser (Pat ())
pPatClosed allowConstants allowNary = choice $ maybe ++ always
  where maybe  = [PConst ()          <$> pConst | allowConstants]
        always = [ PVar  ()          <$> pIdent
                 , flip (PAdt ()) [] <$> pUIdent
                 , PWild ()          <$  pChar '_'
                 , do pChar '('
                      ps <- sepBy (pPatAs allowConstants allowNary) (pChar ',') <* pChar ')'
                      case ps of
                        []      -> pure $ PNil ()
                        [p]     -> pure p
                        (_:_:_) -> pure (PTup () ps)
                 ]

pPatApp :: Bool -> Bool -> Parser (Pat ())
pPatApp allowconstants allowNary = choice $ pAdt ++ [pPatClosed allowconstants allowNary]
  where
      pAdt = if allowNary
        then [adt]
        else [ try $ parens adt
             , pPatClosed allowconstants allowNary
             ]
      adt = do con  <- pUIdent
               vars <- many (pPatClosed allowconstants allowNary)
               return $ PAdt () con vars

pPatAs :: Bool -> Bool -> Parser (Pat ())
pPatAs allowConstants allowNary = choice
  [ try $ do x <- pIdent
             pSymbol "as"
             p <- pPatAs allowConstants allowNary
             return $ PAs () x p
  , pPatApp allowConstants allowNary]

pPat :: Bool -> Bool -> Parser (Pat ())
pPat allowConstants allowNary = pSpace *> pPatAs allowConstants allowNary

-- parse constants

pConst :: Parser Lit
pConst = choice [
    try $ LFloat  <$> Lexer.lexeme pSpace Lexer.float
  , LInt          <$> Lexer.lexeme pSpace Lexer.decimal
  , LBool         <$> ((True <$ pSymbol "True") <|> (False <$ pSymbol "False"))
  , LNil          <$  pSymbol "()"
  ]

-- parser utilities

parens :: Parser a -> Parser a
parens p = label "parse a type wrapped in parentheses" $ do
    pSymbol "("
    a <- p
    pSymbol ")"
    return a

pIdent :: Parser Ident
pIdent = try $ do
    a <- lowerChar
    rest <- many $ choice [letterChar, digitChar, char '_']
    trailings <- many (char '\'')
    pSpace
    let x = a:(rest++trailings)
    if x `elem` pkeywords
        then fail "found keyword, expected identifier"
        else return $ Ident x

pUIdent :: Parser UIdent
pUIdent = try $ do
    a <- upperChar
    rest <- many $ choice [letterChar, digitChar, char '_']
    pSpace
    let x = a:rest
    if x `elem` pkeywords
        then fail "found keyword, expected uppercase identifier"
        else pure $ UIdent x

pSymbol :: T.Text -> Parser T.Text
pSymbol = Lexer.symbol pSpace

pChar :: Char -> Parser ()
pChar c = void (char c <* pSpace)

pSpace :: Parser ()
pSpace = Lexer.space 
           (void spaceChar) 
           (Lexer.skipLineComment "--") 
           (Lexer.skipBlockComment "{-" "-}")

pkeywords :: [String]
pkeywords = [
  -- types
    "Bool"
  , "Int"
  , "Float"
  
  -- constants
  , "True"
  , "False"
  
  -- misc
  , "data"
  , "where"
  , "case"
  , "of"
  , "let"
  , "in"
  , "if"
  , "then"
  , "else"
  , "as"
  ]

printTree :: Print a => a -> String
printTree = render . prt 0

type Doc = [ShowS] -> [ShowS]

doc :: ShowS -> Doc
doc = (:)

render :: Doc -> String
render d = rend 0 (map ($ "") $ d []) "" where
  rend i ss = case ss of
    "["      :ts -> showChar '[' . rend i ts
    "("      :ts -> showChar '(' . rend i ts
    "{"      :ts -> showChar '{' . new (i+1) . rend (i+1) ts
    "}" : ";":ts -> new (i-1) . space "}" . showChar ';' . new (i-1) . rend (i-1) ts
    "}"      :ts -> new (i-1) . showChar '}' . new (i-1) . rend (i-1) ts
    [";"]        -> showChar ';'
    ";"      :ts -> showChar ';' . new i . rend i ts
    t  : ts@(p:_) | closingOrPunctuation p -> showString t . rend i ts
    t        :ts -> space t . rend i ts
    _            -> id
  new i     = showChar '\n' . replicateS (2*i) (showChar ' ') . dropWhile isSpace
  space t s =
    case (all isSpace t', null spc, null rest) of
      (True , _   , True ) -> []              -- remove trailing space
      (False, _   , True ) -> t'              -- remove trailing space
      (False, True, False) -> t' ++ ' ' : s   -- add space if none
      _                    -> t' ++ s
    where
      t'          = showString t []
      (spc, rest) = span isSpace s

  closingOrPunctuation :: String -> Bool
  closingOrPunctuation [c] = c `elem` closerOrPunct
  closingOrPunctuation _   = False

  closerOrPunct :: String
  closerOrPunct = ")],;"

parenth :: Doc -> Doc
parenth ss = doc (showChar '(') . ss . doc (showChar ')')

concatS :: [ShowS] -> ShowS
concatS = foldr (.) id

concatD :: [Doc] -> Doc
concatD = foldr (.) id

replicateS :: Int -> ShowS -> ShowS
replicateS n f = concatS (replicate n f)

-- | The printer class does the job.

class Print a where
  prt :: Int -> a -> Doc
  prtList :: Int -> [a] -> Doc
  prtList i = concatD . map (prt i)

instance {-# OVERLAPPABLE #-} Print a => Print [a] where
  prt = prtList

instance Print Char where
  prt _ s = doc (showChar '\'' . mkEsc '\'' s . showChar '\'')
  prtList _ s = doc (showChar '"' . concatS (map (mkEsc '"') s) . showChar '"')

mkEsc :: Char -> Char -> ShowS
mkEsc q s = case s of
  _ | s == q -> showChar '\\' . showChar s
  '\\'-> showString "\\\\"
  '\n' -> showString "\\n"
  '\t' -> showString "\\t"
  _ -> showChar s

prPrec :: Int -> Int -> Doc -> Doc
prPrec i j = if j < i then parenth else id

instance Print () where
  prt _ x = doc (shows x)

instance Print Int where
  prt _ x = doc (shows x)

instance Print Double where
  prt _ x = doc (shows x)

instance Print Bool where
  prt _ x = doc (shows x)

instance Print Ident where
  prt _ (Ident i) = doc $ showString i
  prtList _ [] = concatD []
  prtList _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print UIdent where
  prt _ (UIdent i) = doc $ showString i

instance Print a => Print [Def a] where
  prt = prtList

instance Print a => Print (Def a) where
  prt i e = case e of
    DEquation a id pats exp -> prPrec i 0 (concatD [prt 0 id, prt 0 pats, doc (showString "="), prt 0 exp, doc (showString ":"), prt 0 a])
    DTypeSig id type_ -> prPrec i 0 (concatD [prt 0 id, doc (showString ":"), prt 0 type_])
    DDataDec uident ids constructordecs -> prPrec i 0 (concatD [doc (showString "data"), prt 0 uident, prt 0 ids, doc (showString "where"), doc (showString "{"), prt 0 constructordecs, doc (showString "}")])
  prtList _ [] = concatD []
  prtList _ [x] = concatD [prt 0 x]
  prtList _ (x:xs) = concatD [prt 0 x, doc (showString ";"), prt 0 xs]

instance Print (UIdent, Type) where
  prt i (uid,t) = prPrec i 0 (concatD [prt 0 uid, doc (showString ":"), prt 0 t])
  prtList _ [] = concatD []
  prtList _ [x] = concatD [prt 0 x]
  prtList _ (x:xs) = concatD [prt 0 x, doc (showString ";"), prt 0 xs]

instance Print [(UIdent, Type)] where
  prt = prtList

instance Print [Ident] where
  prt = prtList

instance Print Type where
  prt i e = case e of
    TLam type_1 type_2 -> prPrec i 0 (concatD [prt 1 type_1, doc (showString "->"), prt 0 type_2])
    TVar id -> prPrec i 1 (concatD [prt 0 id])
    TTup ts -> prPrec i 1 (concatD ([doc (showString "(")] ++ printTups ts ++ [doc (showString ")")]))
    TInt -> prPrec i 2 (concatD [doc (showString "Int")])
    TFloat -> prPrec i 2 (concatD [doc (showString "Float")])
    TBool -> prPrec i 2 (concatD [doc (showString "Bool")])
    TNil -> prPrec i 2 (concatD [doc (showString "()")])
    TAdt uident types -> prPrec i 2 (concatD [prt 0 uident, prt 1 types])
    where
        printTups [] = []
        printTups [x] = [prt 0 x]
        printTups (x:y:xs) = [prt 0 x, doc (showString ",")] ++ printTups (y:xs) 
  prtList n [] = concatD []
  prtList n (x:xs) = concatD [prt n x, prt n xs]


instance Print [Type] where
  prt = prtList

instance Print a => Print (Exp a) where
  prt i e = case e of
    ELet a pat exp1 exp2 -> prPrec i 0 (concatD [doc (showString "let"), prt 0 pat, doc (showString "="), prt 0 exp1, doc (showString "in"), prt 0 exp2])
    ELam a pat exp -> prPrec i 0 (concatD [doc (showString "\\"), prt 0 pat, doc (showString "->"), prt 0 exp])
    EApp a exp1 exp2 -> prPrec i 6 (concatD [prt 6 exp1, prt 7 exp2])
    EBin a exp1 exp2 o -> prPrec i 4 (concatD [prt 4 exp1, prt 4 o, prt 5 exp2])
    EUn a e o -> prPrec i 4 (concatD [prt 4 o, prt 4 e])
    ETup a es -> prPrec i 7 (concatD ([doc (showString "(")] ++ printTups es ++ [doc (showString ")")]))
    EVar a id -> prPrec i 7 (concatD [prt 0 id])
    ECon a uid -> prPrec i 7 (concatD [prt 0 uid])
    ELit a const -> prPrec i 7 (concatD [prt 0 const])
    ECase a exp patmatchs -> prPrec i 0 (concatD [doc (showString "case"), prt 0 exp, doc (showString "of"), doc (showString "{"), prt 0 patmatchs, doc (showString "}")])
    EIf a exp1 exp2 exp3 -> prPrec i 0 (concatD [doc (showString "if"), prt 0 exp1, doc (showString "then"), prt 0 exp2, doc (showString "else"), prt 0 exp3])
    where
        printTups [] = []
        printTups [x] = [prt 0 x]
        printTups (x:y:xs) = [prt 0 x, doc (showString ",")] ++ printTups (y:xs)

  prtList _ [] = concatD []
  prtList _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print a => Print (Pat a, Exp a) where
  prt i (pat,exp) = prPrec i 0 (concatD [prt 0 pat, doc (showString "->"), prt 0 exp])
  prtList _ [x] = concatD [prt 0 x]
  prtList _ (x:xs) = concatD [prt 0 x, doc (showString ";"), prt 0 xs]

instance Print a => Print [Exp a] where
  prt = prtList

instance Print a => Print (Binop a) where
  prt i op = case op of
    Add a -> prPrec i 2 (concatD [doc (showString "+")])
    Sub a -> prPrec i 2 (concatD [doc (showString "-")])
    Mul a -> prPrec i 2 (concatD [doc (showString "*")])
    Div a -> prPrec i 2 (concatD [doc (showString "/")])
    OLT a -> prPrec i 2 (concatD [doc (showString "<")])
    OLE a -> prPrec i 2 (concatD [doc (showString "<=")])
    OGT a -> prPrec i 2 (concatD [doc (showString ">")])
    OGE a -> prPrec i 2 (concatD [doc (showString ">=")])
    OEQ a -> prPrec i 2 (concatD [doc (showString "==")])
    And a -> prPrec i 2 (concatD [doc (showString "&&")])
    Or a  -> prPrec i 2 (concatD [doc (showString "||")])

instance Print a => Print (Unop a) where
  prt i op = case op of
    Not a -> prPrec i 2 (concatD [doc (showString "!")])

instance Print Lit where
  prt i e = case e of
    LInt n -> prPrec i 0 (concatD [prt 0 n])
    LFloat n -> prPrec i 0 (concatD [prt 0 n])
    LBool n -> prPrec i 0 (concatD [prt 0 n])
    LNil -> prPrec i 0 (concatD [doc (showString "()")])

instance Print (Pat a) where
  prt i e = case e of
    PConst _ const -> prPrec i 0 (concatD [prt 0 const])
    PVar _ id -> prPrec i 0 (concatD [prt 0 id])
    PNil _ -> prPrec i 0 (concatD [doc (showString "()")])
    PWild _ -> prPrec i 0 (concatD [doc (showString "_")])
    PAs _ id pat -> prPrec i 2 (concatD [prt 0 id, doc (showString "as"), prt 0 pat])
    PAdt _ uident [] -> prPrec i 0 (concatD [prt 0 uident])
    PAdt _ uident adtpats -> prPrec i 0 (concatD [doc (showString "("), prt 0 uident, prt 0 adtpats, doc (showString ")")])
    PTup _ ps -> prPrec i 1 (concatD $ [doc (showString "(")] ++ printTups ps ++ [doc (showString ")")])
    where
        printTups [] = []
        printTups [x] = [prt 0 x]
        printTups (x:y:xs) = [prt 0 x, doc (showString ",")] ++ printTups (y:xs) 
  prtList _ [] = concatD []
  prtList _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print [Pat a] where
  prt = prtList

instance Print a => Print (Function a) where
  prt i f = prtList 0 $ concat [maybe [] (\t -> [DTypeSig (name f) t]) (typesig f), equations f]
  prtList _ [] = concatD []
  prtList _ (x:xs) = concatD [prt 0 x, prt 0 xs]

instance Print a => Print (Program a) where
  prt i p = concatD [prtList 0 datadecs, prtList 0 (functions p ++ [main p])]
    where
        datadecs :: [Def a]
        datadecs = map (\(uid, vars, cons) -> DDataDec uid vars cons) (datatypes p)

\end{code}