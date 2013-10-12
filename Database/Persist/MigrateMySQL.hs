{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
-- | A MySQL backend for @persistent@.
module Database.Persist.MigrateMySQL
    ( getMigrationStrategy 
    ) where

import Control.Arrow
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Error (ErrorT(..))
import Data.ByteString (ByteString)
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.List (find, intercalate, sort, groupBy)
import Data.Text (Text, pack)
import Data.Monoid ((<>))

import Data.Conduit
import qualified Data.Conduit.List as CL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Database.Persist.Sql
import Database.Persist.ODBCTypes
import Debug.Trace

getMigrationStrategy :: DBType -> MigrationStrategy
getMigrationStrategy dbtype@MySQL {} = 
     MigrationStrategy
                          { dbmsLimitOffset=decorateSQLWithLimitOffset "LIMIT 18446744073709551615" 
                           ,dbmsMigrate=migrate'
                           ,dbmsInsertSql=insertSql'
                           ,dbmsEscape=T.pack . escapeDBName 
                           ,dbmsType=dbtype
                          }
getMigrationStrategy dbtype = error $ "MySQL: calling with invalid dbtype " ++ show dbtype

-- | Create the migration plan for the given 'PersistEntity'
-- @val@.
migrate' :: Show a
         => [EntityDef a]
         -> (Text -> IO Statement)
         -> EntityDef SqlType
         -> IO (Either [Text] [(Bool, Text)])
migrate' allDefs getter val = do
    let name = entityDB val
    (idClmn, old) <- getColumns getter val
    let new = second (map udToPair) $ mkColumns allDefs val
    case (idClmn, old, partitionEithers old) of
      -- Nothing found, create everything
      ([], [], _) -> do
        let idtxt = case "noid" `elem` entityAttrs val of
                      True  -> trace ("found it!!! val=" ++ show val) []
                      False -> trace ("not found val=" ++ show val) $
                                 concat [escapeDBName $ entityID val
                            , " BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"]
        let addTable = AddTable $ concat
                            -- Lower case e: see Database.Persist.Sql.Migration
                [ "CREATE TABLe "
                , escapeDBName name
                , "("
                , idtxt
                , if null (fst new) || null (idtxt) then [] else ","
                , intercalate "," $ map (\x -> showColumn x) $ fst new
                , ")"
                ]
        let uniques = flip concatMap (snd new) $ \(uname, ucols) ->
                      [ AlterTable name $
                        AddUniqueConstraint uname $
                        map (findTypeOfColumn allDefs name) ucols ]
        let foreigns = do
              Column cname _ _ _ _ _ (Just (refTblName, _)) <- fst new
              return $ AlterColumn name (cname, addReference allDefs refTblName)
        return $ Right $ map showAlterDb $ addTable : uniques ++ foreigns
      -- No errors and something found, migrate
      (_, _, ([], old')) -> do
        let (acs, ats) = getAlters allDefs name new $ partitionEithers old'
            acs' = map (AlterColumn name) acs
            ats' = map (AlterTable  name) ats
        return $ Right $ map showAlterDb $ acs' ++ ats'
      -- Errors
      (_, _, (errs, _)) -> return $ Left errs


-- | Find out the type of a column.
findTypeOfColumn :: Show a => [EntityDef a] -> DBName -> DBName -> (DBName, FieldType)
findTypeOfColumn allDefs name col =
    maybe (error $ "Could not find type of column " ++
                   show col ++ " on table " ++ show name ++
                   " (allDefs = " ++ show allDefs ++ ")")
          ((,) col) $ do
            entDef   <- find ((== name) . entityDB) allDefs
            fieldDef <- find ((== col)  . fieldDB) (entityFields entDef)
            return (fieldType fieldDef)


-- | Helper for 'AddRefence' that finds out the 'entityID'.
addReference :: Show a => [EntityDef a] -> DBName -> AlterColumn
addReference allDefs name = AddReference name id_
    where
      id_ = maybe (error $ "Could not find ID of entity " ++ show name
                         ++ " (allDefs = " ++ show allDefs ++ ")")
                  id $ do
                    entDef <- find ((== name) . entityDB) allDefs
                    return (entityID entDef)

data AlterColumn = Change Column
                 | Add' Column
                 | Drop
                 | Default String
                 | NoDefault
                 | Update' String
                 | AddReference DBName DBName
                 | DropReference DBName

type AlterColumn' = (DBName, AlterColumn)

data AlterTable = AddUniqueConstraint DBName [(DBName, FieldType)]
                | DropUniqueConstraint DBName

data AlterDB = AddTable String
             | AlterColumn DBName AlterColumn'
             | AlterTable DBName AlterTable


udToPair :: UniqueDef -> (DBName, [DBName])
udToPair ud = (uniqueDBName ud, map snd $ uniqueFields ud)


----------------------------------------------------------------------


-- | Returns all of the 'Column'@s@ in the given table currently
-- in the database.
getColumns :: (Text -> IO Statement)
           -> EntityDef a
           -> IO ( [Either Text (Either Column (DBName, [DBName]))] -- ID column
                 , [Either Text (Either Column (DBName, [DBName]))] -- everything else
                 )
getColumns getter def = do
    -- Find out ID column.
    -- gb removed \WHERE TABLE_SCHEMA = ? \
    stmtIdClmn <- getter "SELECT COLUMN_NAME, \
                                 \IS_NULLABLE, \
                                 \DATA_TYPE, \
                                 \COLUMN_DEFAULT \
                          \FROM INFORMATION_SCHEMA.COLUMNS \
                        \WHERE  table_schema=schema() \
                        \AND TABLE_NAME   = ? \
                            \AND COLUMN_NAME  = ?"
    inter1 <- runResourceT $ stmtQuery stmtIdClmn vals $$ CL.consume
    ids <- runResourceT $ CL.sourceList inter1 $$ helperClmns -- avoid nested queries

    -- Find out all columns.
    -- gb remove \WHERE TABLE_SCHEMA = ? \
    stmtClmns <- getter "SELECT COLUMN_NAME, \
                               \IS_NULLABLE, \
                               \DATA_TYPE, \
                               \COLUMN_DEFAULT \
                        \FROM INFORMATION_SCHEMA.COLUMNS \
                        \WHERE  table_schema=schema() \
                        \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ?"
    inter2 <- runResourceT $ stmtQuery stmtClmns vals $$ CL.consume
    cs <- runResourceT $ CL.sourceList inter2 $$ helperClmns -- avoid nested queries

    -- Find out the constraints.
    stmtCntrs <- getter "SELECT CONSTRAINT_NAME, \
                               \COLUMN_NAME \
                        \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                        \WHERE  table_schema=schema() \
                        \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ? \
                          \AND REFERENCED_TABLE_SCHEMA IS NULL \
                        \ORDER BY CONSTRAINT_NAME, \
                                 \COLUMN_NAME"
    us <- runResourceT $ stmtQuery stmtCntrs vals $$ helperCntrs

    -- Return both
    return (ids, cs ++ us)
  where
    vals = [ PersistText $ unDBName $ entityDB def
           , PersistText $ unDBName $ entityID def ]

    helperClmns = CL.mapM getIt =$ CL.consume
        where
          getIt = fmap (either Left (Right . Left)) .
                  liftIO .
                  getColumn getter (entityDB def)

    helperCntrs = do
      let check [ PersistByteString cntrName
                , PersistByteString clmnName] = return ( T.decodeUtf8 cntrName
                                                       , T.decodeUtf8 clmnName )
          check other = fail $ "helperCntrs: unexpected " ++ show other
      rows <- mapM check =<< CL.consume
      return $ map (Right . Right . (DBName . fst . head &&& map (DBName . snd)))
             $ groupBy ((==) `on` fst) rows


-- | Get the information about a column in a table.
getColumn :: (Text -> IO Statement)
          -> DBName
          -> [PersistValue]
          -> IO (Either Text Column)
getColumn getter tname [ PersistByteString cname
                                   , PersistByteString null_
                                   , PersistByteString type'
                                   , default'] =
    fmap (either (Left . pack) Right) $
    runErrorT $ do
      -- Default value
      default_ <- case default' of
                    PersistNull   -> return Nothing
                    PersistText t -> return (Just t)
                    PersistByteString bs ->
                      case T.decodeUtf8' bs of
                        Left exc -> fail $ "Invalid default column: " ++
                                           show default' ++ " (error: " ++
                                           show exc ++ ")"
                        Right t  -> return (Just t)
                    _ -> fail $ "Invalid default column: " ++ show default'

      -- Column type
      type_ <- parseType type'

      -- Foreign key (if any)
      stmt <- lift $ getter "SELECT REFERENCED_TABLE_NAME, \
                                   \CONSTRAINT_NAME \
                            \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                        \WHERE  table_schema=schema() \
                        \AND TABLE_NAME   = ? \
                              \AND COLUMN_NAME  = ? \
                              \and REFERENCED_TABLE_SCHEMA=schema() \
                            \ORDER BY CONSTRAINT_NAME, \
                                     \COLUMN_NAME"
      let vars = [ PersistText $ unDBName tname
                 , PersistByteString cname
                 ]
      cntrs <- runResourceT $ stmtQuery stmt vars $$ CL.consume
      ref <- case cntrs of
               [] -> return Nothing
               [[PersistByteString tab, PersistByteString ref]] ->
                   return $ Just (DBName $ T.decodeUtf8 tab, DBName $ T.decodeUtf8 ref)
               a1 -> fail $ "MySQL.getColumn/getRef: never here error[" ++ show a1 ++ "]"

      -- Okay!
      return Column
        { cName = DBName $ T.decodeUtf8 cname
        , cNull = null_ == "YES"
        , cSqlType = type_
        , cDefault = default_
        , cDefaultConstraintName = Nothing
        , cMaxLen = Nothing -- FIXME: maxLen
        , cReference = ref
        }

getColumn _ _ x =
    return $ Left $ pack $ "Invalid result from INFORMATION_SCHEMA: " ++ show x


-- | Parse the type of column as returned by MySQL's
-- @INFORMATION_SCHEMA@ tables.
parseType :: Monad m => ByteString -> m SqlType
parseType "tinyint"    = return SqlBool
-- Ints
parseType "int"        = return SqlInt32
parseType "short"      = return SqlInt32
parseType "long"       = return SqlInt64
parseType "longlong"   = return SqlInt64
parseType "mediumint"  = return SqlInt32
parseType "bigint"     = return SqlInt64
-- Double
parseType "float"      = return SqlReal
parseType "double"     = return SqlReal
parseType "decimal"    = return SqlReal
parseType "newdecimal" = return SqlReal
-- Text
parseType "varchar"    = return SqlString
parseType "varstring"  = return SqlString
parseType "string"     = return SqlString
parseType "text"       = return SqlString
parseType "tinytext"   = return SqlString
parseType "mediumtext" = return SqlString
parseType "longtext"   = return SqlString
-- ByteString
parseType "varbinary"  = return SqlBlob
parseType "blob"       = return SqlBlob
parseType "tinyblob"   = return SqlBlob
parseType "mediumblob" = return SqlBlob
parseType "longblob"   = return SqlBlob
-- Time-related
parseType "time"       = return SqlTime
parseType "datetime"   = return SqlDayTime
parseType "timestamp"  = return SqlDayTime
parseType "date"       = return SqlDay
parseType "newdate"    = return SqlDay
parseType "year"       = return SqlDay
-- Other
parseType b            = error $ "no idea how to handle this type b=" ++ show b -- return $ SqlOther $ T.decodeUtf8 b


----------------------------------------------------------------------


-- | @getAlters allDefs tblName new old@ finds out what needs to
-- be changed from @old@ to become @new@.
getAlters :: Show a
          => [EntityDef a]
          -> DBName
          -> ([Column], [(DBName, [DBName])])
          -> ([Column], [(DBName, [DBName])])
          -> ([AlterColumn'], [AlterTable])
getAlters allDefs tblName (c1, u1) (c2, u2) =
    (getAltersC c1 c2, getAltersU u1 u2)
  where
    getAltersC [] old = concatMap dropColumn old
    getAltersC (new:news) old =
        let (alters, old') = findAlters allDefs new old
         in alters ++ getAltersC news old'

    dropColumn col =
      map ((,) (cName col)) $
        [DropReference n | Just (_, n) <- [cReference col]] ++
        [Drop]

    getAltersU [] old = map (DropUniqueConstraint . fst) old
    getAltersU ((name, cols):news) old =
        case lookup name old of
            Nothing ->
                AddUniqueConstraint name (map findType cols) : getAltersU news old
            Just ocols ->
                let old' = filter (\(x, _) -> x /= name) old
                 in if sort cols == ocols
                        then getAltersU news old'
                        else  DropUniqueConstraint name
                            : AddUniqueConstraint name (map findType cols)
                            : getAltersU news old'
        where
          findType = findTypeOfColumn allDefs tblName


-- | @findAlters newColumn oldColumns@ finds out what needs to be
-- changed in the columns @oldColumns@ for @newColumn@ to be
-- supported.
findAlters :: Show a => [EntityDef a] -> Column -> [Column] -> ([AlterColumn'], [Column])
findAlters allDefs col@(Column name isNull type_ def defConstraintName _maxLen ref) cols =
    case filter ((name ==) . cName) cols of
        [] -> ( let cnstr = [addReference allDefs tname | Just (tname, _) <- [ref]]
                in map ((,) name) (Add' col : cnstr)
              , cols )
        Column _ isNull' type_' def' defConstraintName' _maxLen' ref':_ ->
            let -- Foreign key
                refDrop = case (ref == ref', ref') of
                            (False, Just (_, cname)) -> [(name, DropReference cname)]
                            _ -> []
                refAdd  = case (ref == ref', ref) of
                            (False, Just (tname, _)) -> [(name, addReference allDefs tname)]
                            _ -> []
                -- Type and nullability
                modType | tpcheck type_ type_' && isNull == isNull' = []
                        | otherwise = [(name, Change col)]
                -- Default value
                modDef | cmpdef def def' = []
                       | otherwise   = --trace ("findAlters col=" ++ show col ++ " def=" ++ show def ++ " def'=" ++ show def') $
                                       case def of
                                         Nothing -> [(name, NoDefault)]
                                         Just s -> [(name, Default $ T.unpack s)]
            in ( refDrop ++ modType ++ modDef ++ refAdd
               , filter ((name /=) . cName) cols )


cmpdef::Maybe Text -> Maybe Text -> Bool
cmpdef Nothing Nothing = True
cmpdef (Just def) (Just def') = def == "'" <> def' <> "'"
cmpdef _ _ = False

tpcheck :: SqlType -> SqlType -> Bool
tpcheck SqlDayTime SqlString = True
tpcheck SqlString SqlDayTime = True
tpcheck (SqlNumeric _ _) SqlReal = True
tpcheck SqlReal (SqlNumeric _ _) = True
tpcheck a b = a==b
----------------------------------------------------------------------


-- | Prints the part of a @CREATE TABLE@ statement about a given
-- column.
showColumn :: Column -> String
showColumn (Column n nu t def defConstraintName maxLen ref) = concat
    [ escapeDBName n
    , " "
    , showSqlType t maxLen
    , " "
    , if nu then "NULL" else "NOT NULL"
    , case def of
        Nothing -> ""
        Just s -> " DEFAULT " ++ T.unpack s
    , case ref of
        Nothing -> ""
        Just (s, _) -> " REFERENCES " ++ escapeDBName s
    ]


-- | Renders an 'SqlType' in MySQL's format.
showSqlType :: SqlType
            -> Maybe Integer -- ^ @maxlen@
            -> String
showSqlType SqlBlob    Nothing    = "BLOB"
showSqlType SqlBlob    (Just i)   = "VARBINARY(" ++ show i ++ ")"
showSqlType SqlBool    _          = "TINYINT(1)"
showSqlType SqlDay     _          = "DATE"
showSqlType SqlDayTime _          = "VARCHAR(50) CHARACTER SET utf8" -- "DATETIME"
showSqlType SqlDayTimeZoned _     = "VARCHAR(50) CHARACTER SET utf8"
showSqlType SqlInt32   _          = "INT"
showSqlType SqlInt64   _          = "BIGINT"
showSqlType SqlReal    _          = "DOUBLE PRECISION"
showSqlType (SqlNumeric s prec) _ = "NUMERIC(" ++ show s ++ "," ++ show prec ++ ")"
showSqlType SqlString  Nothing    = "TEXT CHARACTER SET utf8"
showSqlType SqlString  (Just i)   = "VARCHAR(" ++ show i ++ ") CHARACTER SET utf8"
showSqlType SqlTime    _          = "TIME"
showSqlType (SqlOther t) _        = T.unpack t

-- | Render an action that must be done on the database.
showAlterDb :: AlterDB -> (Bool, Text)
showAlterDb (AddTable s) = (False, pack s)
showAlterDb (AlterColumn t (c, ac)) =
    (isUnsafe ac, pack $ showAlter t (c, ac))
  where
    isUnsafe Drop = True
    isUnsafe _    = False
showAlterDb (AlterTable t at) = (False, pack $ showAlterTable t at)


-- | Render an action that must be done on a table.
showAlterTable :: DBName -> AlterTable -> String
showAlterTable table (AddUniqueConstraint cname cols) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName cname
    , " UNIQUE("
    , intercalate "," $ map escapeDBName' cols
    , ")"
    ]
    where
      escapeDBName' (name, FTTypeCon _ "Text"      ) = escapeDBName name ++ "(200)"
      escapeDBName' (name, FTTypeCon _ "String"    ) = escapeDBName name ++ "(200)"
      escapeDBName' (name, FTTypeCon _ "ByteString") = escapeDBName name ++ "(200)"
      escapeDBName' (name, _                       ) = escapeDBName name
showAlterTable table (DropUniqueConstraint cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP INDEX "
    , escapeDBName cname
    ]


-- | Render an action that must be done on a column.
showAlter :: DBName -> AlterColumn' -> String
showAlter table (oldName, Change (Column n nu t def defConstraintName maxLen _ref)) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " CHANGE "
    , escapeDBName oldName
    , " "
    , showColumn (Column n nu t def defConstraintName maxLen Nothing)
    ]
showAlter table (_, Add' col) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD COLUMN "
    , showColumn col
    ]
showAlter table (n, Drop) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP COLUMN "
    , escapeDBName n
    ]
showAlter table (n, Default s) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " SET DEFAULT "
    , s
    ]
showAlter table (n, NoDefault) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " DROP DEFAULT"
    ]
showAlter table (n, Update' s) =
    concat
    [ "UPDATE "
    , escapeDBName table
    , " SET "
    , escapeDBName n
    , "="
    , s
    , " WHERE "
    , escapeDBName n
    , " IS NULL"
    ]
showAlter table (n, AddReference t2 id2) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName $ refName table n
    , " FOREIGN KEY("
    , escapeDBName n
    , ") REFERENCES "
    , escapeDBName t2
    , "("
    , escapeDBName id2
    , ")"
    ]
showAlter table (_, DropReference cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP FOREIGN KEY "
    , escapeDBName cname
    ]

refName :: DBName -> DBName -> DBName
refName (DBName table) (DBName column) =
    DBName $ T.concat [table, "_", column, "_fkey"]


----------------------------------------------------------------------


-- | Escape a database name to be included on a query.
escapeDBName :: DBName -> String
escapeDBName (DBName s) = '`' : go (T.unpack s)
    where
      go ('`':xs) = '`' : '`' : go xs
      go ( x :xs) =     x     : go xs
      go ""       = "`"
-- | SQL code to be executed when inserting an entity.
insertSql' :: DBName -> [FieldDef SqlType] -> DBName -> [PersistValue] -> Bool -> InsertSqlResult
insertSql' t cols id' vals True =
  let keypair = case vals of
                  (PersistInt64 _:PersistInt64 _:_) -> map (\(PersistInt64 i) -> i) vals -- gb fix unsafe
                  _ -> error $ "unexpected vals returned: vals=" ++ show vals
  in trace ("yes ISRManyKeys!!! sql="++show sql) $
      ISRManyKeys sql keypair
        where sql = pack $ concat
                [ "INSERT INTO "
                , escapeDBName t
                , "("
                , intercalate "," $ map (escapeDBName . fieldDB) $ filter (\fd -> null $ fieldManyDB fd) cols
                , ") VALUES("
                , intercalate "," (map (const "?") cols)
                , ")"
                ]

insertSql' t cols _ _ m2m = ISRInsertGet doInsert "SELECT LAST_INSERT_ID()"
    where
      doInsert = pack $ concat
        [ "INSERT INTO "
        , escapeDBName t
        , "("
        , intercalate "," $ map (escapeDBName . fieldDB) cols
        , ") VALUES("
        , intercalate "," (map (const "?") cols)
        , ")"
        ]
