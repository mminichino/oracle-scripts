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

function warn_prompt {
echo "WARNING: This operation is destructive and can not be undone."
echo -n "Enter Oracle SID to contine: "
read ANSWER

if [ "$ANSWER" != "$ORACLE_SID" ]; then
   echo ""
   echo "Aborting ..."
   exit 1
fi
}

function ask_prompt {
echo -n "Continue? (y/n): "
read ANSWER

if [ "$ANSWER" != "y" ]; then
   echo ""
   echo "Aborting ..."
   exit 1
fi
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
if [ $? -ne 0 -a "$IGNORE_SQL_ERROR" -eq 0 ]; then
   err_exit "Query execution failed: $1"
fi
}

function run_rman {
[ -z "$1" ] && err_exit "run_rman: commands text argument can not be empty."

which rman 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "rman not found"

if [ -z "$IGNORE_RMAN_ERROR" ]; then
   IGNORE_RMAN_ERROR=0
fi

if [ -n "$RMAN_DEBUG" ]; then
if [ "$RMAN_DEBUG" -eq 1 ]; then
echo "[debug] ==== Begin RMAN Script ====" 1>&2
cat -nvET << EOF 1>&2
connect target /
$1
EOF
echo "[debug] ==== End RMAN Script ====" 1>&2
fi
fi

rman <<EOF
connect target /
$1
EOF
if [ $? -ne 0 -a "$IGNORE_RMAN_ERROR" -eq 0 ]; then
   err_exit "RMAN script failed: $1"
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

function drop_database {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID not set"
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set."

echo "ORACLE HOME   = $ORACLE_HOME"
echo "ORACLE SID    = $ORACLE_SID"

echo "This will permanently delete SID $ORACLE_SID !!!"
echo -n "Are you sure? [Y/N]? "
read ANSWER

if [ "$ANSWER" != "Y" ]
then
   echo "Aborting ..."
   exit 1
fi

which crsctl > /dev/null 2>&1

if [ "$?" -eq 0 ]
then
   echo "CRS found ... Removing restart for instance ..."
   CRSVERSION=$(srvctl -version | awk '{print $NF}' | sed -e 's/^\([0-9]*\)\..*$/\1/')
   if [ "$CRSVERSION" -lt 12 ]; then
      srvctl remove database -d $ORACLE_SID -f -y
   else
      srvctl remove database -db $ORACLE_SID -force -noprompt
   fi
   echo "Done."
fi

echo "Shutting database down... "

sqlCommand="shutdown abort"
run_query "$sqlCommand"

echo "Done."
echo "Deleting database... "

IGNORE_RMAN_ERROR=1
rmanScript="startup force mount
sql 'alter system enable restricted session';
drop database including backups noprompt;"
run_rman "$rmanScript"

echo "Done."
echo "Shutting instance down... "

sqlCommand="shutdown abort"
run_query "$sqlCommand"

echo "Done."
echo "Removing database files ..."

[[ -z "$ORACLE_SID" ]] && exit
[[ -f $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ]] && rm $ORACLE_HOME/dbs/init${ORACLE_SID}.ora
[[ -f $ORACLE_HOME/dbs/orapw${ORACLE_SID} ]] && rm $ORACLE_HOME/dbs/orapw${ORACLE_SID}
[[ -f $ORACLE_HOME/dbs/hc_${ORACLE_SID}.dat ]] && rm $ORACLE_HOME/dbs/hc_${ORACLE_SID}.dat
[[ -f $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora ]] && rm $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora
[ -d $ORACLE_BASE/diag/rdbms/${ORACLE_SID} -a -n "$ORACLE_BASE" ] && rm -rf $ORACLE_BASE/diag/rdbms/${ORACLE_SID}

if [ -f $ORACLE_HOME/network/admin/tnsnames.ora ]; then
   echo "Cleaning tnsnames.ora"
   sed -i -e "/$ORACLE_SID.*=/,/^ *\$/d" $ORACLE_HOME/network/admin/tnsnames.ora
fi

LISTENER_CONFIG=$(lsnrctl status | grep "^Listener Parameter File" | awk '{print $NF}')

if [ -n "$LISTENER_CONFIG" ]; then
   echo "Cleaning listener.ora"
   sed -i -e "/SID_LIST_LISTENER.*=/,/^ *\$/d" $LISTENER_CONFIG
fi

echo "Done."
}

function asm_cli {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID is not set"
HOST_GRID_HOME=$(dirname $(dirname $(ps -ef |grep evmd.bin | grep -v grep | awk '{print $NF}')))
[ -z "$HOST_GRID_HOME" ] && err_exit "Oracle CRS does not seem to be running"
HOST_ASM_INSTANCE=$(ps -ef | grep pmon_+ASM | grep -v grep | awk '{print $NF}' | sed -e 's/^.*_pmon_//')
[ -z "$HOST_ASM_INSTANCE" ] && err_exit "ASM does not appear to be running"

export ORACLE_HOME_SAVE=$ORACLE_HOME
export PATH_SAVE=$PATH
export ORACLE_SID_SAVE=$ORACLE_SID

export ORACLE_HOME=$HOST_GRID_HOME
export PATH=$ORACLE_HOME/bin:$PATH
export ORACLE_SID=$HOST_ASM_INSTANCE

asmcmd $@
returnCode=$?

export ORACLE_HOME=$ORACLE_HOME_SAVE
export PATH=$PATH_SAVE
export ORACLE_SID=$ORACLE_SID_SAVE
return $returnCode
}

function asm_path_check {
[ -z "$1" ] && err_exit "Syntax error: usage: asm_path_check path"
asm_cli ls -ls $1 >/dev/null 2>&1
return $?
}

function asm_isdir {
[ -z "$1" ] && err_exit "Syntax error: usage: asm_path_check path"
result=$(asm_cli ls -ld $1 | sed -e '1d' | awk '{print NF}' 2>&1)
if [ "$result" = "2" -o "$result" = "4" ]; then
   return 0
else
   return 1
fi
}

function asm_isfile {
[ -z "$1" ] && err_exit "Syntax error: usage: asm_path_check path"
result=$(asm_cli ls -ld $1 | sed -e '1d' | awk '{print NF}' 2>&1)
if [ "$result" = "8" -o "$result" = "10" ]; then
   return 0
else
   return 1
fi
}

function db_file_check {
[ -z "$1" ] && err_exit "Syntax error: usage: db_file_chedk path"

if [ -z "$(echo $1 | sed -e '/^+/d')" ]; then
   asm_path_check $1
   if [ $? -eq 0 ]; then
      asm_isfile $1
      return $?
   else
      return 1
   fi
else
   if [ -f "$1" ]; then
      return 0
   else
      return 1
   fi
fi
}

function db_dir_check {
[ -z "$1" ] && err_exit "Syntax error: usage: db_dir_check path"

if [ -z "$(echo $1 | sed -e '/^+/d')" ]; then
   asm_path_check $1
   if [ $? -eq 0 ]; then
      asm_isdir $1
      return $?
   else
      return 1
   fi
else
   if [ -d "$1" ]; then
      return 0
   else
      return 1
   fi
fi
}

function db_mkdir {
[ -z "$1" ] && err_exit "Syntax error: usage: db_mkdir path"

if [ -z "$(echo $1 | sed -e '/^+/d')" ]; then
   db_dir_check $(dirname $1)
   if [ $? -ne 0 ]; then
      db_mkdir $(dirname $1)
   fi
   asm_cli mkdir $1
   return $?
else
   mkdir -p $1
   return $?
fi
}
