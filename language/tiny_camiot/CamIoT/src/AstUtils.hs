{-# LANGUAGE FlexibleInstances #-}
module AstUtils(
    getExpvar
  , getTypvar  

  , tupExp
  , deTupExp
  , tupType
  , deTupType
  , deTupPat
  , tupPat
  , deAdtPat
  , adtPat
  , getPatType
  , getExpType
  , getPMType

  , function_type
  , unwrap_function
  , count_arguments

  , (*->)
  , bool
  , int
  , float
) where

import AbsTinyCamiot
import Substitution

-- TODO make heavy use of this bad boy.... it would make
-- the inference code easier to read, I believe
infixr 8 *->
(*->) :: Type () -> Type () -> Type ()
t1 *-> t2 = TLam () t1 t2

getExpvar :: Exp a -> a
getExpvar e = case e of
    ETup a _      -> a
    ECase a _ _   -> a
    ELet a _ _ _  -> a
    ELetR a _ _ _ -> a
    ELam a _ _    -> a
    EIf a _ _ _   -> a
    EApp a _ _    -> a
    EOr a _ _     -> a
    EAnd a _ _    -> a
    ERel a _ _ _  -> a
    EAdd a _ _ _  -> a
    EMul a _ _ _  -> a
    ENot a _      -> a
    EVar a _      -> a
    EConst a _    -> a

getTypvar :: Type a -> a
getTypvar (TLam a _ _) = a
getTypvar (TTup a _)   = a
getTypvar (TNil a)     = a
getTypvar (TVar a _)   = a
getTypvar (TAdt a _ _) = a
getTypvar (TInt a)     = a
getTypvar (TBool a)    = a
getTypvar (TFloat a)   = a

getPatvar :: Pat a -> a
getPatvar p = case p of
    PConst a _   -> a
    PVar a _     -> a
    PZAdt a _    -> a
    PNAdt a _ _  -> a
    PWild a      -> a
    PNil a       -> a
    PTup a _     -> a
    PLay a _ _   -> a
    PTyped a _ _ -> a

{- Some conversion to and from closely related types -}
tupExp :: Exp a -> TupExp a
tupExp e = ETupExp (getExpvar e) e

deTupExp :: TupExp a -> Exp a
deTupExp (ETupExp _ e) = e

tupType :: Type a -> TupType a
tupType t = TTupType (getTypvar t) t

deTupType :: TupType a -> Type a
deTupType (TTupType _ t) = t

deTupPat :: TupPat a -> Pat a
deTupPat (PTupPat _ p) = p

tupPat :: Pat a -> TupPat a
tupPat p = PTupPat (getPatvar p) p

deAdtPat :: AdtPat a -> Pat a
deAdtPat (PAdtPat _ p) = p

adtPat :: Pat a -> AdtPat a
adtPat p = PAdtPat (getPatvar p) p

getPatType :: Pat () -> Type ()
getPatType (PTyped _ _ t) = t
getPatType _ = error "please don't end up here" -- TODO backtrack and take care of this

getExpType :: Exp () -> Type ()
getExpType (ETyped _ _ t) = t
getExpType _ = error "please don't end up here" -- TODO backtrack and take care of this

getPMType :: PatMatch () -> Type ()
getPMType (PM _ _ (ETyped _ _ t)) = t

-- builds a function type from the list of argument types and the result type
function_type :: [Type ()] -> Type () -> Type ()
function_type [] res     = res
function_type (x:xs) res = TLam () x (function_type xs res)

-- fetch the final construction of a type
-- e.g unwrap function (a -> b -> Either a b) = Either a b
unwrap_function :: Type () -> Type ()
unwrap_function (TLam () _ t) = unwrap_function t
unwrap_function t             = t

count_arguments :: Type () -> Int
count_arguments (TLam () _ t) = 1 + count_arguments t
count_arguments _             = 0

-- synonyms for the built-in types
bool :: Type ()
bool = TBool () --TAdt () (UIdent "Bool") []

int :: Type ()
int = TInt () --TAdt () (UIdent "Int") []

float :: Type ()
float = TFloat () -- TAdt () (UIdent "Float") []

{- Substitution instances for backtracking -}

-- these instances are meant to be used when applying the inferred substitution to the
-- type annotated AST produced while typechecking.
instance Substitutable (Def ()) where
  apply s (DEquation a ident pats exp) = DEquation a ident (apply s pats) (apply s exp)
  apply _ d = d

  ftv d = undefined -- see below

instance Substitutable (Pat ()) where
  apply s (PTyped a p t)        = PTyped a (apply s p) (apply s t)
  apply s (PNAdt a con adtpats) = PNAdt a con (map (apply s) adtpats)
  apply s (PTup a tuppats)      = PTup a (map (apply s) tuppats)
  apply s (PLay a var pat)      = PLay a var (apply s pat)
  apply s p                     = p

  ftv p = undefined -- don't think we need this.. TODO backtrack here,
                    -- either implement for good measure or think of something else

instance Substitutable (AdtPat ()) where
  apply s (PAdtPat a p) = PAdtPat a (apply s p)
  
  ftv p = undefined -- same reasoning as above

instance Substitutable (TupPat ()) where
  apply s (PTupPat a p) = PTupPat a (apply s p)

  ftv p = undefined -- same reasoning as above

instance Substitutable (Exp ()) where
  apply s (ETyped a e t) = ETyped a (apply s e) (apply s t)
  apply s (ETup a texps) = ETup a (map (apply s) texps)
  apply s (ECase a e branches) = ECase a (apply s e) (map (apply s) branches)
  apply s (ELet a p e1 e2) = ELet a (apply s p) (apply s e1) (apply s e2)
  apply s (ELetR a p e1 e2) = ELetR a (apply s p) (apply s e1) (apply s e2)
  apply s (ELam a p e)   = ELam a (apply s p) (apply s e)
  apply s (EIf a e1 e2 e3)  = EIf a (apply s e1) (apply s e2) (apply s e3)
  apply s (EApp a e1 e2)   = EApp a (apply s e1) (apply s e2)
  apply s (EOr a e1 e2)    = EOr a (apply s e1) (apply s e2)
  apply s (EAnd a e1 e2)   = EAnd a (apply s e1) (apply s e2)
  apply s (ERel a e1 op e2) = ERel a (apply s e1) (apply s op) (apply s e2)
  apply s (EAdd a e1 op e2) = EAdd a (apply s e1) (apply s op) (apply s e2)
  apply s (EMul a e1 op e2) = EMul a (apply s e1) (apply s op) (apply s e2)
  apply s (ENot a e)     = ENot a (apply s e)
  apply s e = e

  ftv p = undefined -- same reasoning as above

instance Substitutable (TupExp ()) where
  apply s (ETupExp a e) = ETupExp a (apply s e)
  ftv e = undefined -- same reasoning as above

instance Substitutable (PatMatch ()) where
  apply s (PM a p e) = PM a (apply s p) (apply s e)
  ftv p = undefined -- same reasoning as above

instance Substitutable (AddOp ()) where
  apply s (AddOpTyped a op t) = AddOpTyped a op (apply s t)
  ftv p = undefined -- same reasoning as above

instance Substitutable (MulOp ()) where
  apply s (MulOpTyped a op t) = MulOpTyped a op (apply s t)
  ftv p = undefined -- same reasoning as above

instance Substitutable (RelOp ()) where
  apply s (RelOpTyped a op t) = RelOpTyped a op (apply s t)
  ftv p = undefined -- same reasoning as above