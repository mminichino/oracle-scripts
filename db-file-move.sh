#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 -s SID -d new_path"
DRYRUN=0

while getopts "s:d:t" opt
do
  case $opt in
    s)
      export ORACLE_SID=$OPTARG
      ;;
    d)
      DEST_DIR=$OPTARG
      ;;
    t)
      DRYRUN=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$DEST_DIR" -o -z "$ORACLE_SID" ]; then
   err_exit
fi

get_db_path

allDbFiles=($(get_db_files))
for ((i=0; i<${#allDbFiles[@]}; i=i+3)); do
   db_file_move ${allDbFiles[i]} ${allDbFiles[i+1]} ${allDbFiles[i+2]} $DEST_DIR
done

allTempFiles=($(get_temp_files))
for ((i=0; i<${#allTempFiles[@]}; i=i+3)); do
   db_file_move ${allTempFiles[i]} ${allTempFiles[i+1]} ${allTempFiles[i+2]} $DEST_DIR
done

db_redo_move