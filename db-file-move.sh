#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 -s SID -d new_path [ -t | -p | -f ]
            -s Oracle SID
            -d Destination directory (root directory by default, subdirectories will be created under this directory)
            -t Dry run test mode
            -p Prompt for each step (enables you to run only specific steps)
            -f Destination is full (not root) path - only runs one step"
DRYRUN=0
PROMPT=0
DEST_ROOT=1

function db_file_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" -o -z "$2" -o -z "$3" -o -z "$4" ] && err_exit "Syntax error: usage: db_file_move con_id file type destination_directory"

if [ -z "$DEBUG" ]; then
   DEBUG=0
fi

if [ "$DEST_ROOT" -eq 1 ]; then
   fileDestDir=$4/dbf
else
   fileDestDir=$4
fi

db_dir_check $fileDestDir
if [ $? -ne 0 ]; then
   info_msg "Destination directory $fileDestDir does not exist"
   if [ "$DRYRUN" -eq 0 ]; then
      echo -n "Creating destination directory ..."
      db_mkdir $fileDestDir || err_exit "Can not create destination directory."
      echo "Done."
   fi
fi

if [ "$1" -ge 1 ]; then
   ISCDB=1
else
   ISCDB=0
fi

if [ "$ISCDB" -eq 1 ]; then
   sqlCommand="select name from v\$containers where con_id = $1;"
   pdbName=$(run_query "$sqlCommand")
fi

baseFileName=$(basename $2)

if [ "$ISCDB" -eq 0 ]; then
   fileDestination=$fileDestDir/$baseFileName
else
   if [ "$1" -gt 1 ]; then
         filePdbName=$(echo $pdbName | sed -e 's/\$//')
         fileDestination=$fileDestDir/$filePdbName/$baseFileName
         db_dir_check $(dirname $fileDestination)
         if [ $? -ne 0 ]; then
            info_msg "PDB Destination directory $(dirname $fileDestination) does not exist"
            if [ "$DRYRUN" -eq 0 ]; then
               echo -n "Creating destination directory ..."
               db_mkdir $(dirname $fileDestination) || err_exit "Can not create PDB destination directory."
               echo "Done."
            fi
         fi
   else
      fileDestination=$fileDestDir/$baseFileName
   fi
fi

if [ "$3" -eq 0 ]; then
   sqlCommand="alter database move datafile '$2' to '$fileDestination' reuse;"
else
   sqlCommand="alter database tempfile '$2' offline;"
fi

if [ "$ISCDB" -eq 1 ]; then
if [ "$1" -gt 1 ]; then
sqlCommand="alter session set container=$pdbName ;
$sqlCommand"
fi
fi

if [ "$3" -eq 1 ]; then
fileDestination=$(echo $fileDestination | sed -e 's/\.[0-9]*\.[0-9]*$/.dbf/')
sqlCommand="$sqlCommand
!$SCRIPTDIR/filecopy.sh $2 $fileDestination
alter database rename file '$2' TO '$fileDestination';
alter database tempfile '$fileDestination' online;"
fi

if [ "$DRYRUN" -eq 1 ]; then
   echo "$sqlCommand"
else
   echo -n "Moving data file $2 => $fileDestination ... "
   run_query "$sqlCommand"
   echo "Done."
fi
}

function db_redo_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" ] && err_exit "Syntax error: usage: db_redo_move destination_directory"

db_dir_check $1
if [ $? -ne 0 ]; then
   info_msg "Destination directory $1 does not exist"
   if [ "$DRYRUN" -eq 0 ]; then
      echo -n "Creating redo directory ..."
      db_mkdir $1 || err_exit "Can not create destination directory."
      echo "Done."
   fi
fi

sqlCommand="select max(GROUP#) from v\$log ;"
logMax=$(run_query "$sqlCommand")

sqlCommand="select GROUP#, THREAD#, bytes/1024/1024, MEMBERS from v\$log;"
LOGFILE=$(run_query "$sqlCommand")

[ -z "$LOGFILE" ] && err_exit "Can not determine redo log directory"

logCount=0
LOG_LIST=($LOGFILE)
GROUP_INCR=1
SQL_SCRIPT=$(mktemp)
for ((i=0; i<${#LOG_LIST[@]}; i=i+4)); do
    groupNum=${LOG_LIST[i]}
    threadNum=${LOG_LIST[i+1]}
    logSize=${LOG_LIST[i+2]}
    memberCount=${LOG_LIST[i+3]}
    logCount=$(($logCount + 1))

    sqlCommand="select member from v\$logfile where GROUP# = $groupNum ;"
    GROUPFILES=$(run_query "$sqlCommand")
    j=1
    NEW_GROUP_NUM=$(($logMax + $GROUP_INCR))
    echo -n "alter database add logfile thread $threadNum group $NEW_GROUP_NUM " >> $SQL_SCRIPT
    for GROUP_LOG_FILE in $GROUPFILES
    do
        [ -z "$GROUP_LOG_FILE" ] && err_exit "Can get redo log path for group $groupNum"
        LOG_PATH=$(dirname $GROUP_LOG_FILE)
        [ "$j" -eq 1 ] && echo -n "(" >> $SQL_SCRIPT
        [ "$j" -gt 1 ] && echo -n "," >> $SQL_SCRIPT
        echo -n "'$1/redo_${NEW_GROUP_NUM}_${j}.log'" >> $SQL_SCRIPT
        j=$(($j + 1))
    done
    echo ") size ${logSize}M reuse;" >> $SQL_SCRIPT
    GROUP_INCR=$(($GROUP_INCR + 1))
done

echo "Creating new log files ..."
if [ "$DRYRUN" -eq 1 ]; then
   cat $SQL_SCRIPT
else
   sqlCommand="@$SQL_SCRIPT"
   run_query "$sqlCommand"
   rm $SQL_SCRIPT
fi
echo "Done."

dropCount=0
while true; do
sqlCommand="alter system switch logfile;"
result=$(run_query "$sqlCommand")
sqlCommand="select GROUP#,STATUS from v\$log ;"
allRedo=($(run_query "$sqlCommand"))
for ((i=0; i<${#allRedo[@]}; i=i+2)); do
    logGroup=${allRedo[i]}
    logStatus=${allRedo[i+1]}
    if [ "$logGroup" -gt "$logMax" ]; then
       continue
    fi
    if [ "$logStatus" = "INACTIVE" ]; then
       dropCount=$(($dropCount + 1))
       sqlCommand="alter database drop logfile group $logGroup ;"
       if [ "$DRYRUN" -eq 1 ]; then
          echo "$sqlCommand"
       else
          echo "Dropping log group $logGroup"
          run_query "$sqlCommand"
          echo "Done."
       fi
    fi
done
[ "$dropCount" -ge "$logCount" ] && break
done
}

function db_fra_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" ] && err_exit "Syntax error: usage: db_fra_move destination_directory"
[ -z "$fraLocation" ] && warn_msg "FRA location not set"

if [ "$DEST_ROOT" -eq 1 ]; then
   fileDestDir=$1/fra
else
   fileDestDir=$1
fi

if [ -n "$fraLocation" ]; then
   echo "Relocating the FRA to $fileDestDir ..."
   db_dir_check $fileDestDir
   if [ $? -ne 0 ]; then
      info_msg "Destination directory $fileDestDir does not exist"
      if [ "$DRYRUN" -eq 0 ]; then
         echo -n "Creating FRA directory ..."
         db_mkdir $fileDestDir || err_exit "Can not create destination directory."
         echo "Done."
      fi
   fi
   sqlCommand="alter system set db_recovery_file_dest='$fileDestDir' scope=both;"
   if [ "$DRYRUN" -eq 1 ]; then
      echo "$sqlCommand"
   else
      run_query "$sqlCommand"
      echo "Done."
   fi
fi
}

function db_arch_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" ] && err_exit "Syntax error: usage: db_arch_move destination_directory"
[ -z "$archStatus" ] && warn_msg "Can not determine archive log status"

if [ "$DEST_ROOT" -eq 1 ]; then
   fileDestDir=$1/log
else
   fileDestDir=$1
fi

if [ -n "$archStatus" ]; then
   if [ "$archStatus" = "Enabled" ]; then
      if [ "$archLogLocation" = "USE_DB_RECOVERY_FILE_DEST" ]; then
         echo "Archive logging to FRA enabled."
      else
         db_dir_check $fileDestDir
         if [ $? -ne 0 ]; then
            info_msg "Destination directory $fileDestDir does not exist"
            if [ "$DRYRUN" -eq 0 ]; then
               echo -n "Creating log directory ..."
               db_mkdir $fileDestDir || err_exit "Can not create destination directory."
               echo "Done."
            fi
         fi
         echo "Archive logging enabled to $archLogLocation"
         echo "Switching logging to $fileDestDir ..."
         sqlCommandA="alter system set log_archive_dest_1='location=$fileDestDir';"
         sqlCommandB="archive log start '$fileDestDir';"
         sqlCommandC="alter system archive log current;"
         if [ "$DRYRUN" -eq 1 ]; then
            echo "$sqlCommandA"
            echo "$sqlCommandB"
            echo "$sqlCommandC"
         else
            run_query "$sqlCommandA"
            run_query "$sqlCommandB"
            run_query "$sqlCommandC"
            echo "Done."
         fi
      fi
   fi
fi
}

function db_control_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" ] && err_exit "Syntax error: usage: db_control_move destination_directory"
fileDestDir=$1

echo "Warning: control file move is disruptive."
ask_prompt

if [ "$DEST_ROOT" -eq 1 ]; then
   recoDestDir=$fileDestDir/fra
else
   recoDestDir=$fileDestDir
fi

restoreControlFile=$(echo $controlFiles | awk '{print $1}')
newControlFileA=$fileDestDir/control01.ctl
newControlFileB=$recoDestDir/control02.ctl

echo "Backing up spfile ..."
sqlCommand="create pfile='?/dbs/init@.ora-backup' from spfile;"
if [ "$DRYRUN" -eq 1 ]; then
   echo "$sqlCommand"
else
   run_query "$sqlCommand"
fi

rmanCommand="alter system set control_files='$newControlFileA','$newControlFileB' scope=spfile;
shutdown immediate;
startup nomount;
restore controlfile from '$restoreControlFile';
alter database mount;
alter database open;"

if [ "$DRYRUN" -eq 1 ]; then
   echo "$rmanCommand"
else
   run_rman "$rmanCommand"
fi
}

while getopts "s:d:tpf" opt
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
    p)
      PROMPT=1
      ;;
    f)
      DEST_ROOT=0
      PROMPT=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$DEST_DIR" -o -z "$ORACLE_SID" ]; then
   err_exit
fi

[ "$DEST_ROOT" -eq 1 ] && DEST_DIR=$DEST_DIR/$ORACLE_SID

get_db_path

skipStep=0
if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move data files ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
allDbFiles=($(get_db_files))
for ((i=0; i<${#allDbFiles[@]}; i=i+3)); do
   db_file_move ${allDbFiles[i]} ${allDbFiles[i+1]} ${allDbFiles[i+2]} $DEST_DIR
done
fi

[ "$PROMPT" -eq 1 -a "$DEST_ROOT" -eq 0 ] && exit 0

if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move temp files ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
allTempFiles=($(get_temp_files))
for ((i=0; i<${#allTempFiles[@]}; i=i+3)); do
   db_file_move ${allTempFiles[i]} ${allTempFiles[i+1]} ${allTempFiles[i+2]} $DEST_DIR
done
fi

[ "$PROMPT" -eq 1 -a "$DEST_ROOT" -eq 0 ] && exit 0

if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move redo ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
   db_redo_move $DEST_DIR
fi

[ "$PROMPT" -eq 1 -a "$DEST_ROOT" -eq 0 ] && exit 0

if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move FRA ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
   db_fra_move $DEST_DIR
fi

[ "$PROMPT" -eq 1 -a "$DEST_ROOT" -eq 0 ] && exit 0

if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move archive logs ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
   db_arch_move $DEST_DIR
fi

[ "$PROMPT" -eq 1 -a "$DEST_ROOT" -eq 0 ] && exit 0

if [ "$PROMPT" -eq 1 ]; then
   ask_prompt "About to move control files ..."
   skipStep=$?
fi

if [ "$skipStep" -eq 0 ]; then
   db_control_move $DEST_DIR
fi
