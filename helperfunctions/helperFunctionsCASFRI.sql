  ------------------------------------------------------------------------------
-- CASFRI Helper functions installation file for CASFR v5 beta
-- For use with PostgreSQL Table Tranlation Engine v0.1 for PostgreSQL 9.x
-- https://github.com/edwardsmarc/postTranslationEngine
-- https://github.com/edwardsmarc/casfri
--
-- This is free software; you can redistribute and/or modify it under
-- the terms of the GNU General Public Licence. See the COPYING file.
--
-- Copyright (C) 2018-2020 Pierre Racine <pierre.racine@sbf.ulaval.ca>, 
--                         Marc Edwards <medwards219@gmail.com>,
--                         Pierre Vernier <pierre.vernier@gmail.com>
-------------------------------------------------------------------------------
-- Begin Tools Function Definitions...
------------------------------------------------------------------------------- 
-- TT_TableColumnType 
-- 
--   tableSchema name - Name of the schema containing the table. 
--   table name       - Name of the table. 
--   column name      - Name of the column. 
-- 
--   RETURNS text     - Type. 
-- 
-- Return the column names for the specified table. 
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_TableColumnType(name, name, name);
CREATE OR REPLACE FUNCTION TT_TableColumnType( 
  schemaName name, 
  tableName name,
  columnName name
) 
RETURNS text AS $$ 
  SELECT data_type FROM information_schema.columns
  WHERE table_schema = schemaName AND table_name = tableName AND column_name = columnName;
$$ LANGUAGE sql STABLE; 
-------------------------------------------------------------------------------

------------------------------------------------------------------------------- 
-- TT_TableColumnNames 
-- 
--   tableSchema name - Name of the schema containing the table. 
--   table name       - Name of the table. 
-- 
--   RETURNS text[]   - ARRAY of column names. 
-- 
-- Return the column names for the speficied table. 
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_TableColumnNames(name, name);
CREATE OR REPLACE FUNCTION TT_TableColumnNames( 
  schemaName name, 
  tableName name 
) 
RETURNS text[] AS $$ 
  DECLARE 
    colNames text[]; 
  BEGIN 
    SELECT array_agg(column_name::text) 
    FROM information_schema.columns 
    WHERE table_schema = schemaName AND table_name = tableName 
    INTO STRICT colNames; 

    RETURN colNames; 
  END; 
$$ LANGUAGE plpgsql VOLATILE; 
------------------------------------------------------------------------------- 

------------------------------------------------------------------------------- 
-- TT_TableColumnIsUnique
--
-- Return TRUE if the column values are unique. 
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_TableColumnIsUnique(name, name, name);
CREATE OR REPLACE FUNCTION TT_TableColumnIsUnique(
  schemaName name,
  tableName name,
  columnName name
)
RETURNS boolean AS $$
  DECLARE 
    isUnique boolean; 
  BEGIN
    EXECUTE 'SELECT (SELECT ' || columnName || 
           ' FROM ' || TT_FullTableName(schemaName, tableName) ||
           ' GROUP BY ' || columnName || 
           ' HAVING count(*) > 1
             LIMIT 1) IS NULL;'
    INTO isUnique;
    RETURN isUnique; 
  END;
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

------------------------------------------------------------------------------- 
-- TT_TableColumnIsUnique 
--
-- Return the list of column for a table and their uniqueness. 
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_TableColumnIsUnique(name, name);
CREATE OR REPLACE FUNCTION TT_TableColumnIsUnique(
  schemaName name,
  tableName name
)
RETURNS TABLE (col_name text, is_unique boolean) AS $$
  WITH column_names AS (
    SELECT unnest(TT_TableColumnNames(schemaName, tableName)) cname
  )
  SELECT cname, TT_TableColumnIsUnique(schemaName, tableName, cname) is_unique
FROM column_names;
$$ LANGUAGE sql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_ColumnExists
--
-- Returns true if a column exist in a table. Mainly defined to be used by 
-- ST_AddUniqueID().
-----------------------------------------------------------
-- Self contained example:
--
-- SELECT TT_ColumnExists('public', 'spatial_ref_sys', 'srid') ;
-----------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_ColumnExists(name, name, name);
CREATE OR REPLACE FUNCTION TT_ColumnExists(
  schemaname name,
  tablename name,
  columnname name
)
RETURNS BOOLEAN AS $$
  DECLARE
  BEGIN
    PERFORM 1 FROM information_schema.COLUMNS
    WHERE lower(table_schema) = lower(schemaname) AND lower(table_name) = lower(tablename) AND lower(column_name) = lower(columnname);
    RETURN FOUND;
  END;
$$ LANGUAGE plpgsql VOLATILE STRICT;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CompareRows 
-- 
-- Return all different attribute values with values from row1 and row2.
-- Does not return anything when rows are identical.
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_CompareRows(jsonb, jsonb);
CREATE OR REPLACE FUNCTION TT_CompareRows(
  row1 jsonb,
  row2 jsonb
)
RETURNS TABLE (attribute text, 
               row_1 text, 
               row_2 text) AS $$ 
  DECLARE
    i int = 0;
    keys text[];
    row1val text;
    row2val text;
  BEGIN
    attribute = 'row';

    IF row1 IS NULL THEN
        row_1 = 'do not exist';
        row_2 = 'exists';
        RETURN NEXT;
        RETURN;
    END IF;
    IF row2 IS NULL THEN
        row_1 = 'exists';
        row_2 = 'do not exist';
        RETURN NEXT;
        RETURN;
    END IF;
    SELECT array_agg(k) INTO keys
    FROM (SELECT jsonb_object_keys(row1) k) foo;

    FOR i IN 1..cardinality(keys) LOOP
      row1val = row1 -> keys[i];
      row2val = row2 -> keys[i];
      IF row1val != row2val THEN
        attribute = keys[i];
        row_1 = row1val::text;
        row_2 = row2val::text;
        RETURN NEXT;
      END IF;
    END LOOP;
    RETURN;
  END;
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CompareTables 
-- 
-- Return all different attribute values with values from table 1 and table 2.
-- Does not return anything when tables are identical.
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_CompareTables(name, name, name, name, name, boolean);
CREATE OR REPLACE FUNCTION TT_CompareTables(
  schemaName1 name,
  tableName1 name,
  schemaName2 name,
  tableName2 name,
  uniqueIDCol name DEFAULT NULL,
  ignoreColumnOrder boolean DEFAULT TRUE
)
RETURNS TABLE (row_id text, 
               attribute text, 
               value_table_1 text, 
               value_table_2 text) AS $$
  DECLARE
    columnName text;
    cols1 text[];
    cols2 text[];
    type1 text;
    type2 text;
    stop boolean := FALSE;
    query text;
  BEGIN
    IF NOT TT_TableExists(schemaName1, tableName1) THEN
      RAISE EXCEPTION 'Table %.% does not exists...', schemaName1, tableName1;
    END IF;
    IF NOT TT_TableExists(schemaName2, tableName2) THEN
      RAISE EXCEPTION 'Table %.% does not exists...', schemaName2, tableName2;
    END IF;
    cols1 = TT_TableColumnNames(schemaName1, tableName1);
    cols2 = TT_TableColumnNames(schemaName2, tableName2);
    -- Check that every column in table1 exists in table2
    FOREACH columnName IN ARRAY cols1 LOOP
      IF columnName != ALL(cols2) THEN
        RAISE EXCEPTION 'Column ''%'' does not exist in %.%...', columnName, schemaName2, tableName2;
        stop = TRUE;
      ELSE
        type1 = TT_TableColumnType(schemaName1, tableName1, columnName);
        type2 = TT_TableColumnType(schemaName2, tableName2, columnName);
        IF type1 != type2 THEN
          RAISE EXCEPTION 'Column ''%'' is of type ''%'' in %.% and of type ''%'' in table %.%...', columnName, type1, schemaName1, tableName1, type2, schemaName2, tableName2;
          stop = TRUE;
        END IF;
      END IF;
    END LOOP;
    -- Check that every column in table2 exists in table1
    FOREACH columnName IN ARRAY cols2 LOOP
      IF columnName != ALL(cols1) THEN
        RAISE EXCEPTION 'Column ''%'' does not exist in %.%...', columnName, schemaName1, tableName1;
        stop = TRUE;
      END IF;
    END LOOP;
    -- Stop for now
    IF stop THEN
      RETURN;
    END IF;
    -- Now that we know both tables have the same columns, check that they are in the same order
    IF NOT ignoreColumnOrder AND cols1 != cols2 THEN
      RAISE EXCEPTION 'Columns with the same names and types exist in both tables but are not in the same order...';
      RETURN;
    END IF;
    
    -- Check that uniqueIDCol is not NULL and exists
    IF uniqueIDCol IS NULL OR uniqueIDCol = '' THEN
      RAISE EXCEPTION 'Table have same structure. In order to report different rows, uniqueIDCol should not be NULL...';
    END IF;
    IF NOT TT_ColumnExists(schemaName1, tableName1, uniqueIDCol) THEN
      RAISE EXCEPTION 'Table have same structure. In order to report different rows, uniqueIDCol (%) should exist in both tables...', uniqueIDCol;
    END IF;
    query = 'SELECT ' || uniqueIDCol || '::text row_id, (TT_CompareRows(to_jsonb(a), to_jsonb(b))).* ' ||
            'FROM ' || schemaName1 || '.' || tableName1 || ' a ' ||
            'FULL OUTER JOIN ' || schemaName2 || '.' || tableName2 || ' b USING (' || uniqueIDCol || ')' ||
            'WHERE NOT coalesce(ROW(a.*) = ROW(b.*), FALSE);';
    RETURN QUERY EXECUTE query;
  END;
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_RandomInt 
-- 
-- Return a list of random nb integer from val_min to val_max (both inclusives).
-- Seed can be set to get always the same repeated list.
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_RandomInt(int, int, int, double precision);
CREATE OR REPLACE FUNCTION TT_RandomInt(
  nb int, 
  val_min int,
  val_max int,
  seed double precision
)
RETURNS TABLE (id int) AS $$
  DECLARE
    newnb int;
  BEGIN
    IF nb < 0 THEN
      RAISE EXCEPTION 'ERROR random_int_id(): nb (%) must be greater than 0...', nb;
    END IF;
    IF nb = 0 THEN
      RETURN;
    END IF;
    IF val_max < val_min THEN
      RAISE EXCEPTION 'ERROR TT_RandomInt(): val_max (%) must be greater or equal to val_min (%)...', val_max, val_min;
    END IF;
    IF nb > (val_max - val_min + 1) THEN
      RAISE EXCEPTION 'ERROR TT_RandomInt(): nb (%) must be smaller or equal to the range of values (%)...', nb, val_max - val_min + 1;
    END IF;
    IF nb = (val_max - val_min + 1) THEN
       RAISE NOTICE 'nb is equal to the range of requested values. Returning a series from % to %...', val_min, val_min + nb - 1;
       RETURN QUERY SELECT val_min + generate_series(0, nb - 1);
       RETURN;
    END IF;
    IF nb > (val_max - val_min + 1) / 2 THEN
       RAISE NOTICE 'nb is greater than half the range of requested values. Returning a % to % series EXCEPT TT_RandomInt(%, %, %, %)...', val_min, val_min + val_max - val_min, (val_max - val_min + 1) - nb, val_min, val_max, seed;
       RETURN QUERY SELECT * FROM (
                      SELECT val_min + generate_series(0, val_max - val_min) id
                      EXCEPT 
                      SELECT TT_RandomInt((val_max - val_min + 1) - nb, val_min, val_max, seed)
                    ) foo ORDER BY id;
       RETURN;
    END IF;
    newnb = nb * (1 + 3 * nb::double precision / (val_max - val_min + 1));
--RAISE NOTICE 'newnb = %', newnb;
--RAISE NOTICE 'seed = %', nb / (nb + abs(seed) + 1);
    PERFORM setseed(nb / (nb + abs(seed) + 1));
    RETURN QUERY WITH rd AS (
                   SELECT (val_min + floor((val_max - val_min + 1) * foo.rd))::int id, foo.rd
                   FROM (SELECT generate_series(1, newnb), random() rd) foo
                 ), list AS (
                   SELECT DISTINCT rd.id 
                   FROM rd LIMIT nb
                 ) SELECT * FROM list ORDER BY id;
  END;
$$ LANGUAGE plpgsql VOLATILE;
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_RandomInt(int, int, int);
CREATE OR REPLACE FUNCTION TT_RandomInt(
  nb int, 
  val_min int,
  val_max int
)
RETURNS SETOF int AS $$
  SELECT TT_RandomInt(nb, val_min, val_max, random());
$$ LANGUAGE sql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_Histogram 
-- 
-- Set function returnings a table representing an histogram of the values
-- for the specifed column.
--
-- The return table contains 3 columns:
--
--   'intervals' is a text column specifiing the lower and upper bounds of the
--               intervals (or bins). Start with '[' when the lower bound is
--               included in the interval and with ']' when the lowerbound is
--               not included in the interval. Complementarily ends with ']'
--               when the upper bound is included in the interval and with '['
--               when the upper bound is not included in the interval.
--
--   'cnt' is a integer column specifying the number of occurrence of the value
--         in this interval (or bin).
--
--   'query' is the query you can use to generate the rows accounted for in this
--           interval.
--
-- Self contained and typical example:
--
-- CREATE TABLE histogramtest AS
-- SELECT * FROM (VALUES (1), (2), (2), (3), (4), (5), (6), (7), (8), (9), (10)) AS t (val);
--
-- SELECT * FROM TT_Histogram('test', 'histogramtest1', 'val');
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_Histogram(text, text, text, int, text);
CREATE OR REPLACE FUNCTION TT_Histogram(
    schemaname text,
    tablename text,
    columnname text,
    nbinterval int DEFAULT 10, -- number of bins
    whereclause text DEFAULT NULL -- additional where clause
)
RETURNS TABLE (intervals text, cnt int, query text) AS $$
    DECLARE
    fqtn text;
    query text;
    newschemaname name;
    findnewcolumnname boolean := FALSE;
    newcolumnname text;
    columnnamecnt int := 0;
    whereclausewithwhere text := '';
    minval double precision := 0;
    maxval double precision := 0;
    columntype text;
    BEGIN
        IF nbinterval IS NULL THEN
            nbinterval = 10;
        END IF;
        IF nbinterval <= 0 THEN
            RAISE NOTICE 'nbinterval is smaller or equal to zero. Returning nothing...';
            RETURN;
        END IF;
        IF whereclause IS NULL OR whereclause = '' THEN
            whereclause = '';
        ELSE
            whereclausewithwhere = ' WHERE ' || whereclause || ' ';
            whereclause = ' AND (' || whereclause || ')';
        END IF;
        newschemaname := '';
        IF length(schemaname) > 0 THEN
            newschemaname := schemaname;
        ELSE
            newschemaname := 'public';
        END IF;
        fqtn := quote_ident(newschemaname) || '.' || quote_ident(tablename);

        -- Build an histogram with the column values.
        IF TT_ColumnExists(newschemaname, tablename, columnname) THEN

            -- Precompute the min and max values so we can set the number of interval to 1 if they are equal
            query = 'SELECT min(' || columnname || '), max(' || columnname || ') FROM ' || fqtn || whereclausewithwhere;
            EXECUTE QUERY query INTO minval, maxval;
            IF maxval IS NULL AND minval IS NULL THEN
                query = 'WITH values AS (SELECT ' || columnname || ' val FROM ' || fqtn || whereclausewithwhere || '),
                              histo  AS (SELECT count(*) cnt FROM values)
                         SELECT ''NULL''::text intervals,
                                cnt::int,
                                ''SELECT * FROM ' || fqtn || ' WHERE ' || columnname || ' IS NULL' || whereclause || ';''::text query
                         FROM histo;';
                RETURN QUERY EXECUTE query;
            ELSE
                IF maxval - minval = 0 THEN
                    RAISE NOTICE 'maximum value - minimum value = 0. Will create only 1 interval instead of %...', nbinterval;
                    nbinterval = 1;
                END IF;

                -- We make sure double precision values are converted to text using the maximum number of digits before computing summaries involving this type of values
                query = 'SELECT pg_typeof(' || columnname || ')::text FROM ' || fqtn || ' LIMIT 1';
                EXECUTE query INTO columntype;
                IF left(columntype, 3) != 'int' THEN
                    SET extra_float_digits = 3;
                END IF;

                -- Compute the histogram
                query = 'WITH values AS (SELECT ' || columnname || ' val FROM ' || fqtn || whereclausewithwhere || '),
                              bins   AS (SELECT val, CASE WHEN val IS NULL THEN -1 ELSE least(floor((val - ' || minval || ')*' || nbinterval || '::numeric/(' || (CASE WHEN maxval - minval = 0 THEN maxval + 0.000000001 ELSE maxval END) - minval || ')), ' || nbinterval || ' - 1) END bin, ' || (maxval - minval) || '/' || nbinterval || '.0 binrange FROM values),
                              histo  AS (SELECT bin, count(*) cnt FROM bins GROUP BY bin)
                         SELECT CASE WHEN serie = -1 THEN ''NULL''::text ELSE ''['' || (' || minval || ' + serie * binrange)::float8::text || '' - '' || (CASE WHEN serie = ' || nbinterval || ' - 1 THEN ' || maxval || '::float8::text || '']'' ELSE (' || minval || ' + (serie + 1) * binrange)::float8::text || ''['' END) END intervals,
                                coalesce(cnt, 0)::int cnt,
                                (''SELECT * FROM ' || fqtn || ' WHERE ' || columnname || ''' || (CASE WHEN serie = -1 THEN '' IS NULL'' || ''' || whereclause || ''' ELSE ('' >= '' || (' || minval || ' + serie * binrange)::float8::text || '' AND ' || columnname || ' <'' || (CASE WHEN serie = ' || nbinterval || ' - 1 THEN ''= '' || ' || maxval || '::float8::text ELSE '' '' || (' || minval || ' + (serie + 1) * binrange)::float8::text END) || ''' || whereclause || ''' || '' ORDER BY ' || columnname || ''') END) || '';'')::text query
                         FROM generate_series(-1, ' || nbinterval || ' - 1) serie
                              LEFT OUTER JOIN histo ON (serie = histo.bin),
                              (SELECT * FROM bins LIMIT 1) foo
                         ORDER BY serie;';
                RETURN QUERY EXECUTE query;
                IF left(columntype, 3) != 'int' THEN
                    RESET extra_float_digits;
                END IF;
            END IF;
        ELSE
            RAISE NOTICE '''%'' does not exists. Returning nothing...',columnname::text;
            RETURN;
        END IF;

        RETURN;
    END;
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_ArrayDistinct
-------------------------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_ArrayDistinct(anyarray, boolean, boolean);
CREATE OR REPLACE FUNCTION TT_ArrayDistinct(
  anyarray, 
  purgeNulls boolean DEFAULT FALSE, 
  purgeEmptys boolean DEFAULT FALSE
) 
RETURNS anyarray AS $$
  WITH numbered AS (
    SELECT ROW_NUMBER() OVER() rn, x
    FROM unnest($1) x 
    WHERE (purgeNulls IS FALSE OR NOT x IS NULL) AND (purgeEmptys IS FALSE OR TT_NotEmpty(x::text))
  ), distincts AS (
    SELECT x, min(rn) rn FROM numbered GROUP BY x ORDER BY rn
)
SELECT array_agg(x) FROM distincts
$$ LANGUAGE sql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_DeleteAllViews
--
-- schemaName text
--
-- Delete all view in the specified schema.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_DeleteAllViews(text);
CREATE OR REPLACE FUNCTION TT_DeleteAllViews(
  schemaName text
)
RETURNS SETOF text AS $$
  DECLARE
    res RECORD;
  BEGIN
    FOR res IN SELECT 'DROP VIEW IF EXISTS ' || TT_FullTableName(schemaName, table_name) || ';' query
               FROM information_schema.tables 
               WHERE lower(table_schema) = lower(schemaName) AND table_type = 'VIEW'
               ORDER BY table_name LOOP
      EXECUTE res.query;
      RETURN NEXT res.query;
    END LOOP;
    RETURN;
  END;
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CountEstimate
-------------------------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CountEstimate(text);
CREATE OR REPLACE FUNCTION TT_CountEstimate(
  query text
)
RETURNS integer AS $$
  DECLARE
    rec record;
    rows integer;
  BEGIN
    FOR rec IN EXECUTE 'EXPLAIN ' || query LOOP
      rows := substring(rec."QUERY PLAN" FROM ' rows=([[:digit:]]+)');
      EXIT WHEN rows IS NOT NULL;
    END LOOP;
    RETURN rows;
END;
$$ LANGUAGE plpgsql VOLATILE STRICT;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CreateMapping
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CreateMapping(text, text, int, name, int); 
CREATE OR REPLACE FUNCTION TT_CreateMapping( 
  schemaName text, 
  fromTableName text,
  fromLayer int,
  toTableName text,
  toLayer int
) 
RETURNS TABLE (num int, key text, from_att text, to_att text, contributing boolean) AS $$
  WITH colnames AS (
    SELECT TT_TableColumnNames('translation', 'attribute_dependencies') col_name_arr
  ), colnames_num AS (
    SELECT generate_series(1, cardinality(col_name_arr)) num, unnest(col_name_arr) colname
    FROM colnames
  ), from_att AS (
    -- Vertical table of all 'from' attribute mapping
    SELECT (jsonb_each(to_jsonb(a.*))).*
    FROM translation.attribute_dependencies a
    WHERE lower(btrim(btrim(inventory_id, ' '), '''')) = lower(fromTableName) AND layer = fromLayer::text
  ), to_att AS (
    -- Vertical table of all 'to' attribute mapping
    SELECT (jsonb_each(to_jsonb(a.*))).*
    FROM translation.attribute_dependencies a
    WHERE lower(btrim(btrim(inventory_id, ' '), '''')) = lower(toTableName) AND layer = toLayer::text
  ), splitted AS (
    -- Splitted by comma, still vertically
    SELECT colnames_num.num, from_att.key, 
           --rtrim(ltrim(trim(regexp_split_to_table(btrim(from_att.value::text, '"'), E',')), '['), ']') from_att, 
           trim(regexp_split_to_table(btrim(from_att.value::text, '"'), E',')) from_att, 
           trim(regexp_split_to_table(btrim(to_att.value::text, '"'), E',')) to_att
    FROM from_att, to_att, colnames_num
    WHERE colnames_num.colname = from_att.key AND 
          from_att.key = to_att.key AND 
          from_att.key != 'ogc_fid' AND 
          from_att.key != 'ttable_exists'
  )
  SELECT num, key,
         rtrim(ltrim(from_att, '['), ']') from_att,
         rtrim(ltrim(to_att, '['), ']') to_att,
         CASE WHEN left(from_att, 1) = '[' AND right(from_att, 1) = ']' THEN FALSE
              ELSE TRUE
         END contributing
  FROM splitted;
$$ LANGUAGE sql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CreateMappingView 
-- 
-- Return a view mapping attributes of fromTableName to attributes of toTableName
-- according to the translation.attribute_dependencies table.
-- Can also be used to create a view selecting the minimal set of useful attribute
-- and to get a random sample of the source table when randomNb is provided.
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text, int, int, text, text); 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text, int, int, text); 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text, int, int);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text, int); 
CREATE OR REPLACE FUNCTION TT_CreateMappingView( 
  schemaName text, 
  fromTableName text,
  fromLayer int,
  toTableName text,
  toLayer int,
  randomNb int DEFAULT NULL,
  rowSubset text DEFAULT NULL,
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  DECLARE
    queryStr text;
    viewName text;
    mappingRec RECORD;
    sourceTableCols text[] = '{}';
    attributeMapStr text;
    attributeArr text[] = '{}';
    whereExpArr text[] = '{}';
    whereExpLyrAddArr text[] = '{}';
    whereExpLyrNFLArr text[] = '{}';
    whereExpStr text = '';
    nb int;
    attName text;
    filteredTableName text;
    filteredNbColName text;
    attributeList boolean = FALSE;
    validRowSubset boolean = FALSE;
    attListViewName text = '';
    rowSubsetKeywords text[] = ARRAY['lyr', 'lyr2', 'nfl', 'dst', 'eco'];
    maxLayerNb int = 0;
  BEGIN
    -- Check if table 'attribute_dependencies' exists
    IF NOT TT_TableExists('translation', 'attribute_dependencies') THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): Could not find table ''translation.dependencies''...';
      RETURN 'ERROR: Could not find table ''translation.dependencies''...';
    END IF;

    -- Check if table fromTableName exists
    IF NOT TT_TableExists(schemaName, fromTableName) THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): Could not find table ''translation.%''...', fromTableName;
      RETURN 'ERROR: Could not find table ''translation..' || fromTableName || '''...';
    END IF;

    -- Check if an entry for (fromTableName, fromLayer) exists in table 'attribute_dependencies'
    SELECT count(*) FROM translation.attribute_dependencies
    WHERE lower(btrim(btrim(inventory_id, ' '), '''')) = lower(fromTableName) AND layer = fromLayer::text
    INTO nb;
    IF nb = 0 THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): No entry found for inventory_id ''%'' layer % in table ''translation.dependencies''...', fromTableName, fromLayer;
      RETURN 'ERROR: No entry could be found for inventory_id '''  || fromTableName || ''' layer ' || fromLayer || ' in table ''translation.dependencies''...';
    ELSIF nb > 1 THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): More than one entry match inventory_id ''%'' layer % in table ''translation.dependencies''...', fromTableName, fromLayer;
      RETURN 'ERROR: More than one entry match inventory_id '''  || fromTableName || ''' layer ' || fromLayer || ' in table ''translation.dependencies''...';
    END IF;

    -- Support a variant where rowSubset is the third parameter (not toTableName)
    sourceTableCols = TT_TableColumnNames(schemaName, fromTableName);
    IF fromLayer = 1 AND toLayer = 1 AND randomNb IS NULL AND viewNameSuffix IS NULL AND
       (lower(toTableName) = ANY (rowSubsetKeywords)  OR
        strpos(toTableName, ',') != 0 OR btrim(toTableName, ' ') = ANY (sourceTableCols)) THEN
      RAISE NOTICE 'TT_CreateMappingView(): Switching viewNameSuffix, rowSubset and toTableName...';
      viewNameSuffix = rowSubset;
      rowSubset = toTableName;
      toTableName = fromTableName;
    END IF;
    rowSubset = lower(btrim(rowSubset, ' '));

    -- Check rowSubset is a valid value
    IF NOT rowSubset IS NULL THEN
      -- If rowSubset is a reserved keyword
      IF rowSubset = ANY (rowSubsetKeywords) THEN
        -- We will later name the VIEW based on rowSubset
        IF viewNameSuffix IS NULL THEN
          viewNameSuffix = rowSubset;
        ELSE
          viewNameSuffix = rowSubset || '_' || viewNameSuffix;
        END IF;
        validRowSubset = TRUE;
      -- If rowSubset is a list of attributes
      ELSIF (strpos(rowSubset, ',') != 0 OR rowSubset = ANY (sourceTableCols)) THEN
        attributeArr = string_to_array(rowSubset, ',');
        FOREACH attName IN ARRAY attributeArr LOOP
          attName = btrim(attName, ' ');
          IF NOT attName = ANY (sourceTableCols) THEN
            RAISE NOTICE 'ERROR TT_CreateMappingView(): Attribute ''%'' in ''rowSubset'' not found in table ''translation.%''...', attName, fromTableName;
            RETURN 'ERROR: Attribute ''' || attName || ''' in ''rowSubset'' not found in table ''translation.''' || fromTableName || '''...';
          END IF;
          whereExpArr = array_append(whereExpArr, '(TT_NotEmpty(' || attName || '::text) AND ' || attName || '::text != ''0'')');
          attListViewName = attListViewName || lower(left(attName, 1));
        END LOOP;
        IF viewNameSuffix IS NULL THEN
          viewNameSuffix = attListViewName;
        END IF;
        attributeList = TRUE;
        validRowSubset = TRUE;
      ELSE
        RAISE NOTICE 'ERROR TT_CreateMappingView(): Invalid rowSubset value (%)...', rowSubset;
        RETURN 'ERROR: Invalid rowSubset value (' || rowSubset || ')...';
      END IF;
    END IF;

    -- Check if an entry for (toTableName, toLayer) exists in table 'attribute_dependencies'
    SELECT count(*) FROM translation.attribute_dependencies
    WHERE lower(btrim(btrim(inventory_id, ' '), '''')) = lower(toTableName) AND layer = toLayer::text
    INTO nb;
    IF nb = 0 THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): No entry found for inventory_id ''%'' layer % in table ''translation.dependencies''...', toTableName, toLayer;
      RETURN 'ERROR: No entry could be found for inventory_id '''  || toTableName || ''' layer ' || toLayer || ' in table ''translation.dependencies''...';
    ELSIF nb > 1 THEN
      RAISE NOTICE 'ERROR TT_CreateMappingView(): More than one entry match inventory_id ''%'' layer % in table ''translation.dependencies''...', toTableName, toLayer;
      RETURN 'ERROR: More than one entry match inventory_id '''  || toTableName || ''' layer ' || toLayer || ' in table ''translation.dependencies''...';
    END IF;

    -- Build the attribute mapping string
      WITH mapping AS (
        SELECT * FROM TT_CreateMapping(schemaName, fromTableName, fromLayer, toTableName, toLayer)
      ), unique_att AS (
      -- Create only one map for each 'to' attribute (there can not be more than one)
      SELECT DISTINCT ON (to_att)
         num, key,
         -- Make sure to quote the 'from' part if it is a constant
         CASE WHEN TT_IsName(from_att) AND lower(key) != 'inventory_id' THEN from_att
              ELSE '''' || btrim(from_att, '''') || ''''
         END from_att,
         -- If the 'to' part is a contant, map the 'from' attribute to itself. They will be fixed later.
         CASE WHEN TT_IsName(to_att) THEN to_att
              WHEN TT_IsName(from_att) THEN from_att
              ELSE key
         END to_att
      FROM mapping
      WHERE TT_NotEmpty(from_att)
      ORDER BY to_att, from_att
    ), ordered_maps AS (
      SELECT num, key, 
             from_att || CASE WHEN from_att = to_att THEN '' 
                              ELSE ' AS ' || to_att 
                         END mapstr,
             CASE WHEN key = ANY (ARRAY['inventory_id', 'layer', 'layer_rank', 'cas_id', 'orig_stand_id', 'stand_structure', 'num_of_layers', 'map_sheet_id', 'casfri_area', 'casfri_perimeter', 'src_inv_area', 'stand_photo_year']) THEN 1
                  WHEN key = ANY (ARRAY['soil_moist_reg', 'structure_per', 'crown_closure_upper', 'crown_closure_lower', 'height_upper', 'height_lower', 'productive_for']) THEN 2
                  WHEN key = ANY (ARRAY['species_1', 'species_per_1', 'species_2', 'species_per_2', 'species_3', 'species_per_3', 'species_4', 'species_per_4', 'species_5', 'species_per_5', 'species_6', 'species_per_6', 'species_7', 'species_per_7', 'species_8', 'species_per_8', 'species_9', 'species_per_9', 'species_10', 'species_per_10']) THEN 3
                  WHEN key = ANY (ARRAY['origin_upper', 'origin_lower', 'site_class', 'site_index']) THEN 4
                  WHEN key = ANY (ARRAY['nat_non_veg', 'non_for_anth', 'non_for_veg']) THEN 5
                  WHEN key = ANY (ARRAY['dist_type_1', 'dist_year_1', 'dist_ext_upper_1', 'dist_ext_lower_1']) THEN 6
                  WHEN key = ANY (ARRAY['dist_type_2', 'dist_year_2', 'dist_ext_upper_2', 'dist_ext_lower_2']) THEN 7
                  WHEN key = ANY (ARRAY['dist_type_3', 'dist_year_3', 'dist_ext_upper_3', 'dist_ext_lower_3']) THEN 8
                  WHEN key = ANY (ARRAY['wetland_type', 'wet_veg_cover', 'wet_landform_mod', 'wet_local_mod', 'eco_site']) THEN 9
                  ELSE 10
             END groupid
      FROM unique_att ORDER BY num
    )
    SELECT string_agg(str, ', ' || chr(10))
    FROM (SELECT string_agg(mapstr, ', ') str
          FROM ordered_maps
          GROUP BY groupid
          ORDER BY groupid) foo
    INTO attributeMapStr;

    -- Determine max_layer_number and add it to the list of attributes
    maxLayerNb = CASE WHEN rowSubset IS NULL OR rowSubset != 'nfl' THEN fromLayer ELSE fromLayer + 2 END;
    attributeMapStr = attributeMapStr || ', ' || maxLayerNb || ' max_layer_number';
    
    -- Build the WHERE string
    IF validRowSubset AND NOT attributeList THEN
      FOR mappingRec IN SELECT * 
                        FROM TT_CreateMapping(schemaName, fromTableName, fromLayer, toTableName, toLayer)
                        WHERE TT_NotEmpty(from_att) LOOP
        IF mappingRec.contributing AND (((rowSubset = 'lyr' OR rowSubset = 'lyr2') AND (mappingRec.key = 'species_1' OR mappingRec.key = 'species_2' OR mappingRec.key = 'species_3')) OR
           (rowSubset = 'nfl' AND (mappingRec.key = 'nat_non_veg' OR mappingRec.key = 'non_for_anth' OR mappingRec.key = 'non_for_veg')) OR
           (rowSubset = 'dst' AND (mappingRec.key = 'dist_type_1' OR mappingRec.key = 'dist_year_1' OR mappingRec.key = 'dist_type_2' OR mappingRec.key = 'dist_year_2' OR mappingRec.key = 'dist_type_3' OR mappingRec.key = 'dist_year_3')) OR
           (rowSubset = 'eco' AND mappingRec.key = 'wetland_type'))
        THEN
          whereExpArr = array_append(whereExpArr, '(TT_NotEmpty(' || mappingRec.from_att || '::text) AND ' || mappingRec.from_att || '::text != ''0'')');
        END IF;
        IF rowSubset = 'lyr2' THEN
          -- Add soil_moist_reg, site_class and site_index
          IF mappingRec.contributing AND (mappingRec.key = 'soil_moist_reg' OR mappingRec.key = 'site_class' OR mappingRec.key = 'site_index') THEN
            whereExpLyrAddArr = array_append(whereExpLyrAddArr, '(TT_NotEmpty(' || mappingRec.from_att || '::text) AND ' || mappingRec.from_att || '::text != ''0'')');
          END IF;
          -- Except when any NFL attribute is set
          IF mappingRec.contributing AND (mappingRec.key = 'nat_non_veg' OR mappingRec.key = 'non_for_anth' OR mappingRec.key = 'non_for_veg' OR mappingRec.key = 'dist_type_1' OR mappingRec.key = 'dist_type_2') THEN
            whereExpLyrNFLArr = array_append(whereExpLyrNFLArr, '(TT_NotEmpty(' || mappingRec.from_att || '::text) AND ' || mappingRec.from_att || '::text != ''0'')');
          END IF;
        END IF;
      END LOOP;
    END IF;

    nb = NULL;
    -- Concatenate the WHERE attribute into a string
    IF cardinality(whereExpArr) = 0 AND validRowSubset THEN
      whereExpStr = '  WHERE FALSE = TRUE';
      nb = 0;
    ELSIF cardinality(whereExpArr) > 0 THEN
      whereExpStr = '  WHERE ' || array_to_string(TT_ArrayDistinct(whereExpArr), ' OR ' || chr(10) || '        ');
      
      -- Add extra condition for lyr including soil_moist_reg, site_class and site_index when NFL attributes are not set
      IF rowSubset = 'lyr2' THEN
        whereExpStr = whereExpStr || ' OR ' || chr(10) || 
                      '        ((' || array_to_string(TT_ArrayDistinct(whereExpLyrAddArr), ' OR ' || chr(10) || '          ') || ') AND ' || chr(10) || 
                      '         NOT (' || array_to_string(TT_ArrayDistinct(whereExpLyrNFLArr), ' OR ' || chr(10) || '              ') || '))';
      END IF;
    END IF;

    -- Contruct the name of the VIEW
    viewName = TT_FullTableName(schemaName, fromTableName || 
               CASE WHEN fromTableName = toTableName AND fromLayer = toLayer AND fromLayer != 1 THEN '_min_l' || fromLayer
                    WHEN fromTableName = toTableName AND fromLayer = toLayer THEN '_min' 
                    ELSE '_l' || fromLayer || '_to_' || toTableName || '_l' || toLayer || '_map' 
               END || coalesce('_' || randomNb, '') || coalesce('_' || viewNameSuffix, ''));

    -- Build the VIEW query
    queryStr = 'DROP VIEW IF EXISTS ' || viewName || ' CASCADE;' || chr(10) ||
               'CREATE OR REPLACE VIEW ' || viewName || ' AS' || chr(10);
    
    filteredTableName = TT_FullTableName(schemaName, fromTableName);
    filteredNbColName = 'ogc_fid';
    IF TT_NotEmpty(whereExpStr) THEN
      filteredTableName = 'filtered_rows_nb';
      filteredNbColName = 'rownb';
      queryStr = queryStr ||
                 'WITH filtered_rows AS (' || chr(10) ||
                 '  SELECT *' || chr(10) ||
                 '  FROM ' || TT_FullTableName(schemaName, fromTableName) || chr(10) ||
                 whereExpStr || chr(10) ||
                 '), filtered_rows_nb AS (' || chr(10) ||
                 '  SELECT ROW_NUMBER() OVER(ORDER BY ogc_fid) ' || filteredNbColName || ', filtered_rows.*' || chr(10) ||
                 '  FROM filtered_rows' || chr(10) ||
                 ')' || chr(10);
    END IF;
    queryStr = queryStr ||
               'SELECT ' || attributeMapStr || chr(10) ||
               'FROM ' || filteredTableName || ' fr';

    -- Make it random if requested
    IF NOT randomNb IS NULL THEN
      queryStr = queryStr || ', TT_RandomInt(' || randomNb || ', 1, (SELECT count(*) FROM ' || filteredTableName || ')::int, 1.0) rd' || chr(10) ||
                'WHERE rd.id = fr.' || filteredNbColName || chr(10) ||
                'LIMIT ' || randomNb || ';';
    END IF;
    RAISE NOTICE 'TT_CreateMappingView(): Creating VIEW ''%''...', viewName;
    EXECUTE queryStr;
    
    -- Display the approximate number of row returned by the view
    IF nb IS NULL THEN
      nb = TT_CountEstimate('SELECT 1 FROM ' || viewName);
    END IF;
    IF nb < 2 THEN
      RAISE NOTICE 'WARNING TT_CreateMappingView(): VIEW ''%'' should return 0 rows...', viewName; 
    ELSIF nb < 1000 THEN
       RAISE NOTICE 'TT_CreateMappingView(): VIEW ''%'' should return % rows...', viewName, nb;
    ELSE
      RAISE NOTICE 'TT_CreateMappingView(): VIEW ''%'' should return at least 1000 rows or more...', viewName;
    END IF;
    RETURN queryStr;
  END; 
$$ LANGUAGE plpgsql VOLATILE;
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, name, int, text, text);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, name, int, text);
CREATE OR REPLACE FUNCTION TT_CreateMappingView( 
  schemaName text,
  fromTableName text,
  fromLayer int, 
  toTableName text,
  toLayer int,
  rowSubset text,
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  SELECT TT_CreateMappingView(schemaName, fromTableName, fromLayer, toTableName, toLayer, NULL, rowSubset, viewNameSuffix);
$$ LANGUAGE sql VOLATILE;
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text, int, text, text);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text, int, text);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text, int); 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text); 
CREATE OR REPLACE FUNCTION TT_CreateMappingView( 
  schemaName text,
  fromTableName text,
  toTableName text,
  randomNb int DEFAULT NULL,
  rowSubset text DEFAULT NULL,
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  SELECT TT_CreateMappingView(schemaName, fromTableName, 1, toTableName, 1, randomNb, rowSubset, viewNameSuffix);
$$ LANGUAGE sql VOLATILE;
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text, text, text); 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, text, text); 
CREATE OR REPLACE FUNCTION TT_CreateMappingView( 
  schemaName text, 
  fromTableName text,
  toTableName text,
  rowSubset text,
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  SELECT TT_CreateMappingView(schemaName, fromTableName, 1, toTableName, 1, NULL, rowSubset, viewNameSuffix);
$$ LANGUAGE sql VOLATILE;
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text, text);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int, text);
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text, int); 
--DROP FUNCTION IF EXISTS TT_CreateMappingView(text, text); 
CREATE OR REPLACE FUNCTION TT_CreateMappingView( 
  schemaName text,
  fromTableName text,
  randomNb int DEFAULT NULL,
  rowSubset text DEFAULT NULL,
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  SELECT TT_CreateMappingView(schemaName, fromTableName, 1, fromTableName, 1, randomNb, rowSubset, viewNameSuffix);
$$ LANGUAGE sql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_CreateFilterView 
-- 
-- Create a VIEW listing only the 'selectAttrList' WHERE 'whereInAttrList' are 
-- TT_NotEmpty() and 'whereOutAttrList' are NOT TT_NotEmpty(). The name 
-- of the view can be suffixed with viewNameSuffix. Otherwise it will get a 
-- random number.
------------------------------------------------------------ 
--DROP FUNCTION IF EXISTS TT_CreateFilterView(text, text, text, text, text, text); 
CREATE OR REPLACE FUNCTION TT_CreateFilterView( 
  schemaName text, 
  tableName text,
  selectAttrList text,
  whereInAttrList text DEFAULT '',
  whereOutAttrList text DEFAULT '',
  viewNameSuffix text DEFAULT NULL
) 
RETURNS text AS $$ 
  DECLARE
    queryStr text;
    viewName text;
    fullTableName text = TT_FullTableName(schemaName, tableName);
    mappingRec RECORD;
    sourceTableCols text[] = '{}';
    keywordArr text[] = ARRAY['lyr1', 'lyr2', 'lyr3', 'nfl1', 'nfl2', 'nfl3', 'nfl4', 'nfl5', 'nfl6', 'dst1', 'dst2', 'eco'];
    keyword text;
    nb int;
    layer text;
    attName text;
    attArr text[] = '{}';
    sigAttArr text[] = '{}';
    attList text;
    sigAttList text;
    selectAttrArr text[] = '{}';
    whereInAttrArr text[] = '{}';
    whereInAttrStrArr text[] = '{}';
    whereOutAttrArr text[] = '{}';
    whereOutAttrStrArr text[] = '{}';
    whereInAttrListArr text[] = '{}';
    attCount int = 0;
    trimmedAttName text;
    indentStr text;
  BEGIN
    -- Check if table 'attribute_dependencies' exists
    IF NOT TT_TableExists('translation', 'attribute_dependencies') THEN
      RAISE NOTICE 'ERROR TT_CreateFilterView(): Could not find table ''translation.dependencies''...';
      RETURN 'ERROR: Could not find table ''translation.dependencies''...';
    END IF;

    -- Check if tableName exists
    IF NOT TT_TableExists(schemaName, tableName) THEN
      RAISE NOTICE 'ERROR TT_CreateFilterView(): Could not find table ''translation.%''...', tableName;
      RETURN 'ERROR: Could not find table ''translation..' || tableName || '''...';
    END IF;

    -- For whereInAttrList only, replace each comma inside two brackets with a special keyword that will be replaced with AND later
    whereInAttrList = regexp_replace(whereInAttrList, '(?<=\[.*\s*)(,)(?=\s*.*\])', ', CASFRI_AND,', 'g');

    -- Replace selectAttrList CASFRI attribute with their mapping attributes
    FOR mappingRec IN SELECT key, string_agg(from_att, ', ') attrs
                      FROM TT_CreateMapping(schemaName, tableName, 1, tableName, 1)
                      WHERE TT_NotEmpty(from_att) AND key != 'inventory_id' AND key != 'layer'
                      GROUP BY key
    LOOP
       selectAttrList = regexp_replace(lower(selectAttrList), '\m' || mappingRec.key || '\M', mappingRec.attrs, 'g');
    END LOOP;

    -- Replace whereInAttrList and whereOutAttrList CASFRI attributes with their mapping attribute. only the 
    FOR mappingRec IN SELECT key, string_agg(from_att, ', ') attrs
                      FROM TT_CreateMapping(schemaName, tableName, 1, tableName, 1)
                      WHERE TT_NotEmpty(from_att) AND contributing AND key != 'inventory_id' AND key != 'layer'
                      GROUP BY key
    LOOP
       whereInAttrList = regexp_replace(lower(whereInAttrList), mappingRec.key || '\M', mappingRec.attrs, 'g');
       whereOutAttrList = regexp_replace(lower(whereOutAttrList), mappingRec.key || '\M', mappingRec.attrs, 'g');
    END LOOP;

     -- Loop through all the possible keywords building the list of attributes from attribute_dependencies and replacing them in the 3 provided lists of attributes
    FOREACH keyword IN ARRAY keywordArr LOOP
      -- Determine from which layer to grab the attributes
      layer = right(keyword, 1);
      IF NOT layer IN ('1', '2', '3', '4', '5', '6') THEN layer = '1'; END IF;
      
      -- Initialize the two attribute arrays, one for all of them and one for only contributing ones
      attArr = '{}';
      sigAttArr = '{}';
      
      -- Loop through all attribute_dependencies row mapping
      FOR mappingRec IN SELECT *
                        FROM TT_CreateMapping(schemaName, tableName, layer::int, tableName, layer::int)
                        WHERE TT_NotEmpty(from_att)
      LOOP
        -- Pick attributes corresponding to keywords
        IF ((keyword = 'lyr1' OR keyword = 'lyr2' OR keyword = 'lyr3') AND (mappingRec.key = 'species_1' OR mappingRec.key = 'species_2' OR mappingRec.key = 'species_3')) OR
           ((keyword = 'nfl1' OR keyword = 'nfl2' OR keyword = 'nfl3' OR 
             keyword = 'nfl4' OR keyword = 'nfl5' OR keyword = 'nfl6') AND (mappingRec.key = 'nat_non_veg' OR mappingRec.key = 'non_for_anth' OR mappingRec.key = 'non_for_veg')) OR
           ((keyword = 'dst1' OR keyword = 'dst2') AND (mappingRec.key = 'dist_type_1' OR mappingRec.key = 'dist_year_1' OR 
                                                        mappingRec.key = 'dist_ext_upper_1' OR mappingRec.key = 'dist_ext_lower_1' OR
                                                        mappingRec.key = 'dist_type_2' OR mappingRec.key = 'dist_year_2' OR 
                                                        mappingRec.key = 'dist_ext_upper_2' OR mappingRec.key = 'dist_ext_lower_2' OR
                                                        mappingRec.key = 'dist_type_3' OR mappingRec.key = 'dist_year_3' OR 
                                                        mappingRec.key = 'dist_ext_upper_3' OR mappingRec.key = 'dist_ext_lower_3')) OR
           (keyword = 'eco' AND (mappingRec.key = 'wetland_type' OR mappingRec.key = 'wet_veg_cover' OR mappingRec.key = 'wet_landform_mod' OR mappingRec.key = 'wet_local_mod'))
        THEN
          -- Append both attributes lists
          attArr = array_append(attArr, lower(mappingRec.from_att));
          sigAttArr = array_append(sigAttArr, CASE WHEN mappingRec.contributing THEN lower(mappingRec.from_att) ELSE NULL END);
        END IF;
      END LOOP;
      -- Convert the first list to a string
      attList = array_to_string(TT_ArrayDistinct(attArr, TRUE), ', ');

      -- Warn if some keywords do not correspond to any attribute
      IF strpos(lower(selectAttrList), keyword) != 0 AND attList IS NULL THEN
        RAISE NOTICE 'WARNING TT_CreateFilterView(): No attributes for keyword ''%'' found in table ''%.%''...', keyword, schemaName, tableName;
      END IF;

      -- Replace keywords with attributes
      selectAttrList = regexp_replace(lower(selectAttrList), keyword || '\s*(,)?\s*', CASE WHEN attList != '' THEN attList || '\1' ELSE '' END, 'g');
      -- Standardise commas and spaces
      selectAttrList = regexp_replace(selectAttrList, '\s*,\s*', ', ', 'g');

      -- Convert the second list to a string
      sigAttList = array_to_string(TT_ArrayDistinct(sigAttArr, TRUE), ', ');
      
      -- Warn if some whereInAttrList keywords do not correspond to any attribute
      IF strpos(lower(whereInAttrList), keyword) != 0 AND sigAttList IS NULL THEN
        RAISE NOTICE 'WARNING TT_CreateFilterView(): No attributes for keyword ''%'' found in table ''%.%''...', keyword, schemaName, tableName;
      END IF;

      -- Replace keywords with attributes
      whereInAttrList = regexp_replace(lower(whereInAttrList), '\s*(,)?\s*(casfri_and)?\s*(,)?\s*' || keyword || '\s*(,)?\s*', CASE WHEN sigAttList != '' THEN '\1\2\3' || sigAttList || '\4' ELSE '' END, 'g');
      -- Standardise commas and spaces
      whereInAttrList = regexp_replace(whereInAttrList, '\s*,\s*', ', ', 'g');
      -- Remove remaining empty brackets
      whereInAttrList = regexp_replace(whereInAttrList, '\[\s*\],?\s*', '', 'g');

      -- Warn if some whereOutAttrList keywords do not correspond to any attribute
      IF strpos(lower(whereOutAttrList), keyword) != 0 AND sigAttList IS NULL THEN
        RAISE NOTICE 'WARNING TT_CreateFilterView(): No attributes for keyword ''%'' found in table ''%.%''...', keyword, schemaName, tableName;
      END IF;
      
      -- Replace keywords with attributes
      whereOutAttrList = regexp_replace(lower(whereOutAttrList), keyword || '\s*(,)?\s*', CASE WHEN attList != '' THEN attList || '\1' ELSE '' END, 'g');
      -- Standardise commas and spaces
      whereOutAttrList = regexp_replace(whereOutAttrList, '\s*,\s*', ', ', 'g');
    END LOOP;

    -- Parse and validate the list of provided attributes against the list of attribute in the table
    sourceTableCols = TT_TableColumnNames(schemaName, tableName);

    -- selectAttrArr
    selectAttrArr = TT_ArrayDistinct(regexp_split_to_array(selectAttrList, '\s*,\s*'), TRUE, TRUE);
    FOREACH attName IN ARRAY coalesce(selectAttrArr, '{}'::text[]) LOOP
      IF NOT attName = ANY (sourceTableCols) THEN
        RAISE NOTICE 'WARNING TT_CreateFilterView(): ''selectAttrList'' parameter''s ''%'' attribute not found in table ''%.%''...', attName, schemaName, tableName;
        --RETURN 'ERROR TT_CreateFilterView(): ''selectAttrList'' parameter''s ''' || attName || ''' attribute not found in table ''' || schemaName || '.' || tableName || '''...';
      END IF;
    END LOOP;

    -- Build the selectAttrArr string
    IF selectAttrArr IS NULL OR cardinality(selectAttrArr) = 0 THEN
      selectAttrList = '*';
    ELSE
      selectAttrList = array_to_string(selectAttrArr, ', ');
    END IF;

    -- whereInAttrArr
    whereInAttrArr = CASE WHEN whereInAttrList = '' THEN '{}'::text[] 
                          ELSE regexp_split_to_array(whereInAttrList, '\s*,\s*') END;
    whereInAttrList = '';
    IF 'casfri_and' = ANY (whereInAttrArr) THEN
      indentStr = '        ';
    ELSE
      indentStr = '      ';
    END IF;
    FOREACH attName IN ARRAY coalesce(whereInAttrArr, '{}'::text[]) LOOP
      attCount = attCount + 1;
      IF left(attName, 1) = '[' AND 'casfri_and' = ANY (whereInAttrArr) THEN 
        IF attCount != 1 THEN
          whereInAttrList = whereInAttrList || chr(10) || '       ' || 'OR' || chr(10) || indentStr;
        END IF;        
        whereInAttrList = whereInAttrList || '(';
        attCount = 1;
      END IF;
      trimmedAttName = rtrim(ltrim(attName, '['), ']');
      IF trimmedAttName = 'casfri_and' THEN
        whereInAttrList = whereInAttrList || ')'  || chr(10) || '       ' || 'AND'  || chr(10) || indentStr || '(';
        attCount = 0;
      ELSE
        IF NOT trimmedAttName = ANY (sourceTableCols) THEN
          RAISE NOTICE 'WARNING TT_CreateFilterView(): ''whereInAttrList'' parameter''s ''%'' attribute not found in table ''%.%''. Removed from the WHERE clause...', trimmedAttName, schemaName, tableName;
          --RETURN 'ERROR TT_CreateFilterView(): ''whereInAttrList'' parameter''s ''' || trimmedAttName || ''' attribute not found in table ''' || schemaName || '.' || tableName || '''...';
        ELSE
          IF attCount != 1 THEN
            whereInAttrList = whereInAttrList || ' OR ' || chr(10) || indentStr;
          END IF;
          whereInAttrList = whereInAttrList || '(TT_NotEmpty(' || trimmedAttName || '::text) AND ' || trimmedAttName || '::text != ''0'')';
        END IF;
      END IF;
      IF right(attName, 1) = ']' AND 'casfri_and' = ANY (whereInAttrArr) THEN
        whereInAttrList = whereInAttrList || ')' || chr(10) || '      ';
      END IF;
    END LOOP;

    -- whereOutAttrArr
    whereOutAttrArr = TT_ArrayDistinct(regexp_split_to_array(whereOutAttrList, '\s*,\s*'), TRUE, TRUE);

    -- Build the whereOutAttrArr string
    FOREACH attName IN ARRAY coalesce(whereOutAttrArr, '{}'::text[]) LOOP
      IF NOT attName = ANY (sourceTableCols) THEN
        RAISE NOTICE 'WARNING TT_CreateFilterView(): ''whereOutAttrList'' parameter''s ''%'' attribute not found in table ''%.%''. Removed from the WHERE clause...', attName, schemaName, tableName;
        --RETURN 'ERROR TT_CreateFilterView(): ''whereOutAttrList'' parameter''s ''' || attName || ''' attribute not found in table ''' || schemaName || '.' || tableName || '''...';
      ELSE
        whereOutAttrStrArr = array_append(whereOutAttrStrArr, '(TT_NotEmpty(' || attName || '::text) AND ' || attName || '::text != ''0'')');
      END IF;
    END LOOP;
    whereOutAttrList = array_to_string(whereOutAttrStrArr, ' OR ' || chr(10) || indentStr);

    -- Construct the name of the VIEW
    viewName = fullTableName || coalesce('_' || viewNamesuffix, '_' || (random()*100)::int::text);

    -- Build the VIEW query
    queryStr = 'DROP VIEW IF EXISTS ' || viewName || ' CASCADE;' || chr(10) ||
               'CREATE OR REPLACE VIEW ' || viewName || ' AS' || chr(10) ||
               'SELECT ' || selectAttrList || chr(10) ||
               'FROM ' || fullTableName;
               
    IF whereInAttrList != '' OR whereOutAttrList != '' THEN
      queryStr = queryStr || chr(10) || 'WHERE ';
      IF whereInAttrList != '' AND whereOutAttrList != '' THEN
        queryStr = queryStr || '(';
      END IF;
      IF whereInAttrList != '' THEN
        queryStr = queryStr || whereInAttrList;
      END IF;
      IF whereInAttrList != '' AND whereOutAttrList != '' THEN
        queryStr = queryStr || ')' || chr(10) || '      AND ';
      END IF;
      IF whereOutAttrList != '' THEN
        queryStr = queryStr || 'NOT' || chr(10) || '       (' || whereOutAttrList || ')';
      END IF;
    END IF;
    queryStr = queryStr  || ';';

    -- Create the VIEW
    RAISE NOTICE 'TT_CreateFilterView(): Creating VIEW ''%''...', viewName;
    EXECUTE queryStr;
    
    -- Display the approximate number of row returned by the view
    nb = TT_CountEstimate('SELECT 1 FROM ' || viewName);
    IF nb < 2 THEN
      RAISE NOTICE 'WARNING TT_CreateFilterView(): VIEW ''%'' should return 0 rows...', viewName; 
    ELSIF nb < 1000 THEN
       RAISE NOTICE 'TT_CreateFilterView(): VIEW ''%'' should return % rows...', viewName, nb;
    ELSE
      RAISE NOTICE 'TT_CreateFilterView(): VIEW ''%'' should return at least 1000 rows or more...', viewName;
    END IF;
    RETURN queryStr;
  END; 
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_StackTranslationRules 
-- 
-- List all target_attribute rules vertically for easy comparison for the provided
-- translation tables or for the 'cas', 'lyr', 'nfl', 'dst', 'eco' or 'geo' keywords.
--
-- e.g.
-- SELECT * FROM TT_StackTranslationRules('translation', 'ab06_avi01_nfl, ab16_avi01_nfl');
--
-- SELECT * FROM TT_StackTranslationRules('nfl');
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_StackTranslationRules(text, text);
CREATE OR REPLACE FUNCTION TT_StackTranslationRules(
  schemaName text,
  transTableList text DEFAULT NULL
)
RETURNS TABLE (ttable text,
               rule_id int,
               target_attribute text, 
               target_attribute_type text, 
               validation_rules text,
               translation_rules text
) AS $$
  DECLARE
    query text = '';
    attrPart text = '';
    wherePart text = 'WHERE ';
    attributeArr text[];
    attributeArrOld text[];
    tTableArr text[];
    tTable text;
    attr text;
    nb int = 1;
    nb2 int = 1;
  BEGIN
    -- Handle when only one keyword parameter is provided instead of a schema and a table
    IF transTableList IS NULL AND lower(schemaName) IN ('cas', 'lyr', 'nfl', 'dst', 'eco', 'geo') THEN
      transTableList = 'ab_avi01_' || lower(schemaName) || ', ' || 
                       'nt_fvi01_' || lower(schemaName) || ', ' || 
                       'nb_nbi01_' || lower(schemaName) || ', ' || 
                       'bc_vri01_' || lower(schemaName) || ', ' || 
                       'on_fim02_' || lower(schemaName) || ', ' || 
                       'sk_utm01_' || lower(schemaName) || ', ' || 
                       'yt_yvi01_' || lower(schemaName);
      schemaName = 'translation';
                       
    END IF;
    
    -- Parse the list of translation tables
    tTableArr = regexp_split_to_array(transTableList, '\s*,\s*');

    nb = 1;
    query = 'SELECT ttable, rule_id, target_attribute, target_attribute_type, validation_rules, translation_rules FROM (' || chr(10);
    FOREACH tTable IN ARRAY tTableArr LOOP
      IF NOT TT_TableExists(schemaName, tTable) THEN
        RAISE EXCEPTION 'TT_StackTranslationRules() ERROR: Table ''%.%'' does not exist...', schemaName, tTable;
      END IF;
      
      -- Build a list of all target attributes for this table
      EXECUTE 'SELECT array_agg(target_attribute)' ||
              ' FROM ' || TT_FullTableName(schemaName, tTable) 
      INTO attributeArr;
      IF nb > 1 AND attributeArr != attributeArrOld THEN
        RAISE EXCEPTION 'TT_StackTranslationRules() ERROR: Table ''%.%'' does not have the same target attributes as the previous table in the list...', schemaName, tTable;
      END IF;
      attributeArrOld = attributeArr;
      
      IF nb = 1 THEN
        -- Create the attribute part of the query which will be repeated for each translation table
        nb2 = 1;
        FOREACH attr IN ARRAY attributeArr LOOP
          wherePart = wherePart || 'target_attribute = ''' || attr || '''';
          IF nb2 < cardinality(attributeArr) THEN
            wherePart = wherePart || ' OR ';
          END IF;
          nb2 = nb2 + 1;
        END LOOP;
      END IF;

      IF nb > 1 THEN
        query = query || 'UNION ALL' || chr(10);
      END IF;
      query = query || 'SELECT ' || nb || ' nb, ''' || tTable || ''' ttable,' || chr(10) ||
                       '        rule_id::int,' || chr(10) ||
                       '        target_attribute::text,' || chr(10) ||
                       '        target_attribute_type::text,' || chr(10) ||
                       '        validation_rules::text,' || chr(10) ||
                       '        translation_rules::text' || chr(10) ||
                       'FROM ' || TT_FullTableName(schemaName, tTable) || chr(10) ||
                       wherePart;
      IF nb < cardinality(tTableArr) THEN
        query = query || chr(10);
      END IF;
      nb = nb + 1;
    END LOOP;
    query = query  || chr(10) || ') foo' || chr(10) || 'ORDER BY rule_id, nb;';
    RETURN QUERY EXECUTE query;
  END
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------

-------------------------------------------------------
-- Create a function that create the constraint in a non 
-- blocking way and return TRUE or FALSE upon succesfull completion
-------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_AddConstraint(name, name, text, text[], text[]);
CREATE OR REPLACE FUNCTION TT_AddConstraint(
  schemaName name,
  tableName name,
  cType text,
  args text[],
  lookup_vals text[] DEFAULT NULL
)
RETURNS RECORD AS $$ 
  DECLARE
    acceptableCType text[] = ARRAY['PK', 'FK', 'NOTNULL', 'CHECK', 'LOOKUP', 'LOOKUPTABLE'];
    nbArgs int[] = ARRAY[1, 4, 1, 2, 2, 2];
    queryStr text;
  BEGIN
    cType = upper(cType);
    BEGIN
      IF NOT cType = ANY (acceptableCType) THEN
        RAISE EXCEPTION 'TT_AddConstraint(): ERROR invalid constraint type (%)...', cType;
      END IF;
      IF cardinality(args) != nbArgs[array_position(acceptableCType, cType)] THEN
        RAISE EXCEPTION 'TT_AddConstraint(): ERROR invalid number of arguments (%). Should be %...', cardinality(args), nbArgs[array_position(acceptableCType, cType)];
      END IF;
      queryStr = 'ALTER TABLE ' || schemaName || '.' || tableName || chr(10); 
      CASE WHEN cType = 'PK' THEN
             queryStr = 'SELECT constraint_name FROM information_schema.table_constraints
                         WHERE table_schema = ''' || schemaName || '''
                         AND table_name = ''' || tableName || '''
                         AND constraint_type = ''PRIMARY KEY'';';
RAISE NOTICE '11 queryStr = %', queryStr;
             EXECUTE queryStr INTO queryStr;
RAISE NOTICE '22 queryStr = %', queryStr;
             IF queryStr IS NULL THEN
               queryStr = '';
             ELSE 
               queryStr = 'ALTER TABLE ' || schemaName || '.' || tableName || chr(10) ||
                        'DROP CONSTRAINT IF EXISTS ' || queryStr || ' CASCADE;' || chr(10);
             END IF;
             queryStr = queryStr || 'ALTER TABLE ' || schemaName || '.' || tableName || chr(10) ||
                                    'ADD PRIMARY KEY (' || args[1] || ');';
RAISE NOTICE '33 queryStr = %', queryStr;

           WHEN cType = 'FK' THEN
             queryStr = queryStr || 'ADD FOREIGN KEY (' || args[1] || ') ' ||
                                    'REFERENCES ' || args[2] || '.' || args[3] || ' (' || args[4] || ') MATCH FULL;';
           
           WHEN cType = 'NOTNULL' THEN
             queryStr = queryStr || 'ALTER COLUMN ' || args[1] || ' SET NOT NULL;';
           
           WHEN cType = 'CHECK' THEN
             queryStr = queryStr || 'DROP CONSTRAINT IF EXISTS ' || args[1] || ';' || chr(10) ||
                                    'ALTER TABLE ' || schemaName || '.' || tableName || chr(10) ||
                                    'ADD CONSTRAINT ' || args[1] || chr(10) ||
                                    'CHECK (' || args[2] || ');';

           WHEN cType = 'LOOKUP' THEN
             queryStr = 'DROP TABLE IF EXISTS ' || args[1] || '.' || args[2] || '_codes CASCADE;' || chr(10) || chr(10) ||

                        'CREATE TABLE ' || args[1] || '.' || args[2] || '_codes AS' || chr(10) ||
                        'SELECT * FROM (VALUES (''' || array_to_string(lookup_vals, '''), (''') || ''')) AS t(code);' || chr(10) || chr(10) ||

                        'ALTER TABLE ' || args[1] || '.' || args[2] || '_codes' || chr(10) ||
                        'ADD PRIMARY KEY (code);' || chr(10) || chr(10) ||

                        'ALTER TABLE ' || schemaName || '.' || tableName || chr(10) ||
                        'DROP CONSTRAINT IF EXISTS ' || tableName || '_' || args[2] || '_fk;' || chr(10) || chr(10) ||

                        'ALTER TABLE ' || schemaName || '.' || tableName || chr(10) ||
                        'ADD CONSTRAINT ' || tableName || '_' || args[2] || '_fk' || chr(10) ||
                        'FOREIGN KEY (' || args[2] || ')' || chr(10) ||
                        'REFERENCES ' || args[1] || '.' || args[2] || '_codes (code);';
           ELSE
             RAISE EXCEPTION 'TT_AddConstraint(): ERROR invalid constraint type (%)...', cType;
      END CASE;
      RAISE NOTICE 'TT_AddConstraint(): EXECUTING ''%''...', queryStr; 
      EXECUTE queryStr;
      RETURN (TRUE, queryStr);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '%', SQLERRM;
      RETURN (FALSE, queryStr);
    END;
  END; 
$$ LANGUAGE plpgsql VOLATILE;
-------------------------------------------------------------------------------
-- Overwrite the TT_DefaultProjectErrorCode() function to define default error 
-- codes for these helper functions...
-------------------------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_DefaultProjectErrorCode(text, text);
CREATE OR REPLACE FUNCTION TT_DefaultProjectErrorCode(
  rule text, 
  targetType text
)
RETURNS text AS $$
  DECLARE
    rulelc text = lower(rule);
    targetTypelc text = lower(targetType);
  BEGIN
    IF targetTypelc = 'integer' OR targetTypelc = 'int' OR targetTypelc = 'double precision' THEN 
      RETURN CASE WHEN rulelc = 'projectrule1' THEN '-9999'
                  WHEN rulelc = 'tie01_2layer_age_codes_validation' THEN '-9997'
                  WHEN rulelc = 'tie01_not_etage_notnull_validation' THEN '-8888'
                  WHEN rulelc = 'tie01_not_etage_layer1_validation' THEN '-8887'
                  WHEN rulelc = 'tie01_not_etage_dens_layers_validation' THEN '-8887'
                  WHEN rulelc = 'sk_utm01_species_percent_validation' THEN '-9997'
                  ELSE TT_DefaultErrorCode(rulelc, targetTypelc) END;
    ELSIF targetTypelc = 'geometry' THEN
      RETURN CASE WHEN rulelc = 'projectrule1' THEN NULL
                  ELSE TT_DefaultErrorCode(rulelc, targetTypelc) END;
    ELSE
      RETURN CASE WHEN rulelc = 'nbi01_wetland_validation' THEN 'NOT_APPLICABLE'
                  WHEN rulelc = 'vri01_nat_non_veg_validation' THEN 'INVALID_VALUE'
                  WHEN rulelc = 'vri01_non_for_anth_validation' THEN 'INVALID_VALUE'
                  WHEN rulelc = 'vri01_non_for_veg_validation' THEN 'INVALID_VALUE'
                  WHEN rulelc = 'yvi01_nat_non_veg_validation' THEN 'NOT_IN_SET'
                  WHEN rulelc = 'yvi01_nfl_soil_moisture_validation' THEN 'NOT_APPLICABLE'
                  WHEN rulelc = 'avi01_stand_structure_validation' THEN 'NOT_APPLICABLE'
                  WHEN rulelc = 'fvi01_stand_structure_validation' THEN 'NOT_APPLICABLE'
                  ELSE TT_DefaultErrorCode(rulelc, targetTypelc) END;
    END IF;
  END;
$$ LANGUAGE plpgsql VOLATILE;

-------------------------------------------------------------------------------
-- Begin Validation Function Definitions...
-------------------------------------------------------------------------------
-- TT_vri01_non_for_veg_validation(text, text, text, text)
--
-- Check the correct combination of values exists based on the translation rules.
-- If not return FALSE
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_non_for_veg_validation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_non_for_veg_validation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  bclcs_level_4 text,
  non_productive_descriptor_cd text
)
RETURNS boolean AS $$
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL THEN
      IF land_cover_class_cd_1 IN ('BL', 'BM', 'BY', 'HE', 'HF', 'HG', 'SL', 'ST') THEN
        RETURN TRUE;
      END IF;
    END IF;
    
    IF inventory_standard_cd IN ('V', 'I') AND bclcs_level_4 IS NOT NULL THEN
      IF bclcs_level_4 IN ('BL', 'BM', 'BY', 'HE', 'HF', 'HG', 'SL', 'ST') THEN
        RETURN TRUE;
      END IF;
    END IF;
    
    IF inventory_standard_cd='F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd IN ('AF', 'M', 'NPBR', 'OR') THEN
        RETURN TRUE;
      END IF;
    END IF;

    IF inventory_standard_cd='F' AND bclcs_level_4 IS NOT NULL THEN
      IF bclcs_level_4 IN ('BL', 'BM', 'BY', 'HE', 'HF', 'HG', 'SL', 'ST') THEN
        RETURN TRUE;
      END IF;
    END IF;
    RETURN FALSE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_nat_non_veg_validation(text, text, text, text, text)
--
-- Check the correct combination of values exists based on the translation rules.
-- If not return FALSE
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_nat_non_veg_validation(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_nat_non_veg_validation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  bclcs_level_4 text,
  non_productive_descriptor_cd text,
  non_veg_cover_type_1 text
)
RETURNS boolean AS $$
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND non_veg_cover_type_1 IS NOT NULL THEN
      IF non_veg_cover_type_1 IN ('BE', 'BI', 'BR', 'BU', 'CB', 'DW', 'ES', 'GL', 'LA', 'LB', 'LL', 'LS', 'MN', 'MU', 'OC', 'PN', 'RE', 'RI', 'RM', 'RS', 'TA') THEN
        RETURN TRUE;
      END IF;
    END IF;

    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL THEN
      IF land_cover_class_cd_1 IN ('BE', 'BI', 'BR', 'BU', 'CB', 'EL', 'ES', 'GL', 'LA', 'LB', 'LL', 'LS', 'MN', 'MU', 'OC', 'PN', 'RE', 'RI', 'RM', 'RO', 'RS', 'SI', 'TA') THEN
        RETURN TRUE;
      END IF;
    END IF;
    
    IF inventory_standard_cd IN ('V', 'I') AND bclcs_level_4 IS NOT NULL THEN
      IF bclcs_level_4 IN ('EL', 'RO', 'SI') THEN
        RETURN TRUE;
      END IF;
    END IF;
    
    IF inventory_standard_cd='F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd IN ('A', 'CL', 'G', 'ICE', 'L', 'MUD', 'R', 'RIV', 'S', 'SAND', 'TIDE') THEN
        RETURN TRUE;
      END IF;
    END IF;

    IF inventory_standard_cd='F' AND bclcs_level_4 IS NOT NULL THEN
      IF bclcs_level_4 IN ('EL', 'RO', 'SI') THEN
        RETURN TRUE;
      END IF;
    END IF;
    RETURN FALSE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_non_for_anth_validation(text, text, text, text)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_non_for_anth_validation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_non_for_anth_validation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  non_productive_descriptor_cd text,
  non_veg_cover_type_1 text
)
RETURNS boolean AS $$
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND non_veg_cover_type_1 IS NOT NULL THEN
      IF non_veg_cover_type_1 IN ('AP', 'GP', 'MI', 'MZ', 'OT', 'RN', 'RZ', 'TZ', 'UR') THEN
        RETURN TRUE;
      END IF;
    END IF;
        
    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL THEN
      IF land_cover_class_cd_1 IN ('AP', 'GP', 'MI', 'MZ', 'OT', 'RN', 'RZ', 'TZ', 'UR') THEN
        RETURN TRUE;
      END IF;
    END IF;
        
    IF inventory_standard_cd='F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd IN ('C', 'GR', 'P', 'U') THEN
        RETURN TRUE;
      END IF;
    END IF;    
    RETURN FALSE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_nbi01_wetland_code(text, text, text)
-------------------------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_wetland_code(text, text, text);
CREATE OR REPLACE FUNCTION TT_nbi01_wetland_code(
  wc text,
  vt text,
  im text
)
RETURNS text AS $$
  SELECT CASE
           WHEN wc='BO' AND vt='EV' AND im='BP' THEN 'BO-B'
           WHEN wc='FE' AND vt='EV' AND im='BP' THEN 'FO-B'
           WHEN wc='BO' AND vt='EV' AND im='DI' THEN 'BO--'
           WHEN wc='BO' AND vt='AW' AND im='BP' THEN 'BT-B'
           WHEN wc='BO' AND vt='OV' AND im='BP' THEN 'OO-B'
           WHEN wc='FE' AND vt='EV' AND im IN ('MI', 'DI') THEN 'FO--'
           WHEN wc='FE' AND vt='OV' AND im='MI' THEN 'OO--'
           WHEN wc='BO' AND vt='FS' THEN 'BTNN'
           WHEN wc='BO' AND vt='SV' THEN 'BONS'
           WHEN wc='FE' AND vt IN ('FH', 'FS') THEN 'FTNN'
           WHEN wc='FE' AND vt IN ('AW', 'SV') THEN 'FONS'
           WHEN wc='FW' AND im='BP' THEN 'OF-B'
           WHEN wc='FE' AND vt='EV' THEN 'FO--'
           WHEN wc IN ('FE', 'BO') AND vt='OV' THEN 'OO--'
           WHEN wc IN ('FE', 'BO') AND vt='OW' THEN 'O---'
           WHEN wc='BO' AND vt='EV' THEN 'BO--'
           WHEN wc='BO' AND vt='AW' THEN 'BT--'
           WHEN wc='AB' THEN 'OONN'
           WHEN wc='FM' THEN 'MONG'
           WHEN wc='FW' THEN 'STNN'
           WHEN wc='SB' THEN 'SONS'
           WHEN wc='CM' THEN 'MCNG'
           WHEN wc='TF' THEN 'TMNN'
           WHEN wc IN ('NP', 'WL') THEN 'W---'
           ELSE NULL
         END;
$$ LANGUAGE sql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_nbi01_wetland_validation(text, text, text, text)
--
-- Assign 4 letter wetland character code, then return true if the requested character (1-4)
-- is not null and not -.
--
-- e.g. TT_nbi01_wetland_validation(wt, vt, im, '1')
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_wetland_validation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_nbi01_wetland_validation(
  wc text,
  vt text,
  im text,
	ret_char_pos text
)
RETURNS boolean AS $$
  DECLARE
		wetland_code text;
  BEGIN
    PERFORM TT_ValidateParams('TT_nbi01_wetland_validation',
                              ARRAY['ret_char_pos', ret_char_pos, 'int']);
	wetland_code = TT_nbi01_wetland_code(wc, vt, im);

    -- return true or false
    IF wetland_code IS NULL OR substring(wetland_code from ret_char_pos::int for 1) = '-' THEN
      RETURN FALSE;
		END IF;
    RETURN TRUE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_tie01_2layer_age_codes_validation()
--
-- When num_of_layers is 2, do the 2 age codes from cl_age match the age codes in
-- sup_cl_age_et and inf_cl_age_et?
--
-- Also need to do this check when et_domi is EQU because in that case we don't know the dominant layer
-- and have to id it using the age code order.
--
-- e.g. TT_tie01_2layer_age_codes_validation()
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_2layer_age_codes_validation(text,text,text,text,text,text,text);
CREATE OR REPLACE FUNCTION TT_tie01_2layer_age_codes_validation(
  cl_age text,
  lookup_schema text,
  lookup_table text,
  in_etage text,
  et_domi text,
  sup_cl_age_et text,
  inf_cl_age_et text
)
RETURNS boolean AS $$
  DECLARE
		layer_1_age_code text;
    layer_2_age_code text;
    num_of_layers int;
  BEGIN
    PERFORM TT_ValidateParams('TT_tie01_2layer_age_codes_validation',
                              ARRAY['lookup_schema', lookup_schema, 'text',
                                   'lookup_table', lookup_table, 'text']);
	
    IF cl_age IS NOT NULL AND in_etage = 'O' THEN
      num_of_layers = TT_lookupInt(cl_age, lookup_schema, lookup_table, 'num_of_layers');
      
      IF num_of_layers = 2 THEN
        IF et_domi IS NULL OR et_domi = 'EQU' THEN        
          layer_1_age_code = TT_lookupText(cl_age, lookup_schema, lookup_table, 'layer_1_age'::text);
          layer_2_age_code = TT_lookupText(cl_age, lookup_schema, lookup_table, 'layer_2_age'::text);

          -- if layer 1 doesn't match either value, return FALSE
          IF layer_1_age_code NOT IN (sup_cl_age_et, inf_cl_age_et) THEN
            RETURN FALSE;
          END IF;

          -- if layer 1 matches one of the values, check layer 2 matches the other
          IF layer_1_age_code = sup_cl_age_et THEN
            IF layer_2_age_code = inf_cl_age_et THEN
              RETURN TRUE;
            ELSE
              RETURN FALSE;
            END IF;
          END IF;

          -- if layer 1 matches one of the values, check layer 2 matches the other
          IF layer_1_age_code = inf_cl_age_et THEN
            IF layer_2_age_code = sup_cl_age_et THEN
              RETURN TRUE;
            ELSE
              RETURN FALSE;
            END IF;
          END IF;
        END IF;
      END IF;
    END IF;
    
    RETURN TRUE; -- this rule only applies in etage table where cl_age has 2 layers defined, and et_domi ir null or EQU. For all other cases return TRUE to skip this validation.
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_tie01_not_etage_notnull_validation()
--
-- in_etage text
-- check_att text (cl_dens or cl_haut)
--
-- When in_etage = 'N', check cl_dens and cl_height are not null
--
-- e.g. TT_tie01_not_etage_notnull_validation(in_etage, check_att)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_not_etage_notnull_validation(text,text);
CREATE OR REPLACE FUNCTION TT_tie01_not_etage_notnull_validation(
  in_etage text,  
  check_att text
)
RETURNS boolean AS $$		
  BEGIN

    IF in_etage = 'N' THEN
      RETURN TT_NotNull(check_att);
    END IF;
    
    RETURN TRUE; -- if row is in_etage = 'O', return true.
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_tie01_not_etage_layer1_validation()
--
-- in_etage text
-- layer text
--
-- When in_etage = 'N', check layer requested = 1, otherwise return FALSE
--
-- e.g. TT_tie01_not_etage_layer1_validation(in_etage, layer)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_not_etage_layer1_validation(text,text);
CREATE OR REPLACE FUNCTION TT_tie01_not_etage_layer1_validation(
  in_etage text,  
  layer text
)
RETURNS boolean AS $$		
  DECLARE
    _layer int;
  BEGIN
    
    _layer = layer::int;
    
    IF in_etage = 'N' THEN
      IF NOT _layer = 1 THEN
        RETURN FALSE;
      END IF;
    END IF;
    
    RETURN TRUE; -- if row is in_etage = 'O', or layer = 1, return true.
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_tie01_not_etage_dens_layers_validation()
--
-- in_etage text
-- cl_age text
-- lookup_schema text,
-- lookup_table text,
--
-- When in_etage = 'N', for density, check if num_of_layer > 1, if so return FALSE
--
-- e.g. TT_tie01_not_etage_dens_layers_validation(in_etage, layer)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_not_etage_dens_layers_validation(text,text,text,text);
CREATE OR REPLACE FUNCTION TT_tie01_not_etage_dens_layers_validation(
  in_etage text,  
  cl_age text,
  lookup_schema text,
  lookup_table text  
)
RETURNS boolean AS $$		
  DECLARE
    num_of_layers int;
  BEGIN
    
    IF in_etage = 'N' THEN
      num_of_layers = TT_lookupInt(cl_age, lookup_schema, lookup_table, 'num_of_layers');
      IF num_of_layers = 2 THEN
        RETURN FALSE;
      END IF;
    END IF;
    
    RETURN TRUE; -- if row is in_etage = 'O', or layer = 1, return true.
  END;
$$ LANGUAGE plpgsql STABLE;
-------------------------------------------------------------------------------
-- TT_yvi01_nat_non_veg_validation()
--
-- type_lnd text
-- class text
-- landpos text
--
-- e.g. TT_yvi01_nat_non_veg_validation(type_lnd, class, landpos)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_yvi01_nat_non_veg_validation(text,text,text);
CREATE OR REPLACE FUNCTION TT_yvi01_nat_non_veg_validation(
  type_lnd text,
  class_ text,
  landpos text
)
RETURNS boolean AS $$		
  BEGIN
    IF type_lnd IN('NW', 'NS', 'NE') THEN
      IF landpos = 'A' THEN
        RETURN TRUE;
      END IF;
      
      IF class_ IN('R','L','RS','E','S','B','RR') THEN
        RETURN TRUE;
      END IF;
    END IF;
    RETURN FALSE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_yvi01_nfl_soil_moisture_validation()
--
-- type_lnd text
-- class_ text
-- cl_mod text
-- landpos text
--
-- Only want to translate soil moisture in NFL table if the row is either non_for_veg or
-- nat_non_veg = EX (burned or exposed land).
-- e.g. TT_yvi01_nfl_soil_moisture_validation(type_land, class_, cl_mod, landpos)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_yvi01_nfl_soil_moisture_validation(text,text,text,text);
CREATE OR REPLACE FUNCTION TT_yvi01_nfl_soil_moisture_validation(
  type_lnd text,
  class_ text,
  cl_mod text,
  landpos text
)
RETURNS boolean AS $$		
  BEGIN
    
    -- If row has non_for_veg attribute, return true
    IF type_lnd = 'VN' THEN
      IF class_ IN('S','H','C','M') THEN
        IF TT_yvi01_non_for_veg_translation(type_lnd, class_, cl_mod) IS NOT NULL THEN
          RETURN TRUE;
        END IF;
      END IF;
    END IF;
    
    -- If row has nat_non_veg attribute of EX, return true
    IF type_lnd IN('NW','NS','NE') THEN
      IF TT_yvi01_nat_non_veg_validation(type_lnd, class_, landpos) THEN
        IF TT_yvi01_nat_non_veg_translation(type_lnd, class_, landpos) = 'EXPOSED_LAND' THEN
          RETURN TRUE;
        END IF;
      END IF;
    END IF;
    
    RETURN FALSE;
      
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------
-- TT_avi01_stand_structure_validation(text, text, text, text)
--
-- stand_structure text
-- nfl_l1_1 text
-- nfl_l1_2 text
-- nfl_l1_3 text
-- nfl_l1_4 text
--
-- Catch the cases where stand structure will be NOT_APPLICABLE because row is NFL.
-- Will be every row where overstory attributes are NFL. Except those
-- cases where stand structure is Horizontal.
-- Overstory species should always be absent when there is overstory NFL.
-- If overstory is NFL then understory should not have sp1, unless stand structure is Horizontal.
-- e.g. TT_avi01_stand_structure_validation(nfl_l1_1, nfl_l1_2, nfl_l1_2, stand_structure)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_avi01_stand_structure_validation(text,text,text, text, text);
CREATE OR REPLACE FUNCTION TT_avi01_stand_structure_validation(
  stand_structure text,
  nfl_l1_1 text,
  nfl_l1_2 text,
  nfl_l1_3 text,
  nfl_l1_4 text
)
RETURNS boolean AS $$		
  BEGIN
    -- if stand structure is Horozontal, always return true
    IF stand_structure IN ('H', 'h') THEN
      RETURN TRUE;
    END IF;
    
    -- if overstory species is NFL (and stand structure not H), return FALSE 
    IF tt_notEmpty(nfl_l1_1) OR tt_notEmpty(nfl_l1_2) OR tt_notEmpty(nfl_l1_3) OR tt_notEmpty(nfl_l1_4) THEN
      RETURN FALSE;
    END IF;    
    
    -- other cases return true
    RETURN TRUE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------
-- TT_fvi01_stand_structure_validation(text, text)
--
-- stand_structure text
-- nfl text
--
-- Catch the cases where stand structure will be NOT_APPLICABLE because stand is
-- not horizontal and there is no species info.
--
-- e.g. TT_fvi01_stand_structure_validation(stand_structure, species_1_layer1, species_2_layer1, species_3_layer1, species_4_layer1, species_1_layer2, species_2_layer2, species_3_layer2, species_4_layer2)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_fvi01_stand_structure_validation(text,text,text,text,text,text,text);
CREATE OR REPLACE FUNCTION TT_fvi01_stand_structure_validation(
  stand_structure text,
  species_1_layer1 text, 
  species_2_layer1 text, 
  species_3_layer1 text,
  species_1_layer2 text,
  species_2_layer2 text,
  species_3_layer2 text
)
RETURNS boolean AS $$		
  BEGIN
    -- if stand structure is Horozontal, always return true
    IF stand_structure IN ('H', 'h') THEN
      RETURN TRUE;
    END IF;
    
    -- if any species info, return TRUE 
    IF tt_notEmpty(species_1_layer1) OR tt_notEmpty(species_2_layer1) OR tt_notEmpty(species_3_layer1)
     OR tt_notEmpty(species_1_layer2) OR tt_notEmpty(species_2_layer2) OR tt_notEmpty(species_3_layer2) THEN
      RETURN TRUE;
    END IF;    
    
    -- other cases return false
    RETURN FALSE;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_sk_utm01_species_percent_validation(text, text, text, text, text)
--
-- sp10 text
-- sp11 text
-- sp12 text
-- sp20 text
-- sp21 text
--
-- Checks the combination of hardwood and softwood species is valid and in one of the 
-- expected codes used in the translation function.
--
-- Codes the polygon being processed based on the combination of hardwood and
-- softwood species in each column.
-- e.g. concatenates in order either H for hardwood, S for softwood or - for nothing
-- into a 5 character string such as S----
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_sk_utm01_species_percent_validation(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_sk_utm01_species_percent_validation(
  sp10 text,
  sp11 text,
  sp12 text,
  sp20 text,
  sp21 text
)
RETURNS boolean AS $$
  DECLARE
    hardwoods text[]; -- list of harwood species codes
    softwoods text[]; -- list of softwood species codes
    ft10 text; -- assigns hardwood or softwood forest type
    ft11 text;
    ft12 text;
    ft20 text;
    ft21 text;
    ft_concat text; -- concatenates the ft values.
  BEGIN
    
    -- assign hardwood and softwood groups
    softwoods = ARRAY['WS','BS','JP','BF','TL','LP'];
    hardwoods = ARRAY['GA','TA','BP','WB','WE','MM','BO'];
    
    -- assign forest type variables
    IF sp10 = ANY(hardwoods) THEN ft10 = 'H';
    ELSIF sp10 = ANY(softwoods) THEN ft10 = 'S';
    ELSE ft10 = '-';
    END IF;
    
    IF sp11 = ANY(hardwoods) THEN ft11 = 'H';
    ELSIF sp11 = ANY(softwoods) THEN ft11 = 'S';
    ELSE ft11 = '-';
    END IF;
    
    IF sp12 = ANY(hardwoods) THEN ft12 = 'H';
    ELSIF sp12 = ANY(softwoods) THEN ft12 = 'S';
    ELSE ft12 = '-';
    END IF;
    
    IF sp20 = ANY(hardwoods) THEN ft20 = 'H';
    ELSIF sp20 = ANY(softwoods) THEN ft20 = 'S';
    ELSE ft20 = '-';
    END IF;
    
    IF sp21 = ANY(hardwoods) THEN ft21 = 'H';
    ELSIF sp21 = ANY(softwoods) THEN ft21 = 'S';
    ELSE ft21 = '-';
    END IF;

    -- assign forest type code
    ft_concat = ft10 || ft11 || ft12 || ft20 || ft21;
    
    -- Check code is in the expected list based on source data with valid entries
    RETURN ft_concat = ANY(ARRAY['H----', 'H--S-', 'H--SS', 'HH---', 'HH-S-', 'HH-SS', 'HHH--', 'HHHS-', 'HHHSS', 'HS-S-', 'S----', 'S--H-', 'S--HH', 'SS---', 'SS-H-', 'SS-HH', 'SS-S-', 'SSS--', 'SSSH-', 'SSSHH', 'HS---', 'SH---']);

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- ROW_TRANSLATION_RULE Function Definitions...
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- TT_HasNFLInfo(text, text, text)
--
-- inventory_id
-- filter_attributes text - string list of nfl attributes to filter by ('non_for_veg', 'non_for_anth', 'nat_non_veg')
-- source_vals text - string list of the source values needed to run the filtering helper functions 
-- 
-- Only called in ROW_TRANSLATION_RULE.
-- For the requested inventory_id, runs the helper functions for all requested nfl attributes. If all helper functions for at least
-- one of the provided attributes return TRUE, the function returns TRUE.
-- This filters the source data so it only includes rows being translated for a given attribute. Needed in cases like BC and SK 
-- where translations are run for individual nfl attributes in turn. Without this we end up with duplicate cas_id-layer combinations
-- in CASFRI.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_HasNFLInfo(text, text, text);
CREATE OR REPLACE FUNCTION TT_HasNFLInfo(
  inventory_id text,
  filter_attributes text,
  source_vals text
)
RETURNS boolean AS $$
  DECLARE
    _fiter_attributes text[];
    _source_vals text[];
    _nat_non_veg_boolean boolean := FALSE;
    _non_for_veg_boolean boolean := FALSE;
    _non_for_anth_boolean boolean := FALSE;
    _inventory_standard_cd text; -- BC - needs to be 1st in string list 
    _land_cover_class_cd_1 text; -- BC - needs to be 2nd in string list
    _bclcs_level_4 text; -- BC - needs to be 3rd in string list
    _non_productive_descriptor_cd text; -- BC - needs to be 4th in string list
    _non_veg_cover_type_1 text; -- BC - needs to be 5th in string list
    _shrub_herb text; -- SK - needs to be 1st in string list
    _nvsl_aquatic_class text; -- SK - nvsl needs to be 2nd in string list, aquatic_class needs to be 3rd
    _luc_transp_class text; -- SK - luc needs to be 4th in string list, transp_class needs to be 5th
  BEGIN
    -- parse string lists
    _fiter_attributes = TT_ParseStringList(filter_attributes, TRUE);
    _source_vals = TT_ParseStringList(source_vals, TRUE);
        
    -- run validations for the requestesd inventory and attributes
    -- If all validations for a given attribute return TRUE, then set the declared
    -- variable to true. Once run if any of the decared variables are TRUE, return
    -- TRUE from the function.
    
    -----------
    -- BC
    -----------
    -- assign source values to variables depending on the inventory id
    IF inventory_id IN('BC08','BC10') THEN
      _inventory_standard_cd = _source_vals[1]; 
      _land_cover_class_cd_1 = _source_vals[2];
      _bclcs_level_4 = _source_vals[3];
      _non_productive_descriptor_cd = _source_vals[4];
      _non_veg_cover_type_1 = _source_vals[5];
    
      -- run validations
      IF 'nat_non_veg' = ANY (_fiter_attributes) THEN
        IF tt_vri01_nat_non_veg_validation(_inventory_standard_cd, _land_cover_class_cd_1, _bclcs_level_4, _non_productive_descriptor_cd, _non_veg_cover_type_1)
        THEN
          _nat_non_veg_boolean = TRUE;
        END IF;
      END IF;
      
      IF 'non_for_anth' = ANY (_fiter_attributes) THEN
        IF tt_vri01_non_for_anth_validation(_inventory_standard_cd, _land_cover_class_cd_1, _non_productive_descriptor_cd, _non_veg_cover_type_1)
        THEN
          _non_for_anth_boolean = TRUE;
        END IF;
      END IF;
      
      IF 'non_for_veg' = ANY (_fiter_attributes) THEN
        IF tt_vri01_non_for_veg_validation(_inventory_standard_cd, _land_cover_class_cd_1, _bclcs_level_4, _non_productive_descriptor_cd)
        THEN
          _non_for_veg_boolean = TRUE;
        END IF;
      END IF;
    END IF;
    
    -----------
    -- SK
    -----------
    -- assign source values to variables depending on the inventory id
    IF inventory_id IN('SK02','SK03','SK04','SK05','SK06') THEN
      _shrub_herb = _source_vals[1];
      _nvsl_aquatic_class = _source_vals[2] || _source_vals[3]; -- concatenate for use in matchList
      _luc_transp_class = _source_vals[4] || _source_vals[5]; -- concatenate for use in matchList
    END IF;
    
    -- run validations
    IF inventory_id IN('SK02', 'SK03', 'SK04', 'SK05', 'SK06') THEN
      IF 'nat_non_veg' = ANY (_fiter_attributes) THEN
        IF tt_matchList(_nvsl_aquatic_class,'{''UK'', ''CB'', ''RK'', ''SA'', ''MS'', ''GR'', ''SB'', ''WA'', ''LA'', ''RI'', ''FL'', ''SF'', ''FP'', ''ST'', ''WASF'', ''WALA'', ''UKLA'', ''WARI'', ''WAFL'', ''WAFP'', ''WAST'',''L'',''R''}')
        THEN
          _nat_non_veg_boolean = TRUE;
        END IF;
      END IF;
      
      IF 'non_for_anth' = ANY (_fiter_attributes) THEN
        IF tt_matchList(_luc_transp_class,'{''ALA'', ''POP'', ''REC'', ''PEX'', ''GPI'', ''BPI'', ''MIS'', ''ASA'', ''NSA'', ''OIS'', ''OUS'', ''AFS'', ''CEM'', ''WEH'', ''TOW'', ''RWC'', ''RRC'', ''TLC'', ''PLC'', ''MPC'',''PL'',''RD'',''TL'',''vegu'', ''bugp'', ''towu'', ''cmty'', ''dmgu'', ''gsof'', ''rwgu'', ''muou'', ''mg'', ''peatc'', ''lmby'', ''sdgu'', ''bupo'', ''ftow''}')
        THEN
          _non_for_anth_boolean = TRUE;
        END IF;
      END IF;
      
      IF 'non_for_veg' = ANY (_fiter_attributes) THEN
        IF tt_matchList(_shrub_herb,'{''Ts'',''Al'',''Bh'',''Ma'',''Sa'',''Pc'',''Cr'',''Wi'',''Ls'',''Ro'',''Bi'',''Bu'',''Dw'',''Ra'',''Cu'',''Sn'',''Bb'',''Ci'',''Bl'',''La'',''Le'',''Be'',''Lc'',''Lb'',''He'',''Fe'',''Gr'',''Mo'',''Li'',''Av'',''Se''}')
        THEN
          _non_for_veg_boolean = TRUE;
        END IF;
      END IF;
    END IF;
    
    -- return TRUE if any of the nfl attribute validations passed
    IF _nat_non_veg_boolean OR _non_for_veg_boolean OR _non_for_anth_boolean THEN
      RETURN TRUE;
    ELSE
      RETURN FALSE;
    END IF;
    
  END; 
$$ LANGUAGE plpgsql;

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Begin Translation Function Definitions...
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- TT_vri01_origin_translation(text, text)
--
-- get projected year as first 4 characters of proj_date  
-- return projected year minus projected age
-- Validation should ensure projected year substring is an integer using TT_vri01_origin_validation,
-- and that projected age is not zero using TT_IsNotEqualToInt()
-- 
-- e.g. TT_vri01_origin_translation(proj_date, proj_age)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_origin_translation(text, text);
CREATE OR REPLACE FUNCTION TT_vri01_origin_translation(
  proj_date text,
  proj_age text
)
RETURNS integer AS $$
  BEGIN
    RETURN substring(proj_date from 1 for 4)::int - proj_age::int;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_site_index_translation(text, text)
--
-- If site_index not null, return it.
-- Otherwise return site_index_est.
-- If both are null, TT_vri01_site_index_validation should return error.
-- 
-- e.g. TT_vri01_site_index_translation(site_index, site_index_est)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_site_index_translation(text, text);
CREATE OR REPLACE FUNCTION TT_vri01_site_index_translation(
  site_index text,
  site_index_est text
)
RETURNS double precision AS $$
  BEGIN
    IF TT_NotEmpty(site_index) THEN
      RETURN site_index::double precision;
    ELSIF NOT TT_NotEmpty(site_index) AND TT_NotEmpty(site_index_est) THEN
      RETURN site_index_est::double precision;
	  END IF;
		RETURN NULL;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_non_for_veg_translation(text, text, text, text)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_non_for_veg_translation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_non_for_veg_translation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  bclcs_level_4 text,
  non_productive_descriptor_cd text
)
RETURNS text AS $$
  DECLARE
    result text = NULL;
	  src_cover_types text[] = '{BL, BM, BY, HE, HF, HG, SL, ST}';
	  tgt_cover_types text[] = '{BRYOID, BRYOID, BRYOID, HERBS, FORBS, GRAMMINOIDS, LOW_SHRUB, TALL_SHRUB}';
    src_non_prod_desc text[] = '{AF, M, NPBR, OR}';
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL THEN
      IF land_cover_class_cd_1 = ANY(src_cover_types) THEN
        result = TT_MapText(land_cover_class_cd_1, src_cover_types::text, tgt_cover_types::text);
      END IF;
    END IF;
    
    IF inventory_standard_cd IN ('V', 'I') AND bclcs_level_4 IS NOT NULL AND result IS NULL THEN
      IF bclcs_level_4  = ANY(src_cover_types) THEN
        result = TT_MapText(bclcs_level_4, src_cover_types::text, tgt_cover_types::text);
      END IF;
    END IF;
    
    IF inventory_standard_cd='F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd = ANY(src_non_prod_desc) THEN
        result = TT_MapText(non_productive_descriptor_cd, src_non_prod_desc::Text, '{''ALPINE_FOREST'', ''GRAMMINOIDS'', ''LOW_SHRUB'', ''GRAMMINOIDS''}');
      END IF;
    END IF;

    IF inventory_standard_cd='F' AND bclcs_level_4 IS NOT NULL AND result IS NULL THEN
      IF bclcs_level_4  = ANY(src_cover_types) THEN
        result = TT_MapText(bclcs_level_4, src_cover_types::text, tgt_cover_types::text);
      END IF;
    END IF;
    RETURN result;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_nat_non_veg_translation(text, text, text, text, text)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_nat_non_veg_translation(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_nat_non_veg_translation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  bclcs_level_4 text,
  non_productive_descriptor_cd text,
  non_veg_cover_type_1 text
)
RETURNS text AS $$
  DECLARE
    result text = NULL;
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND non_veg_cover_type_1 IS NOT NULL THEN
      IF non_veg_cover_type_1 IN ('BE', 'BI', 'BR', 'BU', 'CB', 'DW', 'ES', 'GL', 'LA', 'LB', 'LL', 'LS', 'MN', 'MU', 'OC', 'PN', 'RE', 'RI', 'RM', 'RS', 'TA') THEN
        result = TT_MapText(non_veg_cover_type_1, '{''BE'', ''BI'', ''BR'', ''BU'', ''CB'', ''DW'', ''ES'', ''GL'', ''LA'', ''LB'', ''LL'', ''LS'', ''MN'', ''MU'', ''OC'', ''PN'', ''RE'', ''RI'', ''RM'', ''RS'', ''TA''}', '{''BEACH'', ''ROCK_RUBBLE'', ''ROCK_RUBBLE'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''SNOW_ICE'', ''LAKE'', ''ROCK_RUBBLE'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''OCEAN'', ''SNOW_ICE'', ''LAKE'', ''RIVER'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''ROCK_RUBBLE''}');
      END IF;
    END IF;

    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL AND result IS NULL THEN
      IF land_cover_class_cd_1 IN ('BE', 'BI', 'BR', 'BU', 'CB', 'EL', 'ES', 'GL', 'LA', 'LB', 'LL', 'LS', 'MN', 'MU', 'OC', 'PN', 'RE', 'RI', 'RM', 'RO', 'RS', 'SI', 'TA') THEN
        result = TT_MapText(land_cover_class_cd_1, '{''BE'', ''BI'', ''BR'', ''BU'', ''CB'', ''EL'', ''ES'', ''GL'', ''LA'', ''LB'', ''LL'', ''LS'', ''MN'', ''MU'', ''OC'', ''PN'', ''RE'', ''RI'', ''RM'', ''RO'', ''RS'', ''SI'', ''TA''}', '{''BEACH'', ''ROCK_RUBBLE'', ''ROCK_RUBBLE'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''EXPOSED_LAND'', ''SNOW_ICE'', ''LAKE'', ''ROCK_RUBBLE'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''OCEAN'', ''SNOW_ICE'', ''LAKE'', ''RIVER'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''ROCK_RUBBLE''}');
      END IF;
    END IF;
    
    IF inventory_standard_cd IN ('V', 'I') AND bclcs_level_4 IS NOT NULL AND result IS NULL THEN
      IF bclcs_level_4 IN ('EL', 'RO', 'SI') THEN
        result = TT_MapText(bclcs_level_4, '{''EL'', ''RO'', ''SI''}', '{''EXPOSED_LAND'', ''ROCK_RUBBLE'', ''SNOW_ICE''}');
      END IF;
    END IF;
    
    IF inventory_standard_cd='F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd IN ('A', 'CL', 'G', 'ICE', 'L', 'MUD', 'R', 'RIV', 'S', 'SAND', 'TIDE') THEN
        result = TT_MapText(non_productive_descriptor_cd, '{''A'', ''CL'', ''G'', ''ICE'', ''L'', ''MUD'', ''R'', ''RIV'', ''S'', ''SAND'', ''TIDE''}', '{''ALPINE'', ''EXPOSED_LAND'', ''WATER_SEDIMENT'', ''SNOW_ICE'', ''LAKE'', ''EXPOSED_LAND'', ''ROCK_RUBBLE'', ''RIVER'', ''SLIDE'', ''SAND'', ''TIDAL_FLATS''}');
      END IF;
    END IF;

    IF inventory_standard_cd='F' AND bclcs_level_4 IS NOT NULL AND result IS NULL THEN
      IF bclcs_level_4 IN ('EL', 'RO', 'SI') THEN
        result = TT_MapText(bclcs_level_4, '{''EL'', ''RO'', ''SI''}', '{''EXPOSED_LAND'', ''ROCK_RUBBLE'', ''SNOW_ICE''}');
      END IF;
    END IF;
    RETURN result;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_vri01_non_for_anth_translation(text, text, text, text)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_non_for_anth_translation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_non_for_anth_translation(
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  non_productive_descriptor_cd text,
  non_veg_cover_type_1 text
)
RETURNS text AS $$
  DECLARE
    result text = NULL;
	src_cover_types text[] = '{AP, GP, MI, MZ, OT, RN, RZ, TZ, UR}';
	tgt_cover_types text[] = '{FACILITY_INFRASTRUCTURE, INDUSTRIAL, INDUSTRIAL, INDUSTRIAL, OTHER, FACILITY_INFRASTRUCTURE, FACILITY_INFRASTRUCTURE, INDUSTRIAL, FACILITY_INFRASTRUCTURE}';
    src_non_prod_desc text[] = '{C, GR, P, U}';
  BEGIN
    -- run if statements
    IF inventory_standard_cd IN ('V', 'I') AND non_veg_cover_type_1 IS NOT NULL THEN
      IF non_veg_cover_type_1 = ANY(src_cover_types) THEN
        result = TT_MapText(non_veg_cover_type_1, src_cover_types::text, tgt_cover_types::text);
      END IF;
    END IF;
        
    IF inventory_standard_cd IN ('V', 'I') AND land_cover_class_cd_1 IS NOT NULL AND result IS NULL THEN
      IF land_cover_class_cd_1 = ANY(src_cover_types) THEN
        result = TT_MapText(land_cover_class_cd_1, src_cover_types::text, tgt_cover_types::text);
      END IF;
    END IF;
        
    IF inventory_standard_cd = 'F' AND non_productive_descriptor_cd IS NOT NULL THEN
      IF non_productive_descriptor_cd = ANY(src_non_prod_desc) THEN
        result = TT_MapText(non_productive_descriptor_cd, src_non_prod_desc::text, '{''CL'', ''IN'', ''CL'', ''FA''}');
      END IF;
    END IF;
    
    RETURN result;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- THIS COULD BECOME A GENERIC FUNCTION IF IT'S USEFUL IN OTHER FRIs
--
-- TT_avi01_non_for_anth_translation(text, text, text, text, text)
--
--  For two values, if one of them is null or empty and the other is not null or empty.
--  use the value that is not null or empty in mapText.
--
-- e.g. TT_avi01_non_for_anth_translation(val1, val2, lst1, lst2, ignoreCase)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_avi01_non_for_anth_translation(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_avi01_non_for_anth_translation(
  val1 text,
  val2 text,
  lst1 text,
  lst2 text,
  ignoreCase text)
RETURNS text AS $$
  BEGIN
    PERFORM TT_ValidateParams('TT_avi01_non_for_anth_translation',
                              ARRAY['lst1', lst1, 'stringlist',
                                    'lst2', lst2, 'stringlist',  
                                    'ignoreCase', ignoreCase, 'boolean']);

    IF NOT TT_NotEmpty(val1) AND TT_NotEmpty(val2) THEN
      RETURN TT_MapText(val2, lst1, lst2, ignoreCase);
    ELSIF TT_NotEmpty(val1) AND NOT TT_NotEmpty(val2) THEN
      RETURN TT_MapText(val1, lst1, lst2, ignoreCase);
    END IF;
    RETURN NULL;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_nbi01_stand_structure_translation(text, text, text)
--
-- If src_filename = 'Forest' and l2vs=0, then stand_structure=“SINGLE_LAYERED”
-- If src_filename = 'Forest' and (l1vs>0 and l2vs>0) then stand_structure=“MULTI_LAYERED”
-- If src_filename = 'Forest' and (l1vs>1 and l2vs>1) then stand_structure=“COMPLEX”
--
-- For NB01 src_filename should match 'Forest'.
-- For NB02 src_filename should match 'geonb_forest-foret'.
--
-- e.g. TT_nbi01_stand_structure_translation(src_filename, l1vs, l2vs)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_stand_structure_translation(text, text, text);
CREATE OR REPLACE FUNCTION TT_nbi01_stand_structure_translation(
  src_filename text,
  l1vs text,
  l2vs text
)
RETURNS text AS $$
  DECLARE
    _l1vs int;
    _l2vs int;
  BEGIN
    PERFORM TT_ValidateParams('TT_nbi01_stand_structure_translation',
                              ARRAY['src_filename', src_filename, 'text',
                                    'l1vs', l1vs, 'int',  
                                    'l2vs', l2vs, 'int']);
    _l1vs = l1vs::int;
    _l2vs = l2vs::int;
		
	IF src_filename IN ('Forest', 'geonb_forest-foret') THEN
	  IF _l2vs = 0 THEN
		RETURN 'SINGLE_LAYERED';
	  ELSIF _l1vs > 1 AND _l2vs > 1 THEN
		  RETURN 'COMPLEX';
	  ELSIF _l1vs > 0 AND _l2vs > 0 THEN
		  RETURN 'MULTI_LAYERED';
	  END IF;
	END IF;				
	RETURN NULL;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_nbi01_wetland_translation(text, text, text, text)
--
-- Assign 4 letter wetland character code, then return the requested character (1-4)
--
-- e.g. TT_nbi01_wetland_translation(wt, vt, im, '1')
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_wetland_translation(text, text, text, text);
CREATE OR REPLACE FUNCTION TT_nbi01_wetland_translation(
  wc text,
  vt text,
  im text,
  ret_char_pos text
)
RETURNS text AS $$
  DECLARE
	wetland_code text;
    result text;
  BEGIN
    PERFORM TT_ValidateParams('TT_nbi01_wetland_translation',
                              ARRAY['ret_char_pos', ret_char_pos, 'int']);
	  wetland_code = TT_nbi01_wetland_code(wc, vt, im);

    -- substring wetland_code
    IF wetland_code IS NOT NULL THEN
      result = substring(wetland_code from ret_char_pos::int for 1);
      IF result = '-' THEN
        RETURN NULL;
      END IF;
	  CASE WHEN ret_char_pos = '1' THEN -- WETLAND_TYPE
	         result = TT_MapText(result, '{''B'', ''F'', ''S'', ''M'', ''O'', ''T'', ''E'', ''W'', ''Z''}', '{''BOG'', ''FEN'', ''SWAMP'', ''MARSH'', ''SHALLOW_WATER'', ''TIDAL_FLATS'', ''ESTUARY'', ''WETLAND'', ''NOT_WETLAND''}');
	       WHEN ret_char_pos = '2' THEN -- WET_VEG_COVER
	         result = TT_MapText(result, '{''F'', ''T'', ''O'', ''C'', ''M''}', '{''FORESTED'', ''WOODED'', ''OPEN_NON_TREED_FRESHWATER'', ''OPEN_NON_TREED_COASTAL'', ''MUD''}');
	       WHEN ret_char_pos = '3' THEN -- WET_LANDFORM_MOD
	         result = TT_MapText(result, '{''X'', ''P'', ''N'', ''A''}', '{''PERMAFROST_PRESENT'', ''PATTERNING_PRESENT'', ''NO_PERMAFROST_PATTERNING'', ''SALINE_ALKALINE''}');
	       WHEN ret_char_pos = '4' THEN -- WET_LOCAL_MOD
	         result = TT_MapText(result, '{''C'', ''R'', ''I'', ''N'', ''S'', ''G''}', '{''INT_LAWN_SCAR'', ''INT_LAWN_ISLAND'', ''INT_LAWN'', ''NO_LAWN'', ''SHRUB_COVER'', ''GRAMMINOIDS''}');
	  END CASE;
	ELSE
	  RETURN NULL;
    END IF;
    
    -- return value or null
     RETURN result;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- TT_nbi01_nb01_productive_for_translation(text, text, text, text, text)
--
-- If no valid crown closure value, or no valid height value. Assign PP.
-- Or if forest stand type is 0, and l1 or l2 trt is neither CC or empty string. Assign PP.
-- Otherwise assign PF (productive forest).
--
-- e.g. TT_nbi01_nb01_productive_for_translation(l1cc, l1ht, l1trt, l2trt, fst)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_nb01_productive_for_translation(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_nbi01_nb01_productive_for_translation(
  l1cc text,
  l1ht text,
  l1trt text,
  l2trt text,
  fst text
)
RETURNS text AS $$
  BEGIN
    IF NOT TT_NotNull(l1cc) THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSIF NOT TT_MatchList(l1cc, '{''1'', ''2'', ''3'', ''4'', ''5''}') THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSEIF NOT TT_NotNull(l1ht) THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSIF NOT TT_IsGreaterThan(l1ht, '0.1') THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSIF NOT TT_IsLessThan(l1ht, '100') THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSIF fst = '0'::text AND l1trt != 'CC' AND btrim(l1trt, ' ') != '' THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    ELSIF fst = '0'::text AND l2trt != 'CC' AND btrim(l2trt, ' ') != '' THEN
      RETURN 'POTENTIALLY_PRODUCTIVE';
    END IF;
    RETURN 'PRODUCTIVE_FOREST';
  END;
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_nbi01_nb02_productive_for_translation(text, text, text, text, text)
--
--  2 options for PRODUCTIVE_FOR, replicating NB02 using trt, l1cc, l1ht, l1s1.
--  Or using fst.
--  Here I`m using the simpler fst method until issue #181
--
-- If no valid crown closure value, or no valid height value. Assign PP.
-- Or if forest stand type is 0, and l1 or l2 trt is neither CC or empty string. Assign PP.
-- Otherwise assign PF (productive forest).
--
-- e.g. TT_nbi01_nb02_productive_for_translation(fst)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_nbi01_nb02_productive_for_translation(text);
CREATE OR REPLACE FUNCTION TT_nbi01_nb02_productive_for_translation(
  fst text
)
RETURNS text AS $$
  DECLARE
    _fst int;
  BEGIN
    _fst = fst::int;
	
    IF _fst IN (1, 2) THEN
	  RETURN 'PRODUCTIVE_FOREST';
	ELSIF _fst = 3 THEN
	  RETURN 'POTENTIALLY_PRODUCTIVE';
	END IF;
	RETURN NULL;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------
-- TT_vri01_dist_yr_translation(text)
--
--  val
-- cutoff_val
--
-- BC disturbance codes are always a single character for the type, concatenated
-- to two digits for the year (e.g. B00). Digits needs to extracted and converted to 4-digit
-- integer for disturbance year.
--
-- Takes the disturbance code, substrings to get the last two values,
-- then concats with either 19 or 20 depending on cutoff.
-- If val <= cutoff_val, concat with 20, else concat with 19.
-- e.g. with cutoff_val of 17 B17 would become 2017, B18 would become
-- 1918.
--
-- e.g. TT_vri01_dist_yr_translation(val, cutoff_val)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_dist_yr_translation(text, text);
CREATE OR REPLACE FUNCTION TT_vri01_dist_yr_translation(
  val text,
  cutoff_val text
)
RETURNS int AS $$
  DECLARE
    _val_text text;
    _val_int int;
    _cutoff_val int;
  BEGIN
  PERFORM TT_ValidateParams('TT_vri01_dist_yr_translation',
                              ARRAY['cutoff_val', cutoff_val, 'int']);
  _cutoff_val = cutoff_val::int;
  _val_text = TT_SubstringText(val, '2'::text, '2'::text); -- get last two characters from string. This is the year. First character is the dist type.
  _val_int = _val_text::int;
  
  IF _val_int <= _cutoff_val THEN
    RETURN TT_Concat('{''20'', ' || _val_text || '}'::text, ''::text)::int;
  ELSE
    RETURN TT_Concat('{''19'', ' || _val_text || '}'::text, ''::text)::int;
  END IF;
  END;
$$ LANGUAGE plpgsql IMMUTABLE;
-------------------------------------------------------------------------------
-- TT_tie01_crownclosure_translation(text)
--
-- val text
-- lookup_schema text
-- lookup_table text
-- lookup_col text
-- in_etage text
-- et_domi text
-- sup_cl_age_et text - source column
-- inf_cl_age_et text - source column
-- sup_densitie text
-- inf_densitie text
-- cl_dens text 
-- layer text (1 or 2)
-- upper_lower - if returned values represent ranges we will need to return either the upper or lower value
--
-- QC crown closure assigned based on complicated logic.
-- If no cl_age value we know the entire polygon is NFL. This should be trapped with a validation function
-- If cl_age has a value we know there is forest info.
  -- If forest info and there is data in the etage table, we need to calculate the number of layers.
    -- If only one layer, we simply return the density value from the sup table (e.g. sup_densite)
    -- If two layers of forest info, we need to figure out whether layer 1 is sup or inf. Get the age class code for the layer being processed
    -- from the cl_age string, and compare it to the age class codes from the sup and inf tables. Then return crown closure from whichever matches.
  -- If forest info but no data in etage table, 
    -- If num_of_layers = 2, return NULL. The density is for the polygon and cannot be attributed to a layer.
    -- If num_of_layers = 1, check for values in cl_dens.
    -- If null, no info for this polygon
    -- If processing layer 1, return cl_dens
    -- If processing layer 2, no info for this polygon. 
--
-- e.g. TT_tie01_crownclosure_translation(val, lookup_schema, lookup_table, in_etage, et_domi, sup_cl_age_et, inf_cl_age_et, sup_densite, inf_densite, cl_dens, layer, upper_lower)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_crownclosure_translation(text, text, text, text, text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_tie01_crownclosure_translation(
  cl_age text,
  lookup_schema text,
  lookup_table text,
  lookup_col text,
  in_etage text,
  et_domi text,
  sup_cl_age_et text,
  inf_cl_age_et text,
  sup_densite text,
  inf_densite text,
  cl_dens text,
  layer text,
  upper_lower text
)
RETURNS int AS $$
  DECLARE
    _layer int;
    num_of_layers int;
    layer_age_code text;
  BEGIN
    PERFORM TT_ValidateParams('TT_tie01_crownclosure_translation',
                              ARRAY['lookup_schema', lookup_schema, 'text',
                                   'lookup_table', lookup_table, 'text',
                                   'lookup_col', lookup_col, 'text',
                                   'layer', layer, 'int',
                                   'upper_lower', upper_lower, 'text']);
    _layer = layer::int;
    num_of_layers = TT_lookupInt(cl_age, lookup_schema, lookup_table, 'num_of_layers'::text);
    
    -- layer can only be 1 or 2
    IF num_of_layers > 2 THEN
      RETURN NULL;
    END IF;
    
    -- upper_lower can only be 'upper' or 'lower'.
    IF NOT upper_lower IN ('upper','lower') THEN
      RETURN NULL;
    END IF;
    
    -- cl_age needs a value
    IF cl_age IS NULL THEN
      RETURN NULL;
    END IF;
    
    IF in_etage = 'O' THEN
      IF num_of_layers = 1 THEN
        IF _layer = 1 THEN
          RETURN sup_densite;
        ELSE
          RETURN NULL; -- no layer 2 info to return
        END IF;
      ELSE -- num_of_layers = 2
        
        IF et_domi IS NULL OR et_domi = 'EQU' THEN
          -- the layer 1 code is always the first code in cl_age, i.e. layer_1_age in the lookup table. But the return value could be in either the sup or inf table.
          -- same for layer 2. Always the second code, but cound be sup or inf.
          -- get the layer 1/2 age code using lookup table...
          layer_age_code = TT_lookupText(cl_age, lookup_schema, lookup_table, lookup_col);

          -- is it in the sup or the inf table? Find out then return the return value from the correct table.
          IF sup_cl_age_et = inf_cl_age_et THEN
            -- what do we do here? Don't know which to return
            RETURN NULL;
          ELSIF layer_age_code = sup_cl_age_et THEN
            RETURN sup_densite; -- if layer is from sup, return sup
          ELSIF layer_age_code = inf_cl_age_et THEN
            RETURN inf_densite; -- if layer is from inf, return inf
          ELSE
            RETURN NULL; -- if it doesn't match either there is an error
          END IF;
        ELSE 
          -- If et_domi has a value, identify layers 1 and 2 using the following:
            -- EQU: Both layers have the same coverage (45%-55%). IN THIS CASE USE THE AGE CODE METHOD ABOVE.
            -- SUP: sup is layer one and it covers more than 50%
            -- INF: inf is the dominant layer (layer 1) and it covers more than 50%
            IF et_domi = 'SUP' THEN
              IF _layer = 1 THEN
                RETURN sup_densite;
              ELSE --layer 2
                RETURN inf_densite;
              END IF;
            ELSIF et_domi = 'INF' THEN
              IF _layer = 1 THEN
                RETURN inf_densite;
              ELSE --layer 2
                RETURN sup_densite;
              END IF;
            ELSE
              RETURN NULL; -- error, should be caught in validation
            END IF;
        END IF;
      END IF;
      
    ELSIF in_etage = 'N' THEN
      IF cl_dens IS NULL THEN
        RETURN NULL;
      ELSIF num_of_layers = 1 AND _layer = 1 THEN
        IF upper_lower = 'upper' THEN
          RETURN TT_MapInt(cl_dens, '{''A'',''B'',''C'',''D'',''H'',''I''}', '{100,80,60,40,100,60}');
        ELSE -- lower
          RETURN TT_MapInt(cl_dens, '{''A'',''B'',''C'',''D'',''H'',''I''}', '{80,60,40,25,60,0}');
        END IF;
      ELSE
        RETURN NULL; -- if num_of_layers = 2 no value can be assigned because cl_dens is at the polygon level. If layer = 2 and num_of_layers = 1, no layer 2 info to return.
      END IF;   
    ELSE
      RETURN NULL; -- in_etage is erroneous
    END IF;
  END;
$$ LANGUAGE plpgsql VOLATILE;

-------------------------------------------------------------------------------
-- TT_tie01_height_translation(text)
--
-- val text
-- lookup_schema text
-- lookup_table text
-- lookup_col text
-- in_etage - source column
-- sup_cl_age_et text - source column
-- inf_cl_age_et text - source column
-- sup_hauteur text
-- inf_hauteur text
-- cl_haut text 
-- layer text (1 or 2)
-- upper_lower - if returned values represent ranges we will need to return either the upper or lower value
--
-- logic is the same as TT_tie01_crownclosure_translation except that when in_etage = 'O' and num_of_layers = 2,
-- the single possible height value is assigned to layer 1. Instead of all layers returning null.
--
-- e.g. TT_tie01_height_translation(val, lookup_schema, lookup_table, in_etage, sup_cl_age_et, inf_cl_age_et, sup_hauteur, inf_hauteur, cl_haut, layer, upper_lower)
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_tie01_height_translation(text, text, text, text, text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_tie01_height_translation(
  cl_age text,
  lookup_schema text,
  lookup_table text,
  lookup_col text,
  in_etage text,
  et_domi text,
  sup_cl_age_et text,
  inf_cl_age_et text,
  sup_hauteur text,
  inf_hauteur text,
  cl_haut text,
  layer text,
  upper_lower text
)
RETURNS int AS $$
  DECLARE
    _layer int;
    num_of_layers int;
    layer_age_code text;
  BEGIN
    PERFORM TT_ValidateParams('TT_tie01_height_translation',
                              ARRAY['lookup_schema', lookup_schema, 'text',
                                   'lookup_table', lookup_table, 'text',
                                   'lookup_col', lookup_col, 'text',
                                   'layer', layer, 'int',
                                   'upper_lower', upper_lower, 'text']);
    _layer = layer::int;
    num_of_layers = TT_lookupInt(cl_age, lookup_schema::text, lookup_table::text, 'num_of_layers'::text);
    
    -- layer can only be 1 or 2
    IF num_of_layers > 2 THEN
      RETURN NULL;
    END IF;
    
    -- upper_lower can only be 'upper' or 'lower'.
    IF NOT upper_lower IN ('upper','lower') THEN
      RETURN NULL;
    END IF;
    
    -- cl_age needs a value
    IF cl_age IS NULL THEN
      RETURN NULL;
    END IF;
    
    IF in_etage = 'O' THEN
      IF num_of_layers = 1 THEN
        IF _layer = 1 THEN
          RETURN sup_hauteur;
        ELSE
          RETURN NULL; -- no layer 2 info to return
        END IF;
      ELSE -- num_of_layers = 2
        IF et_domi IS NULL OR et_domi = 'EQU' THEN
          -- the layer 1 code is always the first code in cl_age, i.e. layer_1_age in the lookup table. But the return value could be in either the sup or inf table.
          -- same for layer 2. Always the second code, but cound be sup or inf.
          -- get the layer 1/2 age code using lookup table...
          layer_age_code = TT_lookupText(cl_age, lookup_schema, lookup_table, lookup_col);

          -- is it in the sup or the inf table? Find out then return the return value from the correct table.
          IF sup_cl_age_et = inf_cl_age_et THEN
            -- what do we do here? Don't know which to return
            RETURN NULL;
          ELSIF layer_age_code = sup_cl_age_et THEN
            RETURN sup_hauteur; -- if layer is from sup, return sup
          ELSIF layer_age_code = inf_cl_age_et THEN
            RETURN inf_hauteur; -- if layer is from inf, return inf
          ELSE
            RETURN NULL; -- if it doesn't match either there is an error
          END IF;
        ELSE 
          -- If et_domi has a value, identify layers 1 and 2 using the following:
            -- EQU: Both layers have the same coverage (45%-55%). IN THIS CASE USE THE AGE CODE METHOD ABOVE.
            -- SUP: sup is layer one and it covers more than 50%
            -- INF: inf is the dominant layer (layer 1) and it covers more than 50%
            IF et_domi = 'SUP' THEN
              IF _layer = 1 THEN
                RETURN sup_hauteur;
              ELSE --layer 2
                RETURN inf_hauteur;
              END IF;
            ELSIF et_domi = 'INF' THEN
              IF _layer = 1 THEN
                RETURN inf_hauteur;
              ELSE --layer 2
                RETURN sup_hauteur;
              END IF;
            ELSE
              RETURN NULL; -- error, should be caught in validation
            END IF;
        END IF;
      END IF;
      
    ELSIF in_etage = 'N' THEN
      IF cl_haut IS NULL THEN
        RETURN NULL;
      ELSIF _layer = 1 THEN
        IF upper_lower = 'upper' THEN
          RETURN TT_MapInt(cl_haut, '{''1'',''2'',''3'',''4'',''5'',''6'',''7''}', '{100, 22, 17, 12, 7, 4, 2}');
        ELSE -- lower
          RETURN TT_MapInt(cl_haut, '{''1'',''2'',''3'',''4'',''5'',''6'',''7''}', '{22, 17, 12, 7, 4, 2, 0}');
        END IF;
      ELSE
        RETURN NULL; -- If layer = 2 and num_of_layers = 1 or 2, no layer 2 info to return.
      END IF;   
    ELSE
      RETURN NULL; -- in_etage is erroneous
    END IF;
  END;
$$ LANGUAGE plpgsql VOLATILE;

-------------------------------------------------------------------------------
-- TT_fim_species_code(text, text)
--
-- sp_string text - source string of species and percentages
-- sp_number text - the species number being requested (i.e. SPECIES 1-10 in casfri)
--
-- This function is used by the following two functions to extract the requested species name an percent code.
-- The following functions take that code and extract either species name or percent info.
-- String structure is a 2-letter species code, followed by 2 spaces, then a 2 digit percentage.
-- In cases where a species is 100%, there is only 1 space so the total length of all codes is 6.
-- Multiple codes are concatenated together. Max number of species in ON is 10.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_fim_species_code(text, text);
CREATE OR REPLACE FUNCTION TT_fim_species_code(
  sp_string text,
  sp_number text
)
RETURNS text AS $$
  DECLARE
    _sp_number int;
    start_char int;
  BEGIN
    
  _sp_number = sp_number::int;
  
  IF TT_Length(sp_string) > 1 THEN -- any empty cells will return null
    IF _sp_number = 1 THEN -- first species is characters 1 to 6
      RETURN substring(sp_string, 1, 6);
    ELSE
      start_char = 1 + ((_sp_number - 1)*6); -- calculate start character for substring
      RETURN substring(sp_string, start_char, 6); -- following species are start character + 6
    END IF;
  ELSE
    RETURN NULL;
  END IF;
  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_fim_species_translation(text, text, text, text, text)
--
-- sp_string text - source string of species and percentages
-- sp_number text - the species number being requested (i.e. SPECIES 1-10 in casfri)
-- lookup_schema text, 
-- lookup_table text,
-- lookup_col text
--
-- This functions calls TT_fim_species_code() to extract the requested species-percent code,
-- then extracts the species code as the first two characters. Then runs TT_LookupText() to
-- convert the ON code into the CASFRI code using a lookup table.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_fim_species_translation(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_fim_species_translation(
  sp_string text,
  sp_number text,
  lookup_schema text, 
  lookup_table text,
  lookup_col text,
  retrieveCol text
)
RETURNS text AS $$
  DECLARE
  code text;
  species text;
  BEGIN
    code = TT_fim_species_code(sp_string, sp_number); -- get the requested species code and percent
    
    IF TT_Length(code) > 1 THEN -- 
      species = substring(code, 1, 2); -- species code is first two characters of code
    ELSE
      RETURN NULL;
    END IF;
    
    -- transform species to casfri species using lookup table
    RETURN TT_LookupText(species, lookup_schema, lookup_table, lookup_col, retrieveCol, TRUE::text);
  END; 
$$ LANGUAGE plpgsql VOLATILE;

-------------------------------------------------------------------------------
-- TT_fim_species_percent_translation(text, text)
--
-- sp_string text - source string of species and percentages
-- sp_number text - the species number being requested (i.e. SPECIES 1-10 in casfri)
--
-- This functions calls TT_fim_species_code() to extract the requested species-percent code,
-- then extracts the percentage as the fifth and sixth characters, or the fourth fifth and sixth characters
-- if 100%.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_fim_species_percent_translation(text, text);
CREATE OR REPLACE FUNCTION TT_fim_species_percent_translation(
  sp_string text,
  sp_number text
)
RETURNS int AS $$
  DECLARE
  code text;
  BEGIN
    code = TT_fim_species_code(sp_string, sp_number);
    
    IF TT_Length(code) > 1 THEN
      RETURN substring(code, 4, 3)::int; -- If 100, last 3 digits returned. If <100, substring grabs space and 2 digits but then converts to int so the space is dropped.
    ELSE
      RETURN NULL;
    END IF;
  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_yvi01_nat_non_veg_translation(text, text, text)
--
-- type_lnd text
-- class_ text
-- landpos text
--
-- Assigns nat non veg casfri attributes based on source attribute from various columns.
-- landpos of A becomes AP
-- classes of 'R','L','RS','E','S','B','RR' become 'RIVER,'LAKE,'WATER_SEDIMENT','EXPOSED_LAND','SAND','EXPOSED_LAND','ROCK_RUBBLE'
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_yvi01_nat_non_veg_translation(text, text, text);
CREATE OR REPLACE FUNCTION TT_yvi01_nat_non_veg_translation(
  type_lnd text,
  class_ text,
  landpos text
)
RETURNS text AS $$
  BEGIN
    IF type_lnd IN('NW', 'NS', 'NE') THEN
      IF landpos = 'A' THEN
        RETURN 'ALPINE';
      END IF;
      
      IF class_ IN('R','L','RS','E','S','B','RR') THEN
        RETURN TT_mapText(class_, '{''R'',''L'',''RS'',''E'',''S'',''B'',''RR''}', '{''RIVER'',''LAKE'',''WATER_SEDIMENT'',''EXPOSED_LAND'',''SAND'',''EXPOSED_LAND'',''ROCK_RUBBLE''}');
      END IF;
    END IF;
      
    RETURN NULL;
      
  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_yvi01_non_for_veg_translation(text, text)
--
-- cl_mod text
-- class_ text
--
-- Assigns non for veg casfri attributes based on source attribute from various columns.
-- assumes type_lnd is VN and class is in 'S','H','C','M'
-- then translates cl_mod 'TS','TSo','TSc','LS' to 'TALL_SHRUB','TALL_SHRUB','TALL_SHRUB','LOW_SHRUB'
-- and class 'C','H','M' to 'BRYOID','HERBS','HERBS'
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_yvi01_non_for_veg_translation(text, text, text);
CREATE OR REPLACE FUNCTION TT_yvi01_non_for_veg_translation(
  type_lnd text,
  class_ text,
  cl_mod text
)
RETURNS text AS $$
  BEGIN
    IF type_lnd IN('VN') THEN
      IF class_ IN('S','H','C','M') THEN
        IF cl_mod IN('TS','TSo','TSc','LS') THEN
          RETURN TT_mapText(cl_mod, '{''TS'',''TSo'',''TSc'',''LS''}', '{''TALL_SHRUB'',''TALL_SHRUB'',''TALL_SHRUB'',''LOW_SHRUB''}');
        END IF;
        
        IF class_ IN('C','H','M') THEN
          RETURN TT_mapText(class_, '{''C'',''H'',''M''}', '{''BRYOID'',''HERBS'',''HERBS''}');
        END IF;
      END IF;
    END IF;
    
    RETURN NULL;
  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_generic_stand_structure_translation(text, text, text, text)
--
-- stand_structure text
-- layer1_sp1 text
-- layer1_sp2 text
-- layer1_sp3 text
-- layer2_sp1 text
-- layer2_sp2 text
-- layer2_sp3 text
-- layer3_sp1 text
-- layer3_sp2 text
-- layer3_sp3 text
-- 
-- Generic function the passes H or C from source to casfri, otherwise counts not null
-- forest layers and returns S or M.
--
-- All other cases should be caught in validation.
-- 
-- Inventory specific signatures are made from this generic version using the correct 
-- number of species and layers.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_generic_stand_structure_translation(text, text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_generic_stand_structure_translation(
  stand_structure text,
  layer1_sp1 text,
  layer1_sp2 text,
  layer1_sp3 text,
  layer2_sp1 text,
  layer2_sp2 text,
  layer2_sp3 text,
  layer3_sp1 text,
  layer3_sp2 text,
  layer3_sp3 text
)
RETURNS text AS $$
  DECLARE
    _count1 int := 0;
    _count2 int := 0;
    _count3 int := 0;
    _count int;
  BEGIN
    
    -- are there any layer 1 species? (tried forming a tt_countOfNotNull call here but couldn't get it to run correctly)
    IF tt_notEmpty(layer1_sp1) OR tt_notEmpty(layer1_sp2) OR tt_notEmpty(layer1_sp3) THEN
      _count1 = 1;
    END IF;
    
    -- are there any layer 2 species?
    IF tt_notEmpty(layer2_sp1) OR tt_notEmpty(layer2_sp2) OR tt_notEmpty(layer2_sp3) THEN
      _count2 = 1;
    END IF;
    
    -- are there any layer 3 species?
    IF tt_notEmpty(layer3_sp1) OR tt_notEmpty(layer3_sp2) OR tt_notEmpty(layer3_sp3) THEN
      _count3 = 1;
    END IF;

    _count = _count1 + _count2 + _count3;
  
    -- if stand structure is H or C, return H or C. Note CX was added so this function can be re-used in ON02.
    IF stand_structure IN ('H', 'h', 'C', 'c', 'C4', 'C5', 'CX') THEN
      RETURN tt_mapText(stand_structure, '{''H'', ''h'', ''C'', ''c'', ''C4'', ''C5'', ''CX''}', '{''HORIZONTAL'', ''HORIZONTAL'', ''COMPLEX'', ''COMPLEX'', ''COMPLEX'', ''COMPLEX'', ''COMPLEX''}');
    
    -- if stand structure is not HORIZONTAL or COMPLEX, it must be SINGLE_LAYERED or MULTI_LAYERED.
    -- if only one species layer, return S (this should always be sp1)
    ELSIF _count = 1 THEN
      RETURN 'SINGLE_LAYERED';
    ELSIF _count IN(2, 3) THEN
      RETURN 'MULTI_LAYERED';
    ELSE
      RETURN NULL;
    END IF; 
  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-- avi signature - 2 layers, 3 species
-- DROP FUNCTION IF EXISTS TT_avi01_stand_structure_translation(text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_avi01_stand_structure_translation(
  stand_structure text,
  layer1_sp1 text,
  layer1_sp2 text,
  layer1_sp3 text,
  layer2_sp1 text,
  layer2_sp2 text,
  layer2_sp3 text
)
RETURNS text AS $$
  SELECT TT_generic_stand_structure_translation(stand_structure, layer1_sp1, layer1_sp2, layer1_sp3, layer2_sp1, layer2_sp2, layer2_sp3, NULL::text, NULL::text, NULL::text);
$$ LANGUAGE sql IMMUTABLE;

-- ON02 signature - 2 layers, 1 species
CREATE OR REPLACE FUNCTION TT_fim02_stand_structure_translation(
  stand_structure text,
  layer1_sp1 text,
  layer2_sp1 text
)
RETURNS text AS $$
  SELECT TT_generic_stand_structure_translation(stand_structure, layer1_sp1, NULL::text, NULL::text, layer2_sp1, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text);
$$ LANGUAGE sql IMMUTABLE;

-- SK SFVI signature - 3 layers, 1 species
CREATE OR REPLACE FUNCTION TT_sfv01_stand_structure_translation(
  stand_structure text,
  layer1_sp1 text,
  layer2_sp1 text,
  layer3_sp1 text
)
RETURNS text AS $$
  SELECT TT_generic_stand_structure_translation(stand_structure, layer1_sp1, NULL::text, NULL::text, layer2_sp1, NULL::text, NULL::text, layer3_sp1, NULL::text, NULL::text);
$$ LANGUAGE sql IMMUTABLE;
-------------------------------------------------------------------------------
-- TT_fvi01_countOfNotNull(text, text, text, text, text, text)
--
-- vals1 text
-- vals2 text
-- typeclas text
-- min_typeclas text
-- max_rank_to_consider text
-- 
-- Use match list to determine if typeclas and min_typeclas are NFL values.
-- If they are assign them a string so they are counted as layers. If not assign
-- NULL.
-- 
-- Pass vals1, vals2 and the string/NULLs to countOfNotNull().
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_fvi01_countOfNotNull(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_fvi01_countOfNotNull(
  vals1 text,
  vals2 text,
  typeclas text,
  min_typeclas text,
  max_rank_to_consider text,
  zero_is_null text
)
RETURNS int AS $$
  DECLARE
    nfl_string_list text;
    _typeclas text;
    _min_typeclas text;
  BEGIN

    -- set up nfl_string_list
    nfl_string_list = '{''BE'',''BR'',''BU'',''CB'',''ES'',''LA'',''LL'',''LS'',''MO'',''MU'',''PO'',''RE'',''RI'',''RO'',''RS'',''RT'',''SW'',''AP'',''BP'',''EL'',''GP'',''TS'',''RD'',''SH'',''SU'',''PM'',''BL'',''BM'',''BY'',''HE'',''HF'',''HG'',''SL'',''ST''}';
    
    -- is typeclas NFL?
    IF tt_matchList(typeclas, nfl_string_list) THEN
      _typeclas = 'a_value';
    ELSE
      _typeclas = NULL::text;
    END IF;
    
    -- is min_typeclas NFL?
    IF tt_matchList(min_typeclas, nfl_string_list) THEN
      _min_typeclas = 'a_value';
    ELSE
      _min_typeclas = NULL::text;
    END IF;
    
    -- call countOfNotNull
    RETURN tt_countOfNotNull(vals1, vals2, _typeclas, _min_typeclas, max_rank_to_consider, zero_is_null);

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_vri01_countOfNotNull(text, text, text, text, text, text, text, text)
--
-- vals1 text - string list of layer 1 attributes. This is carried through to couneOfNotNull
-- vals2 text - string list of layer 2 attribtues. This is carried through to couneOfNotNull  
-- inventory_standard_cd text
-- land_cover_class_cd_1 text
-- bclcs_level_4 text
-- non_productive_descriptor_cd text
-- non_veg_cover_type_1 text
-- zero_is_null
-- 
-- Use the custom helper function:  
-- to determine if the row contains 1 - 3 NFL records. If it does assign a string
-- for each NFL layer so they can be counted as a non-null layer.
-- 
-- Pass vals1, vals2 and the string/NULLs to countOfNotNull().
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_vri01_countOfNotNull(text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_vri01_countOfNotNull(
  vals1 text,
  vals2 text,
  inventory_standard_cd text,
  land_cover_class_cd_1 text,
  bclcs_level_4 text,
  non_productive_descriptor_cd text,
  non_veg_cover_type_1 text,
  max_rank_to_consider text,
  zero_is_null text,
  inventory_id text
)
RETURNS int AS $$
  DECLARE
    is_nfl1 text;
    is_nfl2 text;
    is_nfl3 text;
  BEGIN

    -- if non_for_veg is present, add a string.
    IF tt_vri01_non_for_veg_validation(inventory_standard_cd, land_cover_class_cd_1, bclcs_level_4, non_productive_descriptor_cd) THEN
      is_nfl1 = 'a_value';
    ELSE
      is_nfl1 = NULL::text;
    END IF;

    -- if nat_non_veg is present, add a string.
    IF tt_vri01_nat_non_veg_validation(inventory_standard_cd, land_cover_class_cd_1, bclcs_level_4, non_productive_descriptor_cd, non_veg_cover_type_1) THEN
      is_nfl2 = 'a_value';
    ELSE
      is_nfl2 = NULL::text;
    END IF;

    -- if non_for_anth is present, add a string.
    IF tt_vri01_non_for_anth_validation(inventory_standard_cd, land_cover_class_cd_1, non_productive_descriptor_cd, non_veg_cover_type_1) THEN
      is_nfl3 = 'a_value';
    ELSE
      is_nfl3 = NULL::text;
    END IF;
    
    -- call countOfNotNull
    -- if BC08 there is only 1 forest layer so remove the second forest layer from the count
    IF inventory_id = 'BC08' THEN
      RETURN tt_countOfNotNull(vals1, is_nfl1, is_nfl2, is_nfl3, max_rank_to_consider, zero_is_null);
    ELSE
      RETURN tt_countOfNotNull(vals1, vals2, is_nfl1, is_nfl2, is_nfl3, max_rank_to_consider, zero_is_null);
    END IF;

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_sk_utm01_species_percent_translation(text, text, text, text, text, text, text)
--
-- sp_number text - the species number being requested (i.e. SPECIES 1-10 in casfri)
-- sp10 text
-- sp11 text
-- sp12 text
-- sp20 text
-- sp21 text
--
-- returns the species percent based on the requested sp_number and many logical statements
-- to determine the percent based on what species are present. Logical statements were developed
-- with John Cosco and are recorded in an appendix doc.
--
-- Codes the polygon being processed based on the combination of hardwood and
-- softwood species in each column.
-- e.g. concatenates in order either H for hardwood, S for softwood or - for nothing
-- into a 5 character string such as S----
--
-- The code is then used to make a percentage vector and the species requested is returned
-- as an index from the vector.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_sk_utm01_species_percent_translation(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_sk_utm01_species_percent_translation(
  sp_number text,
  sp10 text,
  sp11 text,
  sp12 text,
  sp20 text,
  sp21 text
)
RETURNS int AS $$
  DECLARE
    _sp_number int := sp_number::int;
    hardwoods text[]; -- list of harwood species codes
    softwoods text[]; -- list of softwood species codes
    ft10 text; -- assigns hardwood or softwood forest type
    ft11 text;
    ft12 text;
    ft20 text;
    ft21 text;
    ft_concat text; -- concatenates the ft values.
    percent_vector int[]; -- percentages for the 5 species in a vector
  BEGIN
    
    -- assign hardwood and softwood groups
    softwoods = ARRAY['WS','BS','JP','BF','TL','LP'];
    hardwoods = ARRAY['GA','TA','BP','WB','WE','MM','BO'];
    
    -- assign forest type variables
    IF sp10 = ANY(hardwoods) THEN ft10 = 'H';
    ELSIF sp10 = ANY(softwoods) THEN ft10 = 'S';
    ELSE ft10 = '-';
    END IF;
    
    IF sp11 = ANY(hardwoods) THEN ft11 = 'H';
    ELSIF sp11 = ANY(softwoods) THEN ft11 = 'S';
    ELSE ft11 = '-';
    END IF;
    
    IF sp12 = ANY(hardwoods) THEN ft12 = 'H';
    ELSIF sp12 = ANY(softwoods) THEN ft12 = 'S';
    ELSE ft12 = '-';
    END IF;
    
    IF sp20 = ANY(hardwoods) THEN ft20 = 'H';
    ELSIF sp20 = ANY(softwoods) THEN ft20 = 'S';
    ELSE ft20 = '-';
    END IF;
    
    IF sp21 = ANY(hardwoods) THEN ft21 = 'H';
    ELSIF sp21 = ANY(softwoods) THEN ft21 = 'S';
    ELSE ft21 = '-';
    END IF;

    -- assign forest type code
    ft_concat = ft10 || ft11 || ft12 || ft20 || ft21;
    
    -- Assign logical tests to make percent vector for each forest type code in the source data
    IF ft_concat IN('S----', 'H----') THEN
      percent_vector = ARRAY[100, 0, 0, 0, 0];
    ELSIF ft_concat IN('HH---') THEN
      percent_vector = ARRAY[70, 30, 0, 0, 0];
    ELSIF ft_concat IN('SS---') AND CONCAT(sp10, sp11) NOT IN('JPBS', 'BSJP') THEN
      percent_vector = ARRAY[70, 30, 0, 0, 0];
    ELSIF ft_concat IN('SS---') AND CONCAT(sp10, sp11) IN('JPBS', 'BSJP') THEN
      percent_vector = ARRAY[60, 40, 0, 0, 0];
    ELSIF ft_concat IN('S--S-') THEN
      percent_vector = ARRAY[80, 20, 0, 0, 0];
    ELSIF ft_concat IN('HHH--', 'SSS--') THEN
      percent_vector = ARRAY[40, 30, 30, 0, 0];
    ELSIF ft_concat IN('SS-S-') THEN
      percent_vector = ARRAY[50, 30, 0, 20, 0];
    ELSIF ft_concat IN('S--H-', 'H--S-') THEN
      percent_vector = ARRAY[65, 0, 0, 35, 0];
    ELSIF ft_concat IN('HS-S-') THEN
      percent_vector = ARRAY[60, 30, 0, 10, 0];
    ELSIF ft_concat IN('HS-S-') THEN
      percent_vector = ARRAY[60, 30, 0, 10, 0];
    ELSIF ft_concat IN('HH-S-', 'SS-H-') THEN
      percent_vector = ARRAY[50, 25, 0, 25, 0];
    ELSIF ft_concat IN('H--SS', 'S--HH') THEN
      percent_vector = ARRAY[70, 0, 0, 20, 10];
    ELSIF ft_concat IN('HH-SS', 'SS-HH') THEN
      percent_vector = ARRAY[30, 30, 0, 20, 20];
    ELSIF ft_concat IN('SSSH-', 'HHHS-') THEN
      percent_vector = ARRAY[25, 25, 25, 25, 0];
    ELSIF ft_concat IN('SSSHH', 'HHHSS') THEN
      percent_vector = ARRAY[25, 25, 20, 15, 15];
    ELSIF ft_concat IN('SH---', 'HS---') THEN
      percent_vector = ARRAY[60, 40, 0, 0, 0]; -- this rule needed for layer 2 (u1, u2)
    ELSE
      RETURN NULL; -- if code does not match any of the above, it should have been caught by the validation function. Return NULL.
    END IF;
    
    -- return the requested index, after removing all zero values
    RETURN (array_remove(percent_vector, 0))[_sp_number];

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_sk_utm01_species_translation(text, text, text, text, text, text, text)
--
-- sp_number text - the species number being requested (i.e. SPECIES 1-10 in casfri)
-- sp10 text
-- sp11 text
-- sp12 text
-- sp20 text
-- sp21 text
--
-- Determines the species code for the requested species, ignoring any preceding slots with
-- no data. For example, if only sp10 and sp20 are present, sp20 becomes SPECIES_2 in CASFRI.
--
-- Once the correct species code is identified, it is run through the lookup table and returned.
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_sk_utm01_species_translation(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_sk_utm01_species_translation(
  sp_number text,
  sp10 text,
  sp11 text,
  sp12 text,
  sp20 text,
  sp21 text
)
RETURNS text AS $$
  DECLARE
    _sp_number int := sp_number::int;
    sp_array text[]; -- array to hold species values
    sp_to_lookup text; -- the species code to be translated
  BEGIN

    -- make species array
    sp_array = ARRAY[sp10, sp11, sp12, sp20, sp21];

    -- remove NULLs
    sp_array = array_remove(sp_array, NULL);
    
    -- remove empty strings
    sp_array = array_remove(sp_array, '');
    sp_array = array_remove(sp_array, ' ');

    -- return the requested index, after removing all zero values
    sp_to_lookup = sp_array[_sp_number];
    
    RETURN TT_LookupText(sp_to_lookup, 'translation', 'species_code_mapping', 'sk_species_codes', 'casfri_species_codes', 'TRUE');

  END; 
$$ LANGUAGE plpgsql STABLE;

-------------------------------------------------------------------------------
-- TT_sfv01_countOfNotNull(text, text, text, text, text, text, text, text)
--
-- vals1 text - string list of layer 1 attributes. This is carried through to couneOfNotNull
-- vals2 text - string list of layer 2 attribtues. This is carried through to couneOfNotNull  
-- vals3 text - string list of layer 3 attributes. This is carried through to couneOfNotNull
-- vals4 text - string list of layer 4 (shrub) attributes. This is carried through to couneOfNotNull
-- vals5 text - string list of layer 5 (herb) attributes. This is carried through to couneOfNotNull
-- nvsl text
-- aquatic_class text
-- luc text
-- transp_class text
-- zero_is_null
-- 
-- Use the custom helper function:  
-- to determine if the row contains an NFL record. If it does assign a string
-- so it can be counted as a non-null layer.
-- 
-- Pass vals1-vals5 and the string/NULLs to countOfNotNull().
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_sfv01_countOfNotNull(text, text, text, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_sfv01_countOfNotNull(
  vals1 text,
  vals2 text,
  vals3 text,
  vals4 text,
  vals5 text,
  nvsl text,
  aquatic_class text,
  luc text,
  transp_class text,
  max_rank_to_consider text,
  zero_is_null text
)
RETURNS int AS $$
  DECLARE
    is_nfl text;
  BEGIN

    -- if any of the nfl functions return true, we know there is an NFL record.
    -- set is_nfl to be a valid string.
    IF tt_matchList(nvsl,'{''UK'', ''CB'', ''RK'', ''SA'', ''MS'', ''GR'', ''SB'', ''WA'', ''LA'', ''RI'', ''FL'', ''SF'', ''FP'', ''ST'', ''WASF'', ''WALA'', ''UKLA'', ''WARI'', ''WAFL'', ''WAFP'', ''WAST'',''L'',''R'',''FL''}') 
    OR tt_matchList(aquatic_class,'{''UK'', ''CB'', ''RK'', ''SA'', ''MS'', ''GR'', ''SB'', ''WA'', ''LA'', ''RI'', ''FL'', ''SF'', ''FP'', ''ST'', ''WASF'', ''WALA'', ''UKLA'', ''WARI'', ''WAFL'', ''WAFP'', ''WAST'',''L'',''R'',''FL''}') 
    OR tt_matchList(luc,'{''ALA'', ''POP'', ''REC'', ''PEX'', ''GPI'', ''BPI'', ''MIS'', ''ASA'', ''NSA'', ''OIS'', ''OUS'', ''AFS'', ''CEM'', ''WEH'', ''TOW'', ''RWC'', ''RRC'', ''TLC'', ''PLC'', ''MPC'',''PL'',''RD'',''TL'',''vegu'', ''bugp'', ''towu'', ''cmty'', ''dmgu'', ''gsof'', ''rwgu'', ''muou'', ''mg'', ''peatc'', ''lmby'', ''sdgu'', ''bupo'', ''ftow''}')
    OR tt_matchList(transp_class,'{''ALA'', ''POP'', ''REC'', ''PEX'', ''GPI'', ''BPI'', ''MIS'', ''ASA'', ''NSA'', ''OIS'', ''OUS'', ''AFS'', ''CEM'', ''WEH'', ''TOW'', ''RWC'', ''RRC'', ''TLC'', ''PLC'', ''MPC'',''PL'',''RD'',''TL'',''vegu'', ''bugp'', ''towu'', ''cmty'', ''dmgu'', ''gsof'', ''rwgu'', ''muou'', ''mg'', ''peatc'', ''lmby'', ''sdgu'', ''bupo'', ''ftow''}') THEN
      is_nfl = 'a_value';
    ELSE
      is_nfl = NULL::text;
    END IF;
    
    -- call countOfNotNull
    RETURN tt_countOfNotNull(vals1, vals2, vals3, vals4, vals5, is_nfl, max_rank_to_consider, zero_is_null);

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;

-------------------------------------------------------------------------------
-- TT_ns_nsi01_countOfNotNull(text, text, text, text, text, text, text, text)
--
-- vals1 text - string list of layer 1 attributes. This is carried through to couneOfNotNull
-- vals2 text - string list of layer 2 attribtues. This is carried through to couneOfNotNull  
-- fornon text
-- max_rank_to_consider text
-- zero_is_null
-- 
-- Determine if the row contains an NFL record. If it does assign a string
-- so it can be counted as a non-null layer.
-- 
-- Pass vals1-vals2 and the string/NULLs to countOfNotNull().
------------------------------------------------------------
--DROP FUNCTION IF EXISTS TT_ns_nsi01_countOfNotNull(text, text, text, text, text);
CREATE OR REPLACE FUNCTION TT_ns_nsi01_countOfNotNull(
  vals1 text,
  vals2 text,
  fornon text,
  max_rank_to_consider text,
  zero_is_null text
)
RETURNS int AS $$
  DECLARE
    is_nfl text;
  BEGIN

    -- if any of the nfl functions return true, we know there is an NFL record.
    -- set is_nfl to be a valid string.
    IF tt_matchList(fornon,'{''71'',''76'',''77'',''78'',''84'',''85'',''94'', ''5'',''86'',''87'',''91'',''92'',''93'',''95'',''96'',''97'',''98'',''99'', ''33'',''38'',''39'',''70'',''72'',''74'',''75'',''83'',''88'',''89''}') THEN
      is_nfl = 'a_value';
    ELSE
      is_nfl = NULL::text;
    END IF;
    
    -- call countOfNotNull
    RETURN tt_countOfNotNull(vals1, vals2, is_nfl, max_rank_to_consider, zero_is_null);

  END; 
$$ LANGUAGE plpgsql IMMUTABLE;
