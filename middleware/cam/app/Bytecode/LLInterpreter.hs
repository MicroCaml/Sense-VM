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

module Bytecode.LLInterpreter ( Val (..)
                              , EnvContent (..)
                              , evaluate) where

import CAM
import Data.Int (Int32)
import Data.List (find)
import GHC.Arr
import qualified Control.Monad.State.Strict as S

{-

The low level interpreter with an explicit heap

-}

type Pointer = Int

data CellContent = V Val | P Pointer deriving (Show, Eq)

type HeapCell = (CellContent, CellContent)

nullPointer = -1
emptyCell   = (V VEmpty, P nullPointer)
heapSize    = 2000 --heap cells

type Heap  = Array Index HeapCell

data StackContent = SV Val | SP Pointer deriving (Show, Eq)

type Stack = [StackContent]

data EnvContent  = EV Val | EP Pointer deriving (Show, Eq)

type Environment = EnvContent

type Index = Int

type SymbolTable = [(Label, Index)]

data Code = Code { instrs :: Array Index Instruction
                 , symbolTable :: SymbolTable
                 , prevJump    :: [Index]
                 , environment :: Environment
                 , stack       :: Stack
                 , heap        :: Heap
                 , programCounter :: Index
                 } deriving Show

newtype Evaluate a =
  Evaluate
    { runEvaluate :: S.State Code a
    }
  deriving (Functor, Applicative, Monad, S.MonadState Code)


-- Val is basically Weak Head Normal Form
data Val = VInt  Int32   -- constants s(0)
         | VFloat Float  -- constants s(0)
         | VBool Bool    -- constants s(0)
         | VEmpty        -- empty tuple
         | VPair Val Val -- Pair
         | VCon Tag Val  -- first arg is the tag second is value with tag
         | VClosure Val Label -- closure; Val is the environment
         | VComb Label        -- closure of a combinator; no free variables
         deriving (Ord, Eq)

-- using Hinze's notation
instance Show Val where
  show (VInt i)   = show i
  show (VFloat f) = show f
  show (VBool b)  = show b
  show  VEmpty    = "()"
  show (VPair v1 v2) =
    "(" <> show v1 <> ", " <> show v2 <> ")"
  show (VCon t v) =
    "(" <> show t <> " : " <> show v  <> ")"
  show (VClosure v l) =
    "[" <> show v <> " : " <> show l  <> "]"
  show (VComb l) =
    "[" <> show l <> "]"

-- Take a sequence of stack machine instructions
-- and evaluate them to their normal form
evaluate :: CAM -> EnvContent
evaluate cam = val
  where
    code = initCode cam
    val  = S.evalState (runEvaluate eval) code

initCode :: CAM -> Code
initCode cam = Code { instrs = listArray (1, totalInstrs) caminstrs
                    , symbolTable = filteredEntries
                    , prevJump    = []
                    , environment = EV VEmpty
                    , stack       = []
                    , heap        = listArray (1, heapSize) initHeap
                    , programCounter = 1
                    }
  where
    instrsLabs = genInstrs cam dummyLabel
    indexedinstrsLabs = zip instrsLabs [1..]
    caminstrs = map (fst . fst) indexedinstrsLabs
    entries   = map (\((_,l),idx) -> (l,idx)) indexedinstrsLabs
    filteredEntries = filter (\(l,_) -> l /= dummyLabel) entries
    totalInstrs     = length caminstrs
    initHeap        = replicate heapSize emptyCell

genInstrs :: CAM -> Label -> [(Instruction, Label)]
genInstrs (Ins i) l = [(i, l)]
genInstrs (Seq c1 c2) l = genInstrs c1 l ++ genInstrs c2 dummyLabel
genInstrs (Lab l c) _   = genInstrs c l

eval :: Evaluate EnvContent
eval = do
  currentInstr <- readCurrent
  case currentInstr of
    FST ->
      do { incPC; fstEnv; eval }
    SND ->
      do { incPC; sndEnv; eval }
    ACC n  ->
      do { incPC; accessnth n; eval }
    REST n ->
      do { incPC; restnth n; eval }
    PUSH ->
      do { incPC; push; eval }
    SWAP ->
      do { incPC; swap; eval }
    QUOTE (LInt i)  ->
      do { incPC; loadi i; eval }
    QUOTE (LFloat f)  ->
      do { incPC; loadf f; eval }
    QUOTE (LBool b) ->
      do { incPC; loadb b; eval }
    CLEAR ->
      do { incPC; clear; eval }
    PRIM1 uop ->
      do { incPC; unaryop uop; eval }
    PRIM2 bop ->
      do { incPC; binaryop bop; eval }
    CONS ->
      do { incPC; cons; eval }
    CUR l  ->
      do { incPC; cur l; eval }
    PACK c ->
      do { incPC; pack c; eval }
    SKIP ->
      do { incPC; eval}
    STOP -> getEnv -- base case
    APP    -> do {      app; eval }
    RETURN -> do {  retBack; eval }
    CALL l -> do { jumpTo l; eval }
    GOTO l -> do {   goto l; eval }
    GOTOFALSE l ->
      do { gotofalse l; eval; }
    SWITCH conds ->
      do { switch conds; eval; }
    i ->
      error $! "Unsupported Instruction : " <> show i

-- Symbol Table operations

-- In this case we have a common error message
-- because this operation is only on a symbol table
(~>) :: SymbolTable -> Label -> Index
(~>) [] _ = error "Label missing in symbol table"
(~>) ((label,idx):st) l
  | l == label = idx
  | otherwise  = st ~> l

put :: SymbolTable -> Label -> Index -> SymbolTable
put st l idx = (l,idx) : st


emptyST :: SymbolTable
emptyST = []


-- Code operations

readCurrent :: Evaluate Instruction
readCurrent = do
  is <- S.gets instrs
  pc <- S.gets programCounter
  pure $! is ! pc

incPC :: Evaluate ()
incPC  = do
  pc <- S.gets programCounter
  S.modify $ \s -> s {programCounter = pc + 1}

-- jumpTo stores the jump point in the
-- prevJump field unlike goto
jumpTo :: Label -> Evaluate ()
jumpTo l = do
  pc <- S.gets programCounter
  st <- S.gets symbolTable
  pj <- S.gets prevJump
  let ix = st ~> l
  S.modify $ \s -> s { programCounter = ix
                     , prevJump = pc : pj
                     }

-- return back to the previous "jumped from" label
-- and increment the program counter by 1
retBack :: Evaluate ()
retBack = do
  pj <- S.gets prevJump
  S.modify $ \s -> s { programCounter = head pj + 1
                     , prevJump = tail pj
                     }

getEnv :: Evaluate Environment
getEnv = S.gets environment

getStack :: Evaluate Stack
getStack = S.gets stack

getHeap :: Evaluate Heap
getHeap = S.gets heap

popAndRest :: Evaluate (StackContent, Stack)
popAndRest = do
  st <- getStack
  let (h:t) = st
  return (h, t)

fstEnv :: Evaluate ()
fstEnv = do
  e <- getEnv
  h <- getHeap
  case e of
    EV (VPair v _) -> S.modify $ \s -> s { environment = EV v }
    EP pointer -> let heapcell = h ! pointer
                      fstHeap  = fst heapcell
                   in case fstHeap of
                        V val -> S.modify $ \s -> s { environment = EV val }
                        P ptr -> S.modify $ \s -> s { environment = EP ptr }
    _ -> error "first operation on incorrect value type"

sndEnv :: Evaluate ()
sndEnv = do
  e <- getEnv
  h <- getHeap
  case e of
    EV (VPair _ v) -> S.modify $ \s -> s { environment = EV v }
    EP pointer -> let heapcell = h ! pointer
                      sndHeap  = snd heapcell
                   in case sndHeap of
                        V val -> S.modify $ \s -> s { environment = EV val }
                        P ptr -> S.modify $ \s -> s { environment = EP ptr }
    _ -> error "second operation on incorrect value type"


accessnth :: Int -> Evaluate ()
accessnth 0 = sndEnv
accessnth n = do
  e <- getEnv
  fstEnv
  accessnth (n - 1)

restnth :: Int -> Evaluate ()
restnth 0 = pure ()
restnth n = do
  e <- getEnv
  fstEnv
  restnth (n - 1)

push :: Evaluate ()
push = do
  e  <- getEnv
  st <- getStack
  case e of
    EV val -> S.modify $ \s -> s { stack = (SV val) : st }
    EP ptr -> S.modify $ \s -> s { stack = (SP ptr) : st }

swap :: Evaluate ()
swap = do
  e      <- getEnv
  (sc, t) <- popAndRest
  case e of
    EV val -> S.modify $ \s -> s { stack = (SV val) : t }
    EP ptr -> S.modify $ \s -> s { stack = (SP ptr) : t }
  case sc of
    SV val -> S.modify $ \s -> s { environment = EV val }
    SP ptr -> S.modify $ \s -> s { environment = EP ptr }

loadi :: Int32 -> Evaluate ()
loadi i = S.modify $ \s -> s { environment = EV (VInt i) }

loadf :: Float -> Evaluate ()
loadf f = S.modify $ \s -> s { environment = EV (VFloat f) }

loadb :: Bool -> Evaluate ()
loadb b = S.modify $ \s -> s { environment = EV (VBool b) }

clear :: Evaluate ()
clear = S.modify $ \s -> s { environment = EV VEmpty }

unaryop :: UnaryOp -> Evaluate ()
unaryop uop = do
  e <- getEnv
  case uop of
    Abs -> do
      let EV (VInt i) = e -- XXX: Partial
      S.modify $ \s -> s { environment = EV $ VInt (abs i) }
    Neg -> do
      let EV (VInt i) = e
      S.modify $ \s -> s { environment = EV $ VInt (negate i) }
    NOT -> do
      let EV (VBool b) = e
      S.modify $ \s -> s { environment = EV $ VBool (not b) }
    DEC -> do
      let EV (VInt i) = e
      S.modify $ \s -> s { environment = EV $ VInt (i - 1) }

binaryop :: BinOp -> Evaluate ()
binaryop bop = do
  e      <- getEnv
  (h, t) <- popAndRest
  case bop of
    PlusI -> do
      let EV (VInt i1) = e -- XXX: Partial
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VInt (i2 + i1)
                         , stack = t
                         }
    MultiplyI -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VInt (i2 * i1)
                         , stack = t
                         }
    MinusI -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VInt (i2 - i1)
                         , stack = t
                         }
    PlusF -> do
      let EV (VFloat f1) = e -- XXX: Partial
      let SV (VFloat f2) = h
      S.modify $ \s -> s { environment = EV $ VFloat (f2 + f1)
                         , stack = t
                         }
    MultiplyF -> do
      let EV (VFloat f1) = e
      let SV (VFloat f2) = h
      S.modify $ \s -> s { environment = EV $ VFloat (f2 * f1)
                         , stack = t
                         }
    MinusF -> do
      let EV (VFloat f1) = e
      let SV (VFloat f2) = h
      S.modify $ \s -> s { environment = EV $ VFloat (f2 - f1)
                         , stack = t
                         }
    BGT -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VBool (i2 > i1)
                         , stack = t
                         }
    BLT -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VBool (i2 < i1)
                         , stack = t
                         }
    BGE -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VBool (i2 >= i1)
                         , stack = t
                         }
    BLE -> do
      let EV (VInt i1) = e
      let SV (VInt i2) = h
      S.modify $ \s -> s { environment = EV $ VBool (i2 <= i1)
                         , stack = t
                         }
    BEQ -> do
      case (e,h) of
        (EV (VInt i1), SV (VInt i2)) ->
          S.modify $ \s -> s { environment = EV $ VBool (i2 == i1)
                             , stack = t
                             }
        (EV (VFloat f1), SV (VFloat f2)) ->
          S.modify $ \s -> s { environment = EV $ VBool (f2 == f1)
                             , stack = t
                             }
        (EV (VBool b1), SV (VBool b2)) ->
          S.modify $ \s -> s { environment = EV $ VBool (b2 == b1)
                             , stack = t
                             }
        (EV VEmpty, SV VEmpty) ->
          S.modify $ \s -> s { environment = EV $ VBool True
                             , stack = t
                             }
        _ -> error "Equality not supported for other whnf types"

{-  HEAP growth and manipulation functions -}

cons :: Evaluate ()
cons = undefined-- do
  -- e      <- getEnv
  -- (h, t) <- popAndRest
  -- S.modify $ \s -> s { environment = VPair h e
  --                    , stack = t
  --                    }

cur :: Label -> Evaluate ()
cur l = undefined -- do
  -- e <- getEnv
  -- S.modify $ \s -> s { environment = VClosure e l }

pack :: Tag -> Evaluate ()
pack t = undefined -- do
  -- e <- getEnv
  -- S.modify $ \s -> s { environment = VCon t e }

app :: Evaluate ()
app = undefined -- do
  -- e      <- getEnv
  -- (h, t) <- popAndRest
  -- let (VClosure val label) = e -- XXX: Partial
  -- S.modify $ \s -> s { environment = VPair val h
  --                    , stack = t
  --                    }
  -- jumpTo label

switch :: [(Tag, Label)] -> Evaluate ()
switch conds = undefined -- do
  -- e      <- getEnv
  -- (h, t) <- popAndRest
  -- case e of
  --   VCon ci v1 -> do
  --     let (_, label) =
  --           case find (\(c,_) -> c == ci || c == wildcardtag) conds of
  --             Just (cf, lf) -> (cf, lf)
  --             Nothing -> error $ "Missing constructor " <> show ci
  --     S.modify $ \s -> s { environment = VPair h v1
  --                        , stack = t
  --                        }
  --     goto label
  --   _ -> error "Non constructor patterns should be rewritten"
  --   where
  --     wildcardtag = "??WILDCARD??"


{-  HEAP growth and manipulation functions -}


-- goto doesn't store the previous jump
-- point into prevJump unlike jumpTo
goto :: Label -> Evaluate ()
goto l = do
  pc <- S.gets programCounter
  st <- S.gets symbolTable
  let ix = st ~> l
  S.modify $ \s -> s { programCounter = ix }


gotofalse :: Label -> Evaluate ()
gotofalse l = do
  e      <- getEnv
  (h, t) <- popAndRest
  case h of
    SV val ->
      S.modify $ \s -> s { environment = EV val
                         , stack = t
                         }
    SP ptr ->
      S.modify $ \s -> s { environment = EP ptr
                         , stack = t
                         }

  case e of
    EV (VBool True)  -> incPC
    EV (VBool False) -> goto l
    _ -> error "GOTOFALSE instuction applied to incorrect operand"

dummyLabel = Label (-1)

-- NOTE:
{-
1. Use the stack for intermediate storage of environment;
   Always PUSH before beginning computation
2. BinOp (s(2)) expects first argument on stack and second on register
-}
