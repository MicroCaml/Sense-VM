-- MIT License

-- Copyright (c) 2020 Abhiroop Sarkar

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
module Bytecode.GeneratorTH where

import Control.Monad.State.Strict
import Data.List(find, intercalate)
import Language.Haskell.TH
import Language.Haskell.TH.Desugar
import Language.Haskell.TH.Syntax

type Var = String

data ScopedVar = LocalVar Var
               | GlobalVar Var
               deriving (Ord, Show, Eq)

data Expr = Var Var
          | Let Var Expr
          | Call Expr [Expr]
          | Seq Expr Expr
          deriving (Ord,Eq)

instance Show Expr where
  show (Var v) = v
  show (Let v e) =  "let " <> v <> " = " <> show e
  show (Call e es) = show e <> "(" <> intercalate ", " (map show es) <> ")"
  show (Seq e1 e2) = show e1 <> ";\n" <> show e2

type Scope = [ScopedVar]

newtype Lower a =
  Lower
    { runLower :: State Scope a
    }
  deriving (Functor, Applicative, Monad, MonadState Scope)


lower :: DExp -> Expr
lower dexp = evalState (runLower (lowerExp dexp)) globals
  where
    globals = [] -- needs to be calculated in one pass


lowerExp :: DExp -> Lower Expr
lowerExp (Varname n _) = pure $! Var n -- qualified names and a lot of other cases not handled
lowerExp (DAppE e1 e2) =
  if isSequence e1
  then do
    let (Bind e) = e1
    let var = getLamVar e2
    e' <- if isVar e
          then do
           le <- lowerExp e
           pure $! Call le []
          else lowerExp e
    extendScope var
    e2' <- lowerExp e2
    pure $! Seq (Let var e') e2'
  else undefined
lowerExp _ = error "Yet to handle other cases"

isSequence :: DExp -> Bool
isSequence (Bind e) = True
isSequence _ = False

pattern Bind e =
  DAppE (DVarE (Name (OccName ">>=") (NameQ (ModName "GHC.Base")))) e

pattern Varname n q = DVarE (Name (OccName n) q)

-- XXX: An extremely partial function assuming this is only
-- called from the application of a bind operation
getLamVar :: DExp -> String
getLamVar (DLamE names _) = s
  where
    (n:_) = names
    (Name (OccName s) _) = n
getLamVar _ = error "Sequencing an incorrect operation"

extendScope :: Var -> Lower ()
extendScope v = modify $ \s -> LocalVar v : s


{-
data DExp = DVarE Name
          | DConE Name
          | DLitE Lit
          | DAppE DExp DExp
          | DAppTypeE DExp DType
          | DLamE [Name] DExp
          | DCaseE DExp [DMatch]
          | DLetE [DLetDec] DExp
          | DSigE DExp DType
          | DStaticE DExp
          deriving (Eq, Show, Typeable, Data, Generic)
-}

isVar :: DExp -> Bool
isVar (DVarE _) = True
isVar _ = False

isGlobal :: ScopedVar -> Bool
isGlobal (GlobalVar _) = True
isGlobal (LocalVar _)  = False

isLocal :: ScopedVar -> Bool
isLocal = not . isGlobal

generateC :: Q [Dec] -> Q [Dec]
generateC x = do
  x' <- x
  foo <- dsDecs x' :: Q [DDec]
  runIO $ do
    putStrLn "\nmyLangDefs (stub): would make definitions out of these:"
    putStrLn $ show foo -- $ pprint x' ++ "\n"
  return x'
