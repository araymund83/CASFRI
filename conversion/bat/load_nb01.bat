:: This script loads the New Brunswick FRI data into PostgreSQL

:: The format of the source dataset is four shapefiles named Forest.shp, 
:: Non Forest.shp, Waterbody.shp, and wetland.shp
::
:: These four files are combined into a single PostgreSQL table
:: This is done using the -append argument. Note that -update is also 
:: needed in order to append in PostgreSQL. -addfields is also needed 
:: because columns do not match between tables.

:: The year of photography is included in the attributes table (DATAYR)

:: Load into a target table in the schema defined in the config file.

:: If the table already exists, it can be overwritten by setting the "overwriteFRI" variable 
:: in the configuration file.

:: Workflow is to load the first table normally, then append the others
:: Use -nlt PROMOTE_TO_MULTI to take care of any mixed single and multi part geometries

:: stdlab attribute needed to make cas id. Only present in forest.shp.
:: add as attribute with 0 for other files

:: #################################### Set variables ######################################

SETLOCAL

CALL .\common.bat

SET NB_subFolder=NB\NB01\

SET srcNameWater=Waterbody
SET ogrTabWater=%srcNameWater%
SET srcWaterFullPath="%friDir%\%NB_subFolder%%ogrTabWater%.shp"

SET srcNameNonForest=NonForest
SET ogrTabNonForest=Non Forest
SET srcNonForestFullPath="%friDir%\%NB_subFolder%%ogrTabNonForest%.shp"

SET srcNameWetland=wetland
SET ogrTabWetland=%srcNameWetland%
SET srcWetlandFullPath="%friDir%\%NB_subFolder%%ogrTabWetland%.shp"

SET srcNameForest=Forest
SET ogrTabForest=%srcNameForest%
SET srcForestFullPath="%friDir%\%NB_subFolder%%ogrTabForest%.shp"

SET fullTargetTableName=%targetFRISchema%.nb01

:: ########################################## Process ######################################

::### FILE 1 ###
::Load Waterbody table first. SHAPE_AREA field has a value larger than the numeric type assigned in PostgreSQL. Returns error when loading. Unable to edit field precision on import.
::Solution is to load the Waterbody table first with -lco PRECISION=NO. This changes the type from NUMERIC to DOUBLE. All other tables will be converted to DOUBLE when appended.
"%gdalFolder%/ogr2ogr" ^
-f "PostgreSQL" %pg_connection_string% %srcWaterFullPath% ^
-nln %fullTargetTableName% %layer_creation_option% ^
-nlt PROMOTE_TO_MULTI ^
-sql "SELECT *, '%srcNameWater%' AS src_filename, 0 AS stdlab FROM ""%ogrTabWater%""" ^
-progress %overwrite_tab%

::### FILE 2 ###
"%gdalFolder%/ogr2ogr" ^
-update -append -addfields ^
-f "PostgreSQL" %pg_connection_string% %srcNonForestFullPath% ^
-nln %fullTargetTableName% ^
-t_srs %prjFile% ^
-nlt PROMOTE_TO_MULTI ^
-sql "SELECT *, '%srcNameNonForest%' AS src_filename, 0 AS stdlab FROM ""%ogrTabNonForest%""" ^
-progress

::### FILE 3 ###
"%gdalFolder%/ogr2ogr" ^
-update -append -addfields ^
-f "PostgreSQL" %pg_connection_string% %srcWetlandFullPath% ^
-nln %fullTargetTableName% ^
-t_srs %prjFile% ^
-nlt PROMOTE_TO_MULTI ^
-sql "SELECT *, '%srcNameWetland%' AS src_filename, 0 AS stdlab FROM ""%ogrTabWetland%""" ^
-progress

::## File 4 ###
"%gdalFolder%/ogr2ogr" ^
-update -append -addfields ^
-f "PostgreSQL" %pg_connection_string% %srcForestFullPath% ^
-nln %fullTargetTableName% ^
-t_srs %prjFile% ^
-nlt PROMOTE_TO_MULTI ^
-sql "SELECT *, '%srcNameForest%' AS src_filename FROM ""%ogrTabForest%""" ^
-progress

ENDLOCAL