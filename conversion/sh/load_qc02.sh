#!/bin/bash -x

# This script loads the Quebec (QC02) into PostgreSQL

# There is a updated version of this dataset: QC/SourceDataset/v.00.04/PEE_ORI_PROV.gdb
# However here we load the original to match the CASFRI04 loading script

# The format of the source dataset is a geodatabase

# The year of photography is in a photo year shapefile that needs to loaded separately

# Load into a target table in the schema defined in the config file.

# If the table already exists, it can be overwritten by setting the "overwriteFRI" variable 
# in the configuration file.

######################################## Set variables #######################################

# Load config variables from local config file
if [ -f ../../config.sh ]; then 
  source ../../config.sh
else
  echo ERROR: NO config.sh FILE
  exit 1
fi

srcFileName=DDE_20K_PEU_ECOFOR_ORI_VUE_SE
gdbFileName=$srcFileName
srcFullPath="$friDir/QC/QC02/PEE_ORI_PROV.gdb"

prjFile="./../canadaAlbersEqualAreaConic.prj"
fullTargetTableName=$targetFRISchema.qc02

if [ $overwriteFRI == True ]; then
  overwrite_tab=-overwrite
else 
  overwrite_tab=
fi

########################################## Process ######################################

#Create schema if it doesn't exist
"$gdalFolder/ogrinfo" "PG:host=$pghost port=$pgport dbname=$pgdbname user=$pguser password=$pgpassword" -sql "CREATE SCHEMA IF NOT EXISTS $targetFRISchema";

#Run ogr2ogr
"$gdalFolder/ogr2ogr" \
-f "PostgreSQL" "PG:host=$pghost port=$pgport dbname=$pgdbname user=$pguser password=$pgpassword" "$srcFullPath" "gdbFileName" \
-nln $fullTargetTableName \
-lco PRECISION=NO \
-lco GEOMETRY_NAME=wkb_geometry \
-t_srs $prjFile \
-sql "SELECT *, '$srcFileName' AS src_filename FROM '$gdbFileName'" \
-progress $overwrite_tab