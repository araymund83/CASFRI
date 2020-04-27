------------------------------------------------------------------------------
-- CASFRI Sample workflow file for CASFRI v5 beta
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
-- DROP GeoHistory functions
--------------------------------------------
DROP FUNCTION IF EXISTS TT_GeoHistory(name, name, name, name, name, text, text[]);
DROP FUNCTION IF EXISTS TT_RowIsValid(text[]);
DROP FUNCTION IF EXISTS TT_HasPrecedence(text, text, text, text, boolean, boolean);
DROP FUNCTION IF EXISTS TT_GeoHistoryOblique(name, name, name, name, name, text, text[], double precision, double precision);

DROP FUNCTION IF EXISTS TT_GeoOblique(geometry, int, double precision, double precision);
--------------------------------------------
-- DROP test tables
--------------------------------------------
DROP SCHEMA IF EXISTS geohistory CASCADE;


