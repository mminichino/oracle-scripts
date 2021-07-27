#!/bin/bash
#
#
function print_usage {
if [ -n "$PRINT_USAGE" ]; then
   echo "$PRINT_USAGE"
fi
}

function err_exit {
   if [ -n "$1" ]; then
      echo "[!] Error: $1"
   else
      print_usage
   fi
   exit 1
}

function warn_msg {
   if [ -n "$1" ]; then
      echo "[i] Warning: $1"
   fi
}

function info_msg {
   if [ -n "$1" ]; then
      echo "[i] Notice: $1"
   fi
}

function get_password {
   while true
   do
      echo -n "Password: "
      read -s PASSWORD
      echo ""
      echo -n "Retype Password: "
      read -s CHECK_PASSWORD
      echo ""
      if [ "$PASSWORD" != "$CHECK_PASSWORD" ]; then
         echo "Passwords do not match"
      else
         break
      fi
   done
   export ORACLE_PWD=$PASSWORD
}

function run_query {
[ -z "$1" ] && err_exit "run_query: query text argument can not be empty."

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

if [ -z "$IGNORE_SQL_ERROR" ]; then
   IGNORE_SQL_ERROR=0
fi

if [ -z "$SHOW_HEADERS" ]; then
   SHOW_HEADERS=0
fi

if [ "$SHOW_HEADERS" -eq 1 ]; then
displayOptions="set linesize 200;
set pagesize 100;"
else
displayOptions="set heading off;
set pagesize 0;
set feedback off;"
fi

if [ -n "$QUERY_DEBUG" ]; then
if [ "$QUERY_DEBUG" -eq 1 ]; then
echo "[debug] ==== Begin Query Text ====" 1>&2
cat -nvET << EOF 1>&2
whenever sqlerror exit sql.sqlcode
whenever oserror exit
$displayOptions
$1
exit;
EOF
echo "[debug] ==== End Query Text ====" 1>&2
fi
fi

if [ -n "$QUERY_DEBUG_EXIT" ]; then
if [ "$QUERY_DEBUG_EXIT" -eq 1 ]; then
   exit 0
fi
fi

sqlplus -S / as sysdba << EOF 2>&1
whenever sqlerror exit sql.sqlcode
whenever oserror exit
$displayOptions
$1
exit;
EOF
if [ $? -ne 0 -a $IGNORE_SQL_ERROR -eq 0 ]; then
   err_exit "Query execution failed: $1"
fi
}

function get_db_path {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"

if [ -z "$DEBUG" ]; then
   DEBUG=0
fi

sqlCommand="select name from v\$containers where con_id = 0;"
ISCDB=$(run_query "$sqlCommand")

if [ -z "$ISCDB" ]; then
   cdbConId=1
else
   cdbConId=0
fi

sqlCommand="select name from v\$datafile where ts# = 0 and con_id = $cdbConId ;"
sysDataFile=$(run_query "$sqlCommand")

dataFilePath=$(dirname $sysDataFile)

sqlCommand="select destination from v\$archive_dest where dest_name='LOG_ARCHIVE_DEST_1';"
archLogLocation=$(run_query "$sqlCommand")

sqlCommand="select name from v\$recovery_file_dest where con_id = 0;"
recoveryLocation=$(run_query "$sqlCommand")

sqlCommand="select value from v\$parameter where name = 'audit_file_dest' ;"
auditFileDest=$(run_query "$sqlCommand")

if [ "$DEBUG" -eq 1 ]; then
   echo "CON_ID:              $cdbConId"
   echo "Data File Location:  $dataFilePath"
   echo "Arch Log Location:   $archLogLocation"
   echo "Recovery Location:   $recoveryLocation"
   echo "Audit File Location: $auditFileDest"
fi
}

function get_db_files {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"

if [ -z "$DEBUG" ]; then
   DEBUG=0
fi

if [ -z "$DRYRUN" ]; then
   DRYRUN=0
fi

sqlCommand="select con_id, name, 0 from v\$datafile ;"
run_query "$sqlCommand"
}

function get_temp_files {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"

if [ -z "$DEBUG" ]; then
   DEBUG=0
fi

if [ -z "$DRYRUN" ]; then
   DRYRUN=0
fi

sqlCommand="select con_id, name, 1 from v\$tempfile ;"
run_query "$sqlCommand"
}

function db_file_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$1" -o -z "$2" -o -z "$3" -o -z "$4" ] && err_exit "Syntax error: usage: db_file_move con_id file type destination_directory"

if [ -z "$DEBUG" ]; then
   DEBUG=0
fi

if [ ! -d "$4" ]; then
   info_msg "Destination directory $4 does not exist"
   if [ "$DRYRUN" -eq 0 ]; then
      echo -n "Creating destination directory ..."
      mkdir -p $4 || err_exit "Can not create destination directory."
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
   fileDestination=$4/$baseFileName
else
   if [ "$1" -gt 1 ]; then
         filePdbName=$(echo $pdbName | sed -e 's/\$//')
         fileDestination=$4/$filePdbName/$baseFileName
         if [ ! -d "$fileDestination" ]; then
            info_msg "Destination directory $fileDestination does not exist"
            if [ "$DRYRUN" -eq 0 ]; then
               echo -n "Creating destination directory ..."
               mkdir -p $fileDestination || err_exit "Can not create destination directory."
               echo "Done."
            fi
         fi
   else
      fileDestination=$4/$baseFileName
   fi
fi

echo "Moving data file $2 to $fileDestination ..."
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
sqlCommand="$sqlCommand
!cp -p $2 $fileDestination ;
alter database rename file '$2' to '$fileDestination';
alter database tempfile '$fileDestination' online;"
fi

if [ "$DRYRUN" -eq 1 ]; then
   echo "$sqlCommand"
else
   echo "Moving data file $2 => $fileDestination ..."
   run_query "$sqlCommand"
   echo "Done."
fi
echo "Done."
}

function db_redo_move {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"

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
    for GROUP_LOG_FILE in $GROUPFILES
    do
        [ -z "$GROUP_LOG_FILE" ] && err_exit "Can get redo log path for group $groupNum"
        LOG_PATH=$(dirname $GROUP_LOG_FILE)
        echo "alter database add logfile thread $threadNum group $NEW_GROUP_NUM '$LOG_PATH/stb_redo_${NEW_GROUP_NUM}_${j}.log' size ${logSize}M ;" >> $SQL_SCRIPT
        j=$(($j + 1))
    done
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

echo "max = $logMax count = $logCount"
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
echo "drop = $dropCount"
[ "$dropCount" -ge "$logCount" ] && break
done
}
