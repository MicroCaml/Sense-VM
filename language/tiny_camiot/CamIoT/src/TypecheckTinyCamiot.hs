{-# LANGUAGE FlexibleInstances #-}
module TypecheckTinyCamiot where

import AbsTinyCamiot
import PrintTinyCamiot

import Control.Monad.Trans
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer

import Control.Monad.Except
import Data.Maybe
import Data.Foldable
import qualified Data.Map as Map
import qualified Data.Set as Set

data Scheme = Forall [Ident] (Type ())
newtype TEnv = TEnv (Map.Map Ident (Type ()))
emptyEnv :: TEnv
emptyEnv = TEnv Map.empty

extend :: TEnv -> (Ident, Scheme) -> TEnv
extend = undefined

restrict :: TEnv -> Ident -> TEnv
restrict = undefined

type Subst = Map.Map Ident (Type ())

nullSubst :: Subst
nullSubst = Map.empty

compose :: Subst -> Subst -> Subst
s1 `compose` s2 = Map.map (apply s1) s2 `Map.union` s1

class Substitutable a where
    apply :: Subst -> a -> a
    ftv :: a -> Set.Set Ident

instance Substitutable (Type ()) where
    apply s (TLam a t1 t2)     = TLam a (apply s t1) (apply s t2)
    apply s (TPair a t1 t2)    = TPair a (apply s t1) (apply s t2)
    apply s (TVar a var)       = Map.findWithDefault (TVar a var) var s
    apply s (TAdt a con types) = TAdt a con (map (apply s) types)
    apply _ (TInt a)           = TInt a
    apply _ (TFloat a)         = TFloat a
    apply _ (TBool a)          = TBool a

    ftv (TLam _ t1 t2)     = Set.union (ftv t1) (ftv t2)
    ftv (TPair _ t1 t2)    = Set.union (ftv t1) (ftv t2)
    ftv (TVar _ var)       = Set.singleton var
    ftv (TAdt _ con types) = Set.unions (map ftv types)
    ftv (TInt _)           = Set.empty
    ftv (TFloat _)         = Set.empty
    ftv (TBool _)          = Set.empty

instance Substitutable Scheme where
    apply s (Forall vars t) = Forall vars $ apply s' t
                              where s' = foldr Map.delete s vars

    ftv (Forall vars t) = ftv t `Set.difference` Set.fromList vars

instance Substitutable a => Substitutable [a] where
    apply = fmap . apply
    ftv   = foldr (Set.union . ftv) Set.empty

instance Substitutable TEnv where
  apply s (TEnv env) =  TEnv $ Map.map (apply s) env
  ftv (TEnv env) = ftv $ Map.elems env

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: TC (Type ())
fresh = do
  s <- get
  put $ s { num = (num s) + 1}
  return $ TVar () (Ident (letters !! (num s)))

occursCheck :: Substitutable a => Ident -> a -> Bool
occursCheck a t = a `Set.member` ftv t

unify ::  Type () -> Type () -> TC Subst
unify (TLam _ t1 t2) (TLam _ t1' t2') = do
    s1 <- unify t1 t1'
    s2 <- unify (apply s1 t2) (apply s1 t2')
    return (s2 `compose` s1)

unify (TPair _ t1 t2) (TPair _ t1' t2') = do
    s1 <- unify t1 t1'
    s2 <- unify (apply s1 t2) (apply s1 t2')
    return $ s2 `compose` s1

unify (TAdt _ con []) (TAdt _ con' [])        | con == con' = return nullSubst
unify (TAdt _ con types) (TAdt _ con' types') | con == con' =
    -- I hope this is right?
    -- I want to unify the first 'pair' of zipped types, and then try to unify
    -- the subsequent pair by first applying the substitution I just got by
    -- unifying the first pair
    foldlM (\s' (t1,t2) -> unify (apply s' t1) (apply s' t2)) nullSubst (zip types types')

unify (TInt ()) (TInt ())     = return nullSubst
unify (TBool ()) (TBool ())   = return nullSubst
unify (TFloat ()) (TFloat ()) = return nullSubst

unify (TVar _ var) t = bind var t
unify t (TVar _ var) = bind var t

unify t1 t2 = throwError $ UnificationFail t1 t2

bind :: Ident -> Type () -> TC Subst
bind a t | t == TVar () a  = return nullSubst
         | occursCheck a t = throwError $ InfiniteType a t
         | otherwise       = return $ Map.singleton a t

instantiate ::  Scheme -> TC (Type ())
instantiate (Forall vars t) = do
  vars' <- mapM (const fresh) vars
  let s = Map.fromList $ zip vars vars'
  return $ apply s t

generalize :: TEnv -> Type () -> Scheme
generalize env t  = Forall vars t
    where vars = Set.toList $ ftv t `Set.difference` ftv env
{---------------------------------------------------------------------}
{- ******************** -}
-- top level typecheck

typecheck :: [Def ()] -> IO (Either String [Def (Type ())])
typecheck defs = undefined
--    res <- runExceptT (runStateT pgm emptyState)
--    case res of
--        Left e -> return $ Left (show e)         -- error occured
--        Right (defs', _) -> return $ Right defs' -- TC completed
--  where pgm = check defs -- the monadic computation that TC's

{- ******************** -}
-- typecheck monad

-- Data type representing all possible errors that can be raised
-- Add variants and needed and include a show instance for it, so that
-- it is rendered nicely.
data TCError =
    InfiniteType Ident (Type ())
  | UnificationFail (Type ()) (Type ())
  | UnboundVariable String

instance Show TCError where

-- The state kept by the typechecker as it typechecks a program
data TCState = TCState { 
    num  :: Int
  , constructors :: Map.Map UIdent (Type ()) } deriving Show

emptyState :: TCState
emptyState = TCState 0 Map.empty

-- The typechecking monad! Please change as you see fit. Perhaps we don't
-- want IO in the bottom of it, but i find it usually helps me debug stuff,
-- as you can always just print whatever you want.
--type TC a = StateT TCState (ExceptT TCError IO) a
type Constraint = (Type (), Type ())

type TC a = ReaderT TEnv (
            WriterT [Constraint] (
            StateT TCState (
            ExceptT TCError 
            IO))) 
            a

runTC :: TC a -> TEnv -> IO (Either TCError ((a, [Constraint]), TCState))
runTC tc initEnv = do
    let rd = runReaderT tc initEnv
    let wr = runWriterT rd
    let st = runStateT wr emptyState
    let ex = runExceptT st
    ex

uni :: Type () -> Type () -> TC ()
uni t1 t2 = tell [(t1, t2)]

uniMany :: [Type ()] -> TC ()
uniMany [] = return ()
uniMany [x] = uni x x -- should be OK
uniMany (x:y:xs) = uni x y >> uniMany xs

inEnv :: (Ident, Scheme) -> TC a -> TC a
inEnv xsc m = inEnvMany [xsc] m

-- Extend the local environment with many variables
inEnvMany :: [(Ident, Scheme)] -> TC a -> TC a
inEnvMany xs m = do
    let scope e = foldl (\e' (x,sc) -> restrict e' x `extend` (x, sc)) e xs
    local scope m

lookupVar :: Ident -> TC (Type ())
lookupVar x@(Ident name) = do
    (TEnv env) <- ask
    case Map.lookup x env of
        Just t  -> return t
        Nothing -> throwError $ UnboundVariable name

lookupCons :: Con () -> TC (Type ())
lookupCons (Constructor () con) = do
    env <- get
    case Map.lookup con (constructors env) of
        Just t  -> return t
        Nothing -> error ""

lookupTypeSig :: Ident -> TC (Maybe (Type ()))
lookupTypeSig fun = do
    (TEnv env) <- ask
    return $ Map.lookup fun env

-- collect type sigs and put them in state
gatherTypeSigs :: [Def ()] -> TC () -> TC ()
gatherTypeSigs ds m = do
    let scope e = foldl f e (catMaybes (map go ds))
    local scope m
  where go (DTypeSig () fun t) = Just (fun, t)
        go _                   = Nothing

        f (TEnv e) (fun, t) = case Map.lookup fun e of
            Just _  -> error "same type sig appear twice"
            Nothing -> TEnv $ Map.insert fun t e

-- Gather type information about data declarations and their constructors
gatherDataDecs :: [Def ()] -> TC ()
gatherDataDecs [] = return ()
gatherDataDecs (d:ds) = case d of
    DDataDec () typ tvars cons -> do
        constructors <- mapM (consDecToType typ tvars) cons
        tryInsert constructors
        gatherDataDecs ds
    _ -> gatherDataDecs ds
  where
      tryInsert :: [(UIdent, Type ())] -> TC ()
      tryInsert []         = return ()
      tryInsert ((c,t):xs) = do
          env <- get
          let cons = constructors env
          case Map.lookup c cons of
              Just t' -> error ""
              Nothing -> put (env { constructors = Map.insert c t cons}) >> tryInsert xs

      -- Given a UIdent, e.g 'Maybe', and a list of type vars, e,g [a], and
      -- a constructor, e.g Just, see if the type for Just is correct
      -- TODO check that the type variables are bound by the data declaration
      consDecToType :: UIdent -> [Ident] -> ConstructorDec () -> TC (UIdent, Type ())
      consDecToType typ tvars (ConstDec () con t) =
          -- get the intended creation
          let goal = getGoal t
          -- Is the intended creation an ADT?
          in case goal of
                                     -- Is it the correct ADT?
              (TAdt () con' vars) -> case typ == con' of
                           -- Is the arity correct?
                  True  -> case length tvars == length vars of
                               -- good!
                      True  -> return $ (con, t)
                      False -> error ""
                  False -> error ""
              _ -> error ""
      
      getGoal (TLam _ _ r) = getGoal r
      getGoal t            = t

{- ******************** -}
-- typecheck

check :: [Def ()] -> TC [Def (Type ())]
check = undefined

checkSingle :: Def () -> TC ()
checkSingle d = case d of
    DEquation () name pats exp -> do
        patinfo <- mapM (flip checkPattern True) pats
        let types = map fst patinfo
        let vars = concat $ map snd patinfo
        t <- inEnvMany (map (\(x,t') -> (x, Forall [] t')) vars) (checkExp exp)

        let inferredType = function_type types t
        sig <- lookupTypeSig name
        case sig of
            Just assigned -> uni assigned inferredType
            Nothing -> return ()
        undefined
    _ -> return ()

-- Input: a pattern
-- output
--   - component 1: Type of the top-level pattern
--   - component 2: List of variables and their type variables created by the pattern
-- TODO Maybe the second component should be name and type scheme?
-- TODO rewrite this behemoth
checkPattern :: Pat () -> Bool -> TC (Type (), [(Ident, Type ())])
checkPattern pattern allowConstants = case pattern of
    PConst a c       -> if allowConstants 
                        then return $ (checkConstType c, []) 
                        else error ""
    PVar a var       -> fresh >>= \tv -> return (tv, [(var, tv)])
    PAdt a con pats  -> do
        (typs, vars) <- unzip <$> mapM (flip checkPattern allowConstants) pats
        t <- lookupCons (Constructor () con)
        let t' = unwrap_function t
        -- is it actually an ADT?
        case t' of
                                    -- great, correct arity?
            (TAdt () con' vars') -> case length vars == length vars' of
                True  -> return $ (TAdt () con' typs, concat vars)
                False -> error "wrong arity"
            _ -> error "" -- This happens if someone does data (a -> b) where ...
    PWild a          -> fresh >>= \tv -> return (tv, [])
    PNil a           -> return (TNil (), [])
    PTup a pat1 pat2 -> do
        (t1, tpat1) <- checkPattern pat1 allowConstants
        (t2, tpat2) <- checkPattern pat2 allowConstants
        return $ (TPair () t1 t2, tpat1 ++ tpat2)
    PLay a var pat   -> do
        (tv, tpat) <- checkPattern pat allowConstants
        return $ (tv, (var, tv) : tpat)

checkConstType :: Const () -> Type ()
checkConstType const = case const of
    CInt a integer  -> int
    CFloat a double -> float
    CTrue a         -> bool
    CFalse a        -> bool
    CNil a          -> TNil ()

checkCases :: Type () -> [PatMatch ()] -> TC (Type ())
checkCases t pm = do
    types <- mapM (checkCase t) pm
    uniMany types
    return $ head types

checkCase :: Type () -> PatMatch () -> TC (Type ())
checkCase t (PM () pat e1) = do
    (t', vars) <- checkPattern pat True
    uni t t'
    inEnvMany (map (\(x, t'') -> (x, Forall [] t'')) vars) (checkExp e1) 
    

checkExp :: Exp () -> TC (Type ())
checkExp e = case e of
    ECase _ e1 patterns -> do
        te1 <- checkExp e1
        checkCases te1 patterns

    ELet _ pattern e1 e2 -> do
        (tpat, vars) <- checkPattern pattern False
        te1 <- checkExp e1
        uni tpat te1
        inEnvMany (map (\(x,t') -> (x, Forall [] t')) vars) (checkExp e2)

    -- TODO
    ELetR _ pattern e1 e2 -> undefined

    ELam _ pattern e1 -> do
        -- TODO Maybe we want checkLambdaPattern to
        -- return Schemes with the proper type variables
        (tpat, vars) <- checkPattern pattern False
        t <- inEnvMany (map (\(x,t') -> (x, Forall [] t')) vars) (checkExp e1)
        return $ TLam () tpat t
        
    ECon _ constructor exps -> do
        texps <- mapM checkExp exps
        tv <- fresh
        let u1 = function_type texps tv
        u2 <- lookupCons constructor
        uni u1 u2
        return tv

    EIf _ e1 e2 e3 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        te3 <- checkExp e3
        uni te1 bool
        uni te2 te3
        return te2

    EApp _ e1 e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        tv <- fresh
        uni te1 (TLam () te2 tv)
        return tv

    EOr _ e1 e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        uni te1 bool
        uni te2 bool
        return bool

    EAnd _ e1 e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        uni te1 bool
        uni te2 bool
        return bool

    ERel _ e1 op e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        tv <- fresh
        let u1 = TLam () te1 (TLam () te2 tv)
            u2 = relOps Map.! op
        uni u1 u2
        return tv

    EAdd _ e1 op e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        tv <- fresh
        let u1 = TLam () te1 (TLam () te2 tv)
            u2 = addOps Map.! op
        uni u1 u2
        return tv

    EMul _ e1 op e2 -> do
        te1 <- checkExp e1
        te2 <- checkExp e2
        tv <- fresh
        let u1 = TLam () te1 (TLam () te2 tv)
            u2 = mulOps Map.! op
        uni u1 u2
        return tv

    ENot _ e1 -> do
        te1 <- checkExp e1
        uni te1 bool
        return bool

    EVar _ var -> lookupVar var

    ETup _ tupExps -> do
        let exps = map deTupExp tupExps
        texps <- mapM checkExp exps
        return $ TTup () texps

    EConst _ const -> case const of
        CInt a i   -> return int
        CFloat a f -> return float
        CTrue a    -> return bool
        CFalse a   -> return bool
        CNil a     -> undefined
{-

{- ******************** -}
-- typecheck utility functions

-- map over all definitions and create a type from every
-- data type declaration that is encountered.
collectTypes :: [Def ()] -> TC [Type ()]
collectTypes ds = return $ catMaybes $ map go ds
  where go (DDataDec _ name vars _) = 
           Just $ TAdt () name (map (TVar ()) vars)
        go _ = Nothing
-}
-- Extract the var from a typed expression
getExpvar :: Exp a -> a
getExpvar e = case e of
    ETup a _      -> a
    ECase a _ _   -> a
    ELet a _ _ _  -> a
    ELetR a _ _ _ -> a
    ELam a _ _    -> a
    EIf a _ _ _   -> a
    ECon a _ _    -> a
    EApp a _ _    -> a
    EOr a _ _     -> a
    EAnd a _ _    -> a
    ERel a _ _ _  -> a
    EAdd a _ _ _  -> a
    EMul a _ _ _  -> a
    ENot a _      -> a
    EVar a _      -> a
    EConst a _    -> a
{-
isFunctionType :: Type () -> Bool
isFunctionType (TLam _ _ _) = True
isFunctionType _            = False

-- Can an expression of the first type be applied
-- to an expression of the second type?
-- Returns either the resulting type or a type error
canApply :: Type () -> Type () -> Either (Type ()) (Exp () -> TCError)
canApply (TLam _ t rest) t' = case t == t' of
    True  -> Left rest 
    False -> Right $ \e -> TypeError e t' t

{- ******************** -}
-- ADT related utility functions
-}
tupExp :: Exp a -> TupExp a
tupExp e = ETupExp (getExpvar e) e

deTupExp :: TupExp a -> Exp a
deTupExp (ETupExp _ e) = e


-- synonyms for the built-in types
bool :: Type ()
bool = TAdt () (UIdent "Bool") []

int :: Type ()
int = TAdt () (UIdent "Int") []

float :: Type ()
float = TAdt () (UIdent "Float") []

-- TODO we can remove the 'duplice' operators and try to overload them
-- when we know how to attempt the unification when the types it can be
-- unified with are not arbitrary, but actually a subset of all types.
addOps :: Map.Map (AddOp ()) (Type ())
addOps = Map.fromList [
    (Plus   (), TLam () int   (TLam () int   int)),
    (FPlus  (), TLam () float (TLam () float float)),
    (Minus  (), TLam () int   (TLam () int   int)),
    (FMinus (), TLam () float (TLam () float float))]

mulOps :: Map.Map (MulOp ()) (Type ())
mulOps = Map.fromList [
    (Times  (), TLam () int   (TLam () int   int)),
    (FTImes (), TLam () float (TLam () float float)),
    (Div    (), TLam () int   (TLam () int   int)),
    (FDiv   (), TLam () float (TLam () float float))]

relOps :: Map.Map (RelOp ()) (Type ())
relOps = Map.fromList [
    (LTC  (), TLam () int   (TLam () int   bool)),
    (FLTC (), TLam () float (TLam () float bool)),
    (LEC  (), TLam () int   (TLam () int   bool)),
    (FLEC (), TLam () float (TLam () float bool)),
    (GTC  (), TLam () int   (TLam () int   bool)),
    (FGTC (), TLam () float (TLam () float bool)),
    (GEC  (), TLam () int   (TLam () int   bool)),
    (FGEC (), TLam () float (TLam () float bool)),
    (EQC  (), undefined {- TODO insert some type later, talk with Joel -})]

-- builds a function type from the list of argument types and the result type
function_type :: [Type ()] -> Type () -> Type ()
function_type [] res     = res
function_type (x:xs) res = TLam () x (function_type xs res)

-- fetch the final construction of a type
-- e.g unwrap function (a -> b -> Either a b) = Either a b
unwrap_function :: Type () -> Type ()
unwrap_function (TLam () _ t) = unwrap_function t
unwrap_function t             = t