{-|
Module: Squeal.PostgreSQL.Query
Description: Squeal expressions
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

Squeal expressions are the atoms used to build statements.
-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE
    AllowAmbiguousTypes
  , DataKinds
  , DeriveGeneric
  , DeriveDataTypeable
  , FlexibleContexts
  , FlexibleInstances
  , FunctionalDependencies
  , GADTs
  , GeneralizedNewtypeDeriving
  , LambdaCase
  , MagicHash
  , OverloadedStrings
  , PolyKinds
  , RankNTypes
  , ScopedTypeVariables
  , StandaloneDeriving
  , TypeApplications
  , TypeFamilies
  , TypeInType
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.Expression 
  ( -- * Expression
    Expression (UnsafeExpression, renderExpression)
  , HasParameter (param)
  , HasColumn (getColumn)
  , Column (Column)
  , renderColumn
  , GroupedBy (getGroup1, getGroup2)
    -- ** Default
  , def
  , unDef
    -- ** Null
  , null_
  , unNull
  , coalesce
  , fromNull
  , isNull
  , isn'tNull
  , matchNull
  , nullIf
  -- ** Functions
  , unsafeBinaryOp
  , unsafeUnaryOp
  , unsafeFunction
  , atan2_
  , cast
  , quot_
  , rem_
  , trunc
  , round_
  , ceiling_
  , greatest
  , least
    -- ** Conditions
  , Condition
  , true
  , false
  , not_
  , (.&&)
  , (.||)
  , caseWhenThenElse
  , ifThenElse
  , (.==)
  , (./=)
  , (.>=)
  , (.<)
  , (.<=)
  , (.>)
    -- ** Time
  , currentDate
  , currentTime
  , currentTimestamp
  , localTime
  , localTimestamp
    -- ** Text
  , lower
  , upper
  , charLength
  , like
    -- ** Aggregation
  , unsafeAggregate, unsafeAggregateDistinct
  , sum_, sumDistinct
  , PGAvg (avg, avgDistinct)
  , bitAnd, bitOr, boolAnd, boolOr
  , bitAndDistinct, bitOrDistinct, boolAndDistinct, boolOrDistinct
  , countStar
  , count, countDistinct
  , every, everyDistinct
  , max_, maxDistinct, min_, minDistinct
    -- * Tables
  , Table (UnsafeTable, renderTable)
  , HasTable (getTable)
    -- * TypeExpression
  , TypeExpression (UnsafeTypeExpression, renderTypeExpression)
  , PGTyped (pgtype)
  , bool
  , int2
  , smallint
  , int4
  , int
  , integer
  , int8
  , bigint
  , numeric
  , float4
  , real
  , float8
  , doublePrecision
  , serial2
  , smallserial
  , serial4
  , serial
  , serial8
  , bigserial
  , text
  , char
  , character
  , varchar
  , characterVarying
  , bytea
  , timestamp
  , timestampWithTimeZone
  , date
  , time
  , timeWithTimeZone
  , interval
  , uuid
  , inet
  , json
  , jsonb
  , notNull
  , default_
    -- * Re-export
  , (&)
  , NP ((:*), Nil)
  ) where

import Control.Category
import Control.DeepSeq
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.Monoid hiding (All)
import Data.Ratio
import Data.String
import Generics.SOP hiding (from)
import GHC.OverloadedLabels
import GHC.TypeLits
import Prelude hiding (id, (.))

import qualified GHC.Generics as GHC

import Squeal.PostgreSQL.Prettyprint
import Squeal.PostgreSQL.Schema

{-----------------------------------------
column expressions
-----------------------------------------}

{- | `Expression`s are used in a variety of contexts,
such as in the target list of the `select` command,
as new column values in `insertInto` or `update`,
or in search `Condition`s in a number of commands.

The expression syntax allows the calculation of
values from primitive expression using arithmetic, logical,
and other operations.
-}
newtype Expression
  (tables :: TablesType)
  (grouping :: Grouping)
  (params :: [ColumnType])
  (ty :: ColumnType)
    = UnsafeExpression { renderExpression :: ByteString }
    deriving (GHC.Generic,Show,Eq,Ord,NFData)

{- | A `HasParameter` constraint is used to indicate a value that is
supplied externally to a SQL statement.
`Squeal.PostgreSQL.PQ.manipulateParams`,
`Squeal.PostgreSQL.PQ.queryParams` and
`Squeal.PostgreSQL.PQ.traversePrepared` support specifying data values
separately from the SQL command string, in which case `param`s are used to
refer to the out-of-line data values.
-}
class (PGTyped (BaseType ty), KnownNat n)
  => HasParameter (n :: Nat) params ty | n params -> ty where
    param :: Expression tables grouping params ty
    param = UnsafeExpression $ parenthesized $
      "$" <> renderNat (Proxy @n) <+> "::"
        <+> renderTypeExpression (pgtype @(BaseType ty))
instance {-# OVERLAPPING #-} PGTyped (BaseType ty1)
  => HasParameter 1 (ty1:tys) ty1
instance {-# OVERLAPPABLE #-} (KnownNat n, HasParameter (n-1) params ty)
  => HasParameter n (ty' : params) ty

{- | A `HasColumn` constraint indicates an unqualified column reference.
`getColumn` can only be unambiguous when the `TableExpression` the column
references is unique, in which case the column may be referenced using
@-XOverloadedLabels@. Otherwise, combined with a `HasTable` constraint, the
qualified column reference operator `!` may be used.
-}
class KnownSymbol column => HasColumn column columns ty
  | column columns -> ty where
    getColumn
      :: HasUnique table tables columns
      => Alias column
      -> Expression tables 'Ungrouped params ty
    getColumn column = UnsafeExpression $ renderAlias column
instance {-# OVERLAPPING #-} KnownSymbol column
  => HasColumn column ((column ::: optionality ty) ': tys) ('Required ty)
instance {-# OVERLAPPABLE #-} (KnownSymbol column, HasColumn column table ty)
  => HasColumn column (ty' ': table) ty

instance (HasColumn column columns ty, HasUnique table tables columns)
  => IsLabel column (Expression tables 'Ungrouped params ty) where
    fromLabel = getColumn (Alias @column)

instance (HasTable table tables columns, HasColumn column columns ty)
  => IsTableColumn table column (Expression tables 'Ungrouped params ty) where
    table ! column = UnsafeExpression $
      renderAlias table <> "." <> renderAlias column

-- | A `Column` is a witness to a `HasColumn` constraint. It's used
-- in `Squeel.PostgreSQL.Definition.unique` and other
-- `Squeel.PostgreSQL.Definition.TableConstraint`s to witness a
-- subcolumns relationship.
data Column
  (columns :: ColumnsType)
  (columnty :: (Symbol,ColumnType))
    where
      Column
        :: HasColumn column columns ty
        => Alias column
        -> Column columns (column ::: ty)
deriving instance Show (Column columns columnty)
deriving instance Eq (Column columns columnty)
deriving instance Ord (Column columns columnty)

-- | Render a `Column`.
renderColumn :: Column columns columnty -> ByteString
renderColumn (Column column) = renderAlias column

{- | A `GroupedBy` constraint indicates that a table qualified column is
a member of the auxiliary namespace created by @GROUP BY@ clauses and thus,
may be called in an output `Expression` without aggregating.
-}
class (KnownSymbol table, KnownSymbol column)
  => GroupedBy table column bys where
    getGroup1
      :: (HasUnique table tables columns, HasColumn column columns ty)
      => Alias column
      -> Expression tables ('Grouped bys) params ty
    getGroup1 column = UnsafeExpression $ renderAlias column
    getGroup2
      :: (HasTable table tables columns, HasColumn column columns ty)
      => Alias table
      -> Alias column
      -> Expression tables ('Grouped bys) params ty
    getGroup2 table column = UnsafeExpression $
      renderAlias table <> "." <> renderAlias column
instance {-# OVERLAPPING #-} (KnownSymbol table, KnownSymbol column)
  => GroupedBy table column ('(table,column) ': bys)
instance {-# OVERLAPPABLE #-}
  ( KnownSymbol table
  , KnownSymbol column
  , GroupedBy table column bys
  ) => GroupedBy table column (tabcol ': bys)
  
instance
  ( HasUnique table tables columns
  , HasColumn column columns ty
  , GroupedBy table column bys
  ) => IsLabel column
    (Expression tables ('Grouped bys) params ty) where
      fromLabel = getGroup1 (Alias @column)
  
instance
  ( HasTable table tables columns
  , HasColumn column columns ty
  , GroupedBy table column bys
  ) => IsTableColumn table column
    (Expression tables ('Grouped bys) params ty) where (!) = getGroup2

-- | >>> renderExpression def
-- "DEFAULT"
def :: Expression '[] 'Ungrouped params ('Optional (nullity ty))
def = UnsafeExpression "DEFAULT"

-- | >>> renderExpression $ unDef false
-- "FALSE"
unDef
  :: Expression '[] 'Ungrouped params ('Required (nullity ty))
  -- ^ not @DEFAULT@
  -> Expression '[] 'Ungrouped params ('Optional (nullity ty))
unDef = UnsafeExpression . renderExpression

-- | analagous to `Nothing`
--
-- >>> renderExpression $ null_
-- "NULL"
null_ :: Expression tables grouping params (optionality ('Null ty))
null_ = UnsafeExpression "NULL"

-- | analagous to `Just`
--
-- >>> renderExpression $ unNull true
-- "TRUE"
unNull
  :: Expression tables grouping params (optionality ('NotNull ty))
  -- ^ not @NULL@
  -> Expression tables grouping params (optionality ('Null ty))
unNull = UnsafeExpression . renderExpression

-- | return the leftmost value which is not NULL
--
-- >>> renderExpression $ coalesce [null_, unNull true] false
-- "COALESCE(NULL, TRUE, FALSE)"
coalesce
  :: [Expression tables grouping params ('Required ('Null ty))]
  -- ^ @NULL@s may be present
  -> Expression tables grouping params ('Required ('NotNull ty))
  -- ^ @NULL@ is absent
  -> Expression tables grouping params ('Required ('NotNull ty))
coalesce nullxs notNullx = UnsafeExpression $
  "COALESCE" <> parenthesized (commaSeparated
    ((renderExpression <$> nullxs) <> [renderExpression notNullx]))

-- | analagous to `fromMaybe` using @COALESCE@
--
-- >>> renderExpression $ fromNull true null_
-- "COALESCE(NULL, TRUE)"
fromNull
  :: Expression tables grouping params ('Required ('NotNull ty))
  -- ^ what to convert @NULL@ to
  -> Expression tables grouping params ('Required ('Null ty))
  -> Expression tables grouping params ('Required ('NotNull ty))
fromNull notNullx nullx = coalesce [nullx] notNullx

-- | >>> renderExpression $ null_ & isNull
-- "NULL IS NULL"
isNull
  :: Expression tables grouping params ('Required ('Null ty))
  -- ^ possibly @NULL@
  -> Condition tables grouping params
isNull x = UnsafeExpression $ renderExpression x <+> "IS NULL"

-- | >>> renderExpression $ null_ & isn'tNull
-- "NULL IS NOT NULL"
isn'tNull
  :: Expression tables grouping params ('Required ('Null ty))
  -- ^ possibly @NULL@
  -> Condition tables grouping params
isn'tNull x = UnsafeExpression $ renderExpression x <+> "IS NOT NULL"

-- | analagous to `maybe` using @IS NULL@
--
-- >>> renderExpression $ matchNull true not_ null_
-- "CASE WHEN NULL IS NULL THEN TRUE ELSE (NOT NULL) END"
matchNull
  :: Expression tables grouping params ('Required nullty)
  -- ^ what to convert @NULL@ to
  -> ( Expression tables grouping params ('Required ('NotNull ty))
       -> Expression tables grouping params ('Required nullty) )
  -- ^ function to perform when @NULL@ is absent
  -> Expression tables grouping params ('Required ('Null ty))
  -> Expression tables grouping params ('Required nullty)
matchNull y f x = ifThenElse (isNull x) y
  (f (UnsafeExpression (renderExpression x)))

-- | right inverse to `fromNull`, if its arguments are equal then
-- `nullIf` gives @NULL@.
--
-- >>> :set -XTypeApplications -XDataKinds
-- >>> renderExpression @_ @_ @'[_] $ fromNull false (nullIf false (param @1))
-- "COALESCE(NULL IF (FALSE, ($1 :: bool)), FALSE)"
nullIf
  :: Expression tables grouping params ('Required ('NotNull ty))
  -- ^ @NULL@ is absent
  -> Expression tables grouping params ('Required ('NotNull ty))
  -- ^ @NULL@ is absent
  -> Expression tables grouping params ('Required ('Null ty))
nullIf x y = UnsafeExpression $ "NULL IF" <+> parenthesized
  (renderExpression x <> ", " <> renderExpression y)

-- | >>> renderExpression @_ @_ @'[_] $ greatest currentTimestamp [param @1]
-- "GREATEST(CURRENT_TIMESTAMP, ($1 :: timestamp with time zone))"
greatest
  :: Expression tables grouping params ('Required nullty)
  -- ^ needs at least 1 argument
  -> [Expression tables grouping params ('Required nullty)]
  -- ^ or more
  -> Expression tables grouping params ('Required nullty)
greatest x xs = UnsafeExpression $ "GREATEST("
  <> commaSeparated (renderExpression <$> (x:xs)) <> ")"

-- | >>> renderExpression $ least currentTimestamp [null_]
-- "LEAST(CURRENT_TIMESTAMP, NULL)"
least
  :: Expression tables grouping params ('Required nullty)
  -- ^ needs at least 1 argument
  -> [Expression tables grouping params ('Required nullty)]
  -- ^ or more
  -> Expression tables grouping params ('Required nullty)
least x xs = UnsafeExpression $ "LEAST("
  <> commaSeparated (renderExpression <$> (x:xs)) <> ")"

-- | >>> renderExpression $ unsafeBinaryOp "OR" true false
-- "(TRUE OR FALSE)"
unsafeBinaryOp
  :: ByteString
  -- ^ operator
  -> Expression tables grouping params ('Required ty0)
  -> Expression tables grouping params ('Required ty1)
  -> Expression tables grouping params ('Required ty2)
unsafeBinaryOp op x y = UnsafeExpression $ parenthesized $
  renderExpression x <+> op <+> renderExpression y

-- | >>> renderExpression $ unsafeUnaryOp "NOT" true
-- "(NOT TRUE)"
unsafeUnaryOp
  :: ByteString
  -- ^ operator
  -> Expression tables grouping params ('Required ty0)
  -> Expression tables grouping params ('Required ty1)
unsafeUnaryOp op x = UnsafeExpression $ parenthesized $
  op <+> renderExpression x

-- | >>> renderExpression $ unsafeFunction "f" true
-- "f(TRUE)"
unsafeFunction
  :: ByteString
  -- ^ function
  -> Expression tables grouping params ('Required xty)
  -> Expression tables grouping params ('Required yty)
unsafeFunction fun x = UnsafeExpression $
  fun <> parenthesized (renderExpression x)

instance PGNum ty
  => Num (Expression tables grouping params ('Required (nullity ty))) where
    (+) = unsafeBinaryOp "+"
    (-) = unsafeBinaryOp "-"
    (*) = unsafeBinaryOp "*"
    abs = unsafeFunction "abs"
    signum = unsafeFunction "sign"
    fromInteger
      = UnsafeExpression
      . fromString
      . show

instance (PGNum ty, PGFloating ty) => Fractional
  (Expression tables grouping params ('Required (nullity ty))) where
    (/) = unsafeBinaryOp "/"
    fromRational x = fromInteger (numerator x) / fromInteger (denominator x)

instance (PGNum ty, PGFloating ty) => Floating
  (Expression tables grouping params ('Required (nullity ty))) where
    pi = UnsafeExpression "pi()"
    exp = unsafeFunction "exp"
    log = unsafeFunction "ln"
    sqrt = unsafeFunction "sqrt"
    b ** x = UnsafeExpression $
      "power(" <> renderExpression b <> ", " <> renderExpression x <> ")"
    logBase b y = log y / log b
    sin = unsafeFunction "sin"
    cos = unsafeFunction "cos"
    tan = unsafeFunction "tan"
    asin = unsafeFunction "asin"
    acos = unsafeFunction "acos"
    atan = unsafeFunction "atan"
    sinh x = (exp x - exp (-x)) / 2
    cosh x = (exp x + exp (-x)) / 2
    tanh x = sinh x / cosh x
    asinh x = log (x + sqrt (x*x + 1))
    acosh x = log (x + sqrt (x*x - 1))
    atanh x = log ((1 + x) / (1 - x)) / 2

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGfloat4)) $ atan2_ pi 2
-- "atan2(pi(), 2)"
atan2_
  :: PGFloating float
  => Expression tables grouping params ('Required (nullity float))
  -- ^ numerator
  -> Expression tables grouping params ('Required (nullity float))
  -- ^ denominator
  -> Expression tables grouping params ('Required (nullity float))
atan2_ y x = UnsafeExpression $
  "atan2(" <> renderExpression y <> ", " <> renderExpression x <> ")"

-- When a `cast` is applied to an `Expression` of a known type, it
-- represents a run-time type conversion. The cast will succeed only if a
-- suitable type conversion operation has been defined.
--
-- | >>> renderExpression $ true & cast int4
-- "(TRUE :: int4)"
cast
  :: TypeExpression ('Required ('Null ty1))
  -- ^ type to cast as
  -> Expression tables grouping params ('Required (nullity ty0))
  -- ^ value to convert
  -> Expression tables grouping params ('Required (nullity ty1))
cast ty x = UnsafeExpression $ parenthesized $
  renderExpression x <+> "::" <+> renderTypeExpression ty

-- | integer division, truncates the result
--
-- >>> renderExpression @_ @_ @_ @(_(_ 'PGint2)) $ 5 `quot_` 2
-- "(5 / 2)"
quot_
  :: PGIntegral int
  => Expression tables grouping params ('Required (nullity int))
  -- ^ numerator
  -> Expression tables grouping params ('Required (nullity int))
  -- ^ denominator
  -> Expression tables grouping params ('Required (nullity int))
quot_ = unsafeBinaryOp "/"

-- | remainder upon integer division
--
-- >>> renderExpression @_ @_ @_ @(_ (_ 'PGint2)) $ 5 `rem_` 2
-- "(5 % 2)"
rem_
  :: PGIntegral int
  => Expression tables grouping params ('Required (nullity int))
  -- ^ numerator
  -> Expression tables grouping params ('Required (nullity int))
  -- ^ denominator
  -> Expression tables grouping params ('Required (nullity int))
rem_ = unsafeBinaryOp "%"

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGfloat4)) $ trunc pi
-- "trunc(pi())"
trunc
  :: PGFloating frac
  => Expression tables grouping params ('Required (nullity frac))
  -- ^ fractional number
  -> Expression tables grouping params ('Required (nullity frac))
trunc = unsafeFunction "trunc"

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGfloat4)) $ round_ pi
-- "round(pi())"
round_
  :: PGFloating frac
  => Expression tables grouping params ('Required (nullity frac))
  -- ^ fractional number
  -> Expression tables grouping params ('Required (nullity frac))
round_ = unsafeFunction "round"

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGfloat4)) $ ceiling_ pi
-- "ceiling(pi())"
ceiling_
  :: PGFloating frac
  => Expression tables grouping params ('Required (nullity frac))
  -- ^ fractional number
  -> Expression tables grouping params ('Required (nullity frac))
ceiling_ = unsafeFunction "ceiling"

-- | A `Condition` is a boolean valued `Expression`. While SQL allows
-- conditions to have @NULL@, squeal instead chooses to disallow @NULL@,
-- forcing one to handle the case of @NULL@ explicitly to produce
-- a `Condition`.
type Condition tables grouping params =
  Expression tables grouping params ('Required ('NotNull 'PGbool))

-- | >>> renderExpression true
-- "TRUE"
true :: Condition tables grouping params
true = UnsafeExpression "TRUE"

-- | >>> renderExpression false
-- "FALSE"
false :: Condition tables grouping params
false = UnsafeExpression "FALSE"

-- | >>> renderExpression $ not_ true
-- "(NOT TRUE)"
not_
  :: Condition tables grouping params
  -> Condition tables grouping params
not_ = unsafeUnaryOp "NOT"

-- | >>> renderExpression $ true .&& false
-- "(TRUE AND FALSE)"
(.&&)
  :: Condition tables grouping params
  -> Condition tables grouping params
  -> Condition tables grouping params
(.&&) = unsafeBinaryOp "AND"

-- | >>> renderExpression $ true .|| false
-- "(TRUE OR FALSE)"
(.||)
  :: Condition tables grouping params
  -> Condition tables grouping params
  -> Condition tables grouping params
(.||) = unsafeBinaryOp "OR"

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGint2)) $ caseWhenThenElse [(true, 1), (false, 2)] 3
-- "CASE WHEN TRUE THEN 1 WHEN FALSE THEN 2 ELSE 3 END"
caseWhenThenElse
  :: [ ( Condition tables grouping params
       , Expression tables grouping params ('Required ty)
     ) ]
  -> Expression tables grouping params ('Required ty)
  -> Expression tables grouping params ('Required ty)
caseWhenThenElse whenThens else_ = UnsafeExpression $ mconcat
  [ "CASE"
  , mconcat
    [ mconcat
      [ " WHEN ", renderExpression when_
      , " THEN ", renderExpression then_
      ]
    | (when_,then_) <- whenThens
    ]
  , " ELSE ", renderExpression else_
  , " END"
  ]

-- | >>> renderExpression @_ @_ @_ @(_ (_ 'PGint2)) $ ifThenElse true 1 0
-- "CASE WHEN TRUE THEN 1 ELSE 0 END"
ifThenElse
  :: Condition tables grouping params
  -> Expression tables grouping params ('Required ty)
  -> Expression tables grouping params ('Required ty)
  -> Expression tables grouping params ('Required ty)
ifThenElse if_ then_ else_ = caseWhenThenElse [(if_,then_)] else_

-- | Comparison operations like `.==`, `./=`, `.>`, `.>=`, `.<` and `.<=`
-- will produce @NULL@s if one of their arguments is @NULL@.
--
-- >>> renderExpression $ unNull true .== null_
-- "(TRUE = NULL)"
(.==)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(.==) = unsafeBinaryOp "="
infix 4 .==

-- | >>> renderExpression $ unNull true ./= null_
-- "(TRUE <> NULL)"
(./=)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(./=) = unsafeBinaryOp "<>"
infix 4 ./=

-- | >>> renderExpression $ unNull true .>= null_
-- "(TRUE >= NULL)"
(.>=)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(.>=) = unsafeBinaryOp ">="
infix 4 .>=

-- | >>> renderExpression $ unNull true .< null_
-- "(TRUE < NULL)"
(.<)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(.<) = unsafeBinaryOp "<"
infix 4 .<

-- | >>> renderExpression $ unNull true .<= null_
-- "(TRUE <= NULL)"
(.<=)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(.<=) = unsafeBinaryOp "<="
infix 4 .<=

-- | >>> renderExpression $ unNull true .> null_
-- "(TRUE > NULL)"
(.>)
  :: Expression tables grouping params ('Required (nullity ty)) -- ^ lhs
  -> Expression tables grouping params ('Required (nullity ty)) -- ^ rhs
  -> Expression tables grouping params ('Required (nullity 'PGbool))
(.>) = unsafeBinaryOp ">"
infix 4 .>

-- | >>> renderExpression $ currentDate
-- "CURRENT_DATE"
currentDate
  :: Expression tables grouping params ('Required (nullity 'PGdate))
currentDate = UnsafeExpression "CURRENT_DATE"

-- | >>> renderExpression $ currentTime
-- "CURRENT_TIME"
currentTime
  :: Expression tables grouping params ('Required (nullity 'PGtimetz))
currentTime = UnsafeExpression "CURRENT_TIME"

-- | >>> renderExpression $ currentTimestamp
-- "CURRENT_TIMESTAMP"
currentTimestamp
  :: Expression tables grouping params ('Required (nullity 'PGtimestamptz))
currentTimestamp = UnsafeExpression "CURRENT_TIMESTAMP"

-- | >>> renderExpression $ localTime
-- "LOCALTIME"
localTime
  :: Expression tables grouping params ('Required (nullity 'PGtime))
localTime = UnsafeExpression "LOCALTIME"

-- | >>> renderExpression $ localTimestamp
-- "LOCALTIMESTAMP"
localTimestamp
  :: Expression tables grouping params ('Required (nullity 'PGtimestamp))
localTimestamp = UnsafeExpression "LOCALTIMESTAMP"

{-----------------------------------------
text
-----------------------------------------}

instance IsString
  (Expression tables grouping params ('Required (nullity 'PGtext))) where
    fromString str = UnsafeExpression $
      "E\'" <> fromString (escape =<< str) <> "\'"
      where
        escape = \case
          '\NUL' -> "\\0"
          '\'' -> "''"
          '"' -> "\\\""
          '\b' -> "\\b"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          '\\' -> "\\\\"
          c -> [c]

instance Monoid
  (Expression tables grouping params ('Required (nullity 'PGtext))) where
    mempty = fromString ""
    mappend = unsafeBinaryOp "||"

-- | >>> renderExpression $ lower "ARRRGGG"
-- "lower(E'ARRRGGG')"
lower
  :: Expression tables grouping params ('Required (nullity 'PGtext))
  -- ^ string to lower case
  -> Expression tables grouping params ('Required (nullity 'PGtext))
lower = unsafeFunction "lower"

-- | >>> renderExpression $ upper "eeee"
-- "upper(E'eeee')"
upper
  :: Expression tables grouping params ('Required (nullity 'PGtext))
  -- ^ string to upper case
  -> Expression tables grouping params ('Required (nullity 'PGtext))
upper = unsafeFunction "upper"

-- | >>> renderExpression $ charLength "four"
-- "char_length(E'four')"
charLength
  :: Expression tables grouping params ('Required (nullity 'PGtext))
  -- ^ string to measure
  -> Expression tables grouping params ('Required (nullity 'PGint4))
charLength = unsafeFunction "char_length"

-- | The `like` expression returns true if the @string@ matches
-- the supplied @pattern@. If @pattern@ does not contain percent signs
-- or underscores, then the pattern only represents the string itself;
-- in that case `like` acts like the equals operator. An underscore (_)
-- in pattern stands for (matches) any single character; a percent sign (%)
-- matches any sequence of zero or more characters.
--
-- >>> renderExpression $ "abc" `like` "a%"
-- "(E'abc' LIKE E'a%')"
like
  :: Expression tables grouping params ('Required (nullity 'PGtext))
  -- ^ string
  -> Expression tables grouping params ('Required (nullity 'PGtext))
  -- ^ pattern
  -> Expression tables grouping params ('Required (nullity 'PGbool))
like = unsafeBinaryOp "LIKE"

{-----------------------------------------
aggregation
-----------------------------------------}

-- | escape hatch to define aggregate functions
unsafeAggregate
  :: ByteString -- ^ aggregate function
  -> Expression tables 'Ungrouped params ('Required xty)
  -> Expression tables ('Grouped bys) params ('Required yty)
unsafeAggregate fun x = UnsafeExpression $ mconcat
  [fun, "(", renderExpression x, ")"]

-- | escape hatch to define aggregate functions over distinct values
unsafeAggregateDistinct
  :: ByteString -- ^ aggregate function
  -> Expression tables 'Ungrouped params ('Required xty)
  -> Expression tables ('Grouped bys) params ('Required yty)
unsafeAggregateDistinct fun x = UnsafeExpression $ mconcat
  [fun, "(DISTINCT ", renderExpression x, ")"]

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGnumeric)]] $ sum_ #col
-- "sum(col)"
sum_
  :: PGNum ty
  => Expression tables 'Ungrouped params ('Required (nullity ty))
  -- ^ what to sum
  -> Expression tables ('Grouped bys) params ('Required (nullity ty))
sum_ = unsafeAggregate "sum"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGnumeric)]] $ sumDistinct #col
-- "sum(DISTINCT col)"
sumDistinct
  :: PGNum ty
  => Expression tables 'Ungrouped params ('Required (nullity ty))
  -- ^ what to sum
  -> Expression tables ('Grouped bys) params ('Required (nullity ty))
sumDistinct = unsafeAggregateDistinct "sum"

-- | A constraint for `PGType`s that you can take averages of and the resulting
-- `PGType`.
class PGAvg ty avg | ty -> avg where
  avg, avgDistinct
    :: Expression tables 'Ungrouped params ('Required (nullity ty))
    -- ^ what to average
    -> Expression tables ('Grouped bys) params ('Required (nullity avg))
  avg = unsafeAggregate "avg"
  avgDistinct = unsafeAggregateDistinct "avg"
instance PGAvg 'PGint2 'PGnumeric
instance PGAvg 'PGint4 'PGnumeric
instance PGAvg 'PGint8 'PGnumeric
instance PGAvg 'PGnumeric 'PGnumeric
instance PGAvg 'PGfloat4 'PGfloat8
instance PGAvg 'PGfloat8 'PGfloat8
instance PGAvg 'PGinterval 'PGinterval

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGint4)]] $ bitAnd #col
-- "bit_and(col)"
bitAnd
  :: PGIntegral int
  => Expression tables 'Ungrouped params ('Required (nullity int))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity int))
bitAnd = unsafeAggregate "bit_and"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGint4)]] $ bitOr #col
-- "bit_or(col)"
bitOr
  :: PGIntegral int
  => Expression tables 'Ungrouped params ('Required (nullity int))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity int))
bitOr = unsafeAggregate "bit_or"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGint4)]] $ bitAndDistinct #col
-- "bit_and(DISTINCT col)"
bitAndDistinct
  :: PGIntegral int
  => Expression tables 'Ungrouped params ('Required (nullity int))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity int))
bitAndDistinct = unsafeAggregateDistinct "bit_and"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGint4)]] $ bitOrDistinct #col
-- "bit_or(DISTINCT col)"
bitOrDistinct
  :: PGIntegral int
  => Expression tables 'Ungrouped params ('Required (nullity int))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity int))
bitOrDistinct = unsafeAggregateDistinct "bit_or"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ boolAnd #col
-- "bool_and(col)"
boolAnd
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
boolAnd = unsafeAggregate "bool_and"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ boolOr #col
-- "bool_or(col)"
boolOr
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
boolOr = unsafeAggregate "bool_or"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ boolAndDistinct #col
-- "bool_and(DISTINCT col)"
boolAndDistinct
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
boolAndDistinct = unsafeAggregateDistinct "bool_and"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ boolOrDistinct #col
-- "bool_or(DISTINCT col)"
boolOrDistinct
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
boolOrDistinct = unsafeAggregateDistinct "bool_or"

-- | A special aggregation that does not require an input
--
-- >>> renderExpression countStar
-- "count(*)"
countStar
  :: Expression tables ('Grouped bys) params ('Required ('NotNull 'PGint8))
countStar = UnsafeExpression $ "count(*)"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Optional _]] $ count #col
-- "count(col)"
count
  :: Expression tables 'Ungrouped params ('Required ty)
  -- ^ what to count
  -> Expression tables ('Grouped bys) params ('Required ('NotNull 'PGint8))
count = unsafeAggregate "count"

-- | >>> renderExpression @'[_ ::: '["col" ::: 'Required _]] $ countDistinct #col
-- "count(DISTINCT col)"
countDistinct
  :: Expression tables 'Ungrouped params ('Required ty)
  -- ^ what to count
  -> Expression tables ('Grouped bys) params ('Required ('NotNull 'PGint8))
countDistinct = unsafeAggregateDistinct "count"

-- | synonym for `boolAnd`
--
-- >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ every #col
-- "every(col)"
every
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
every = unsafeAggregate "every"

-- | synonym for `boolAndDistinct`
--
-- >>> renderExpression @'[_ ::: '["col" ::: 'Required (_ 'PGbool)]] $ everyDistinct #col
-- "every(DISTINCT col)"
everyDistinct
  :: Expression tables 'Ungrouped params ('Required (nullity 'PGbool))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity 'PGbool))
everyDistinct = unsafeAggregateDistinct "every"

-- | minimum and maximum aggregation
max_, min_, maxDistinct, minDistinct
  :: Expression tables 'Ungrouped params ('Required (nullity ty))
  -- ^ what to aggregate
  -> Expression tables ('Grouped bys) params ('Required (nullity ty))
max_ = unsafeAggregate "max"
min_ = unsafeAggregate "min"
maxDistinct = unsafeAggregateDistinct "max"
minDistinct = unsafeAggregateDistinct "min"

{-----------------------------------------
tables
-----------------------------------------}

-- | A `Table` from a schema without its alias with an `IsLabel` instance
-- to call a table reference by its alias.
newtype Table
  (schema :: TablesType)
  (columns :: ColumnsType)
    = UnsafeTable { renderTable :: ByteString }
    deriving (GHC.Generic,Show,Eq,Ord,NFData)

-- | A `HasTable` constraint indicates a table reference.
class KnownSymbol table => HasTable table tables columns
  | table tables -> columns where
    getTable :: Alias table -> Table tables columns
    getTable table = UnsafeTable $ renderAlias table
instance {-# OVERLAPPING #-} KnownSymbol table
  => HasTable table ((table ::: columns) ': tables) columns
instance {-# OVERLAPPABLE #-}
  (KnownSymbol table, HasTable table schema columns)
    => HasTable table (table' ': schema) columns

instance HasTable table schema columns
  => IsLabel table (Table schema columns) where
    fromLabel = getTable (Alias @table)

{-----------------------------------------
type expressions
-----------------------------------------}

-- | `TypeExpression`s are used in `cast`s and `createTable` commands.
newtype TypeExpression (ty :: ColumnType)
  = UnsafeTypeExpression { renderTypeExpression :: ByteString }
  deriving (GHC.Generic,Show,Eq,Ord,NFData)

-- | logical Boolean (true/false)
bool :: TypeExpression ('Required ('Null 'PGbool))
bool = UnsafeTypeExpression "bool"
-- | signed two-byte integer
int2, smallint :: TypeExpression ('Required ('Null 'PGint2))
int2 = UnsafeTypeExpression "int2"
smallint = UnsafeTypeExpression "smallint"
-- | signed four-byte integer
int4, int, integer :: TypeExpression ('Required ('Null 'PGint4))
int4 = UnsafeTypeExpression "int4"
int = UnsafeTypeExpression "int"
integer = UnsafeTypeExpression "integer"
-- | signed eight-byte integer
int8, bigint :: TypeExpression ('Required ('Null 'PGint8))
int8 = UnsafeTypeExpression "int8"
bigint = UnsafeTypeExpression "bigint"
-- | arbitrary precision numeric type
numeric :: TypeExpression ('Required ('Null 'PGnumeric))
numeric = UnsafeTypeExpression "numeric"
-- | single precision floating-point number (4 bytes)
float4, real :: TypeExpression ('Required ('Null 'PGfloat4))
float4 = UnsafeTypeExpression "float4"
real = UnsafeTypeExpression "real"
-- | double precision floating-point number (8 bytes)
float8, doublePrecision :: TypeExpression ('Required ('Null 'PGfloat8))
float8 = UnsafeTypeExpression "float8"
doublePrecision = UnsafeTypeExpression "double precision"
-- | not a true type, but merely a notational convenience for creating
-- unique identifier columns with type `'PGint2`
serial2, smallserial :: TypeExpression ('Optional ('NotNull 'PGint2))
serial2 = UnsafeTypeExpression "serial2"
smallserial = UnsafeTypeExpression "smallserial"
-- | not a true type, but merely a notational convenience for creating
-- unique identifier columns with type `'PGint4`
serial4, serial :: TypeExpression ('Optional ('NotNull 'PGint4))
serial4 = UnsafeTypeExpression "serial4"
serial = UnsafeTypeExpression "serial"
-- | not a true type, but merely a notational convenience for creating
-- unique identifier columns with type `'PGint8`
serial8, bigserial :: TypeExpression ('Optional ('NotNull 'PGint8))
serial8 = UnsafeTypeExpression "serial8"
bigserial = UnsafeTypeExpression "bigserial"
-- | variable-length character string
text :: TypeExpression ('Required ('Null 'PGtext))
text = UnsafeTypeExpression "text"
-- | fixed-length character string
char, character
  :: (KnownNat n, 1 <= n)
  => proxy n
  -> TypeExpression ('Required ('Null ('PGchar n)))
char p = UnsafeTypeExpression $ "char(" <> renderNat p <> ")"
character p = UnsafeTypeExpression $  "character(" <> renderNat p <> ")"
-- | variable-length character string
varchar, characterVarying
  :: (KnownNat n, 1 <= n)
  => proxy n
  -> TypeExpression ('Required ('Null ('PGvarchar n)))
varchar p = UnsafeTypeExpression $ "varchar(" <> renderNat p <> ")"
characterVarying p = UnsafeTypeExpression $
  "character varying(" <> renderNat p <> ")"
-- | binary data ("byte array")
bytea :: TypeExpression ('Required ('Null 'PGbytea))
bytea = UnsafeTypeExpression "bytea"
-- | date and time (no time zone)
timestamp :: TypeExpression ('Required ('Null 'PGtimestamp))
timestamp = UnsafeTypeExpression "timestamp"
-- | date and time, including time zone
timestampWithTimeZone :: TypeExpression ('Required ('Null 'PGtimestamptz))
timestampWithTimeZone = UnsafeTypeExpression "timestamp with time zone"
-- | calendar date (year, month, day)
date :: TypeExpression ('Required ('Null 'PGdate))
date = UnsafeTypeExpression "date"
-- | time of day (no time zone)
time :: TypeExpression ('Required ('Null 'PGtime))
time = UnsafeTypeExpression "time"
-- | time of day, including time zone
timeWithTimeZone :: TypeExpression ('Required ('Null 'PGtimetz))
timeWithTimeZone = UnsafeTypeExpression "time with time zone"
-- | time span
interval :: TypeExpression ('Required ('Null 'PGinterval))
interval = UnsafeTypeExpression "interval"
-- | universally unique identifier
uuid :: TypeExpression ('Required ('Null 'PGuuid))
uuid = UnsafeTypeExpression "uuid"
-- | IPv4 or IPv6 host address
inet :: TypeExpression ('Required ('Null 'PGinet))
inet = UnsafeTypeExpression "inet"
-- | textual JSON data
json :: TypeExpression ('Required ('Null 'PGjson))
json = UnsafeTypeExpression "json"
-- | binary JSON data, decomposed
jsonb :: TypeExpression ('Required ('Null 'PGjsonb))
jsonb = UnsafeTypeExpression "jsonb"

-- | used in `createTable` commands as a column constraint to ensure
-- @NULL@ is not present
notNull
  :: TypeExpression (optionality ('Null ty))
  -> TypeExpression (optionality ('NotNull ty))
notNull ty = UnsafeTypeExpression $ renderTypeExpression ty <+> "NOT NULL"

-- | used in `createTable` commands as a column constraint to give a default
default_
  :: Expression '[] 'Ungrouped '[] ('Required ty)
  -> TypeExpression ('Required ty)
  -> TypeExpression ('Optional ty)
default_ x ty = UnsafeTypeExpression $
  renderTypeExpression ty <+> "DEFAULT" <+> renderExpression x

-- | `pgtype` is a demoted version of a `PGType`
class PGTyped (ty :: PGType) where
  pgtype :: TypeExpression ('Required ('Null ty))
instance PGTyped 'PGbool where pgtype = bool
instance PGTyped 'PGint2 where pgtype = int2
instance PGTyped 'PGint4 where pgtype = int4
instance PGTyped 'PGint8 where pgtype = int8
instance PGTyped 'PGnumeric where pgtype = numeric
instance PGTyped 'PGfloat4 where pgtype = float4
instance PGTyped 'PGfloat8 where pgtype = float8
instance PGTyped 'PGtext where pgtype = text
instance (KnownNat n, 1 <= n)
  => PGTyped ('PGchar n) where pgtype = char (Proxy @n)
instance (KnownNat n, 1 <= n)
  => PGTyped ('PGvarchar n) where pgtype = varchar (Proxy @n)
instance PGTyped 'PGbytea where pgtype = bytea
instance PGTyped 'PGtimestamp where pgtype = timestamp
instance PGTyped 'PGtimestamptz where pgtype = timestampWithTimeZone
instance PGTyped 'PGdate where pgtype = date
instance PGTyped 'PGtime where pgtype = time
instance PGTyped 'PGtimetz where pgtype = timeWithTimeZone
instance PGTyped 'PGinterval where pgtype = interval
instance PGTyped 'PGuuid where pgtype = uuid
instance PGTyped 'PGjson where pgtype = json
instance PGTyped 'PGjsonb where pgtype = jsonb
