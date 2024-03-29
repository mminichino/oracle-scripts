#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
unset PRIMARY_SID
unset REMOTE_HOST
REMOTE_SIDE=0
DG_STOP=0
DROP_DB=0
STOP_APPLY=0
PREP_LOGICAL=0
OPEN_LOGICAL=0
PUSH_FILES_TO_REMOTE=0
PRINT_USAGE="Usage: $0 -p SID -h remote_host
          -p Oracle primary SID
          -h Remote database host
          -r Standby side mode
          -k Stop sync
          -c Check logical standby compatibility
          -s Stop redo apply on standby
          -m Build Log Miner directory on primary
          -l Open logical standby database
          -d Drop database"

function check_logical_standby_support {
sqlCommand="column table_name format a30
column column_name format a30
column data_type format a20
select table_name, column_name, data_type from dba_logstdby_unsupported ;"

result=$(run_query "$sqlCommand")

if [ -z "$result" ]; then
   info_msg "No unsupported objects found."
else
   echo "$result"
fi
}

function shutdown_standby {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   shutdown abort
   exit;
EOF
}

function get_db_path {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

ISCDB=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\$containers where con_id = 0;
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error getting CDB status"

if [ -z "$ISCDB" ]; then
   cdbConId=1
else
   cdbConId=0
fi

sysDataFile=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\$datafile where ts# = 0 and con_id = $cdbConId ;
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

dataFilePath=$(dirname $sysDataFile)

archLogLocation=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select destination from v\$archive_dest where dest_name='LOG_ARCHIVE_DEST_1';
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

recoveryLocation=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\$recovery_file_dest where con_id = 0;
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

auditFileDest=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select value from v\$parameter where name = 'audit_file_dest' ;
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

}

function copy_to_remote {
[ -z "$PRIMARY_SID" ] && err_exit "Standby SID not set"
[ -z "$REMOTE_HOST" ] && err_exit "Remote host not set"
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"
export ORACLE_SID=$PRIMARY_SID
ORA_USER=$(id -un)

ssh -o BatchMode=yes $REMOTE_HOST ls >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not ssh to remote host $REMOTE_HOST - configure public key auth"

echo -n "Copying init${ORACLE_SID}.ora to $REMOTE_HOST ..."
scp -q -o BatchMode=yes $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ${ORA_USER}@${REMOTE_HOST}:$ORACLE_HOME/dbs
[ $? -ne 0 ] && err_exit "Can not copy pfile to remote host."
echo "Done."

echo -n "Copying password file to $REMOTE_HOST ..."
scp -q -o BatchMode=yes $ORACLE_HOME/dbs/orapw${ORACLE_SID} ${ORA_USER}@${REMOTE_HOST}:$ORACLE_HOME/dbs/orapw${ORACLE_SID}
[ $? -ne 0 ] && err_exit "Can not copy password file to remote host."
echo "Done."

echo -n "Creating data path $dataFilePath on $REMOTE_HOST ..."
ssh -o BatchMode=yes $REMOTE_HOST "mkdir -p $dataFilePath" >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not make data path $dataFilePath on remote host."
echo "Done."

echo -n "Creating recovery path $recoveryLocation on $REMOTE_HOST ..."
ssh -o BatchMode=yes $REMOTE_HOST "mkdir -p $recoveryLocation" >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not make recovery path $recoveryLocation on remote host."
echo "Done."

if [ -n "$archLogLocation" ]; then
   echo -n "Creating archive log location $archLogLocation on $REMOTE_HOST ..."
   ssh -o BatchMode=yes $REMOTE_HOST "mkdir -p $archLogLocation" >/dev/null 2>&1
   [ $? -ne 0 ] && err_exit "Can not make log path $archLogLocation on remote host."
   echo "Done."
fi

echo -n "Creating audit path $auditFileDest on $REMOTE_HOST ..."
ssh -o BatchMode=yes $REMOTE_HOST "mkdir -p $auditFileDest" >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not make audit path $auditFileDest on remote host."
echo "Done."
}

function create_pfile {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

FL_STATUS=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select force_logging from v\$database;
   exit;
EOF
)

if [ "$FL_STATUS" == "NO" ]; then
echo -n "Enabling force logging ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database force logging;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to enable force logging"
else
   echo "Done."
fi
fi

FB_STATUS=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select flashback_on from v\$database;
   exit;
EOF
)

if [ "$FB_STATUS" == "NO" ]; then
echo -n "Enabling flashback ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database flashback on;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to enable flashback"
else
   echo "Done."
fi
fi

echo -n "Creating pfile ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   create pfile from spfile;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to create pfile"
else
   echo "Done."
fi
}

function set_primary_db_parameters {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo "Set database parameters ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set log_archive_config='dg_config=($PRIMARY_SID,${PRIMARY_SID}_STB)';
   alter system set log_archive_dest_2='service=${PRIMARY_SID}_STB noaffirm async valid_for=(online_logfiles,primary_role) db_unique_name=${PRIMARY_SID}_STB';
   alter system set log_archive_dest_state_2=enable;
   alter system set remote_login_passwordfile=exclusive scope=spfile;
   alter system set fal_server=${PRIMARY_SID}_STB;
   alter system set standby_file_management=auto;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set parameters"
else
   echo "Done."
fi
}

function create_standby_logs {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

LOGFILE=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select GROUP#, THREAD#, bytes/1024/1024, MEMBERS from v\$log;
   exit;
EOF
)

[ $? -ne 0 ] && err_exit "Error getting redo log location"
[ -z "$LOGFILE" ] && err_exit "Can not determine redo log directory"

LOG_LIST=($LOGFILE)
GROUP_INCR=0
SQL_SCRIPT=$(mktemp)
for ((i=0; i<${#LOG_LIST[@]}; i=i+4)); do
    groupNum=${LOG_LIST[i]}
    threadNum=${LOG_LIST[i+1]}
    logSize=${LOG_LIST[i+2]}
    memberCount=${LOG_LIST[i+3]}

GROUPFILES=$(sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select member from v\$logfile where GROUP# = $groupNum ;
   exit;
EOF
)
    j=1
    NEW_GROUP_NUM=$((11 + $GROUP_INCR))
    for GROUP_LOG_FILE in $GROUPFILES
    do
        [ -z "$GROUP_LOG_FILE" ] && err_exit "Can get redo log path for group $groupNum"
        LOG_PATH=$(dirname $GROUP_LOG_FILE)
        echo "alter database add standby logfile thread $threadNum group $NEW_GROUP_NUM '$LOG_PATH/stb_redo_${NEW_GROUP_NUM}_${j}.log' size ${logSize}M ;" >> $SQL_SCRIPT
        j=$(($j + 1))
    done
    GROUP_INCR=$(($GROUP_INCR + 1))

done

echo "Creating standby log files ..."
sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   @$SQL_SCRIPT
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to create standby log files, SQL transcript: $SQL_SCRIPT"
else
   echo "Done."
   rm $SQL_SCRIPT
fi
}

function listener_primary_config {

[ -z "$PRIMARY_SID" ] && err_exit "Standby SID not set"
[ -z "$REMOTE_HOST" ] && err_exit "Remote host not set"

which tnsping  >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "This utility requires tnsping"

tnsping $REMOTE_HOST >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not connect to listener on host $REMOTE_HOST"

LSNR_RUNNING=0
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

which lsnrctl >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "lsnrctl not found"

lsnrctl status >/dev/null 2>&1
if [ $? -eq 0 ]; then
   info_msg "Listener running"
   LSNR_RUNNING=1
else
   err_exit "Listener not running - Please configure and start the listener."
fi

echo "Configuring instance ${PRIMARY_SID}_STB on node $REMOTE_HOST"

grep -iw ^${PRIMARY_SID}_STB $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "Instance ${PRIMARY_SID}_STB already configured"
else
cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
${PRIMARY_SID^^}_STB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $REMOTE_HOST)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $PRIMARY_SID)
    )
  )

EOF
fi

LISTENER_CONFIG=$(lsnrctl status | grep "^Listener Parameter File" | awk '{print $NF}')

[ -z "$LISTENER_CONFIG" ] && err_exit "Can not find listener config file"

grep -iw ^SID_LIST_LISTENER $LISTENER_CONFIG 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "SID_LIST_LISTENER already configured"
else
cat <<EOF >> $LISTENER_CONFIG

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $PRIMARY_SID)
      (ORACLE_HOME = $ORACLE_HOME)
      (SID_NAME = $PRIMARY_SID)
    )
  )

EOF
fi

lsnrctl reload

}

function listener_standby_config {

[ -z "$PRIMARY_SID" ] && err_exit "Standby SID not set"
[ -z "$REMOTE_HOST" ] && err_exit "Remote host not set"

which tnsping  >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "This utility requires tnsping"

tnsping $REMOTE_HOST >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Can not connect to listener on host $REMOTE_HOST"

LSNR_RUNNING=0
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

which lsnrctl >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "lsnrctl not found"

lsnrctl status >/dev/null 2>&1
if [ $? -eq 0 ]; then
   info_msg "Listener running"
   LSNR_RUNNING=1
else
   err_exit "Listener not running - Please configure and start the listener."
fi

LISTENER_CONFIG=$(lsnrctl status | grep "^Listener Parameter File" | awk '{print $NF}')

[ -z "$LISTENER_CONFIG" ] && err_exit "Can not find listener config file"

LOCAL_HOSTNAME=$(hostname -f)

echo "Configuring instances $PRIMARY_SID on node $REMOTE_HOST and ${PRIMARY_SID}_STB on node $LOCAL_HOSTNAME"

grep -iw ^${PRIMARY_SID}_STB $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "Instance ${PRIMARY_SID}_STB already configured"
else
cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
${PRIMARY_SID}_stb =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))
    (CONNECT_DATA =
      (SERVICE_NAME = $PRIMARY_SID)
      (UR = A)
    )
  )

EOF
fi

grep -iw ^${PRIMARY_SID} $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "Instance $PRIMARY_SID already configured"
else
cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
${PRIMARY_SID} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $REMOTE_HOST)(PORT = 1521))
    (CONNECT_DATA =
      (SERVICE_NAME = $PRIMARY_SID)
      (UR = A)
    )
  )

EOF
fi

grep -iw ^SID_LIST_LISTENER $LISTENER_CONFIG 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "SID_LIST_LISTENER already configured"
else
cat <<EOF >> $LISTENER_CONFIG

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $PRIMARY_SID)
      (ORACLE_HOME = $ORACLE_HOME)
      (SID_NAME = $PRIMARY_SID)
    )
  )

EOF
fi

lsnrctl reload

}

function standby_rman {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

which rman 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "rman not found"

LOCAL_HOSTNAME=$(hostname -f)

echo "Starting standby database not mounted ..."
sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   startup nomount
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to start standby database"
else
   echo "Done."
fi

rman <<EOF
connect target sys/${ORACLE_PWD}@${PRIMARY_SID}
connect auxiliary sys/${ORACLE_PWD}@${PRIMARY_SID}_stb
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET db_unique_name='${PRIMARY_SID}_stb' COMMENT 'Is standby'
  NOFILENAMECHECK;
EOF
if [ $? -ne 0 ]; then
   err_exit "RMAN clone to standby database failed"
else
   echo "Done."
fi

echo "Enabling recovery ..."
sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database recover managed standby database disconnect;
   alter system set fal_server=${PRIMARY_SID};
   alter system set log_archive_dest_2='service=${PRIMARY_SID} noaffirm async valid_for=(online_logfiles,primary_role) db_unique_name=${PRIMARY_SID}';
   alter system set local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=$LOCAL_HOSTNAME)(PORT=1521))' ;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to enable recovery"
else
   echo "Done."
fi

}

function db_stop_apply {
sqlCommand="alter database recover managed standby database cancel ;"
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

if [ "$REMOTE_SIDE" -ne 1 ]; then
   err_exit "Redo apply stop should be run from the standby side."
fi

echo -n "Stopping redo apply on instance $ORACLE_SID ..."
result=$(run_query "$sqlCommand")
echo "Done."
}

function db_prep_primary_logical {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

if [ "$REMOTE_SIDE" -eq 1 ]; then
   err_exit "Prep should be performed on the primary side."
fi

sqlCommand="exec dbms_logstdby.build"
echo -n "Building Log Miner directory on instance $ORACLE_SID ..."
result=$(run_query "$sqlCommand")
echo "Done."
}

function db_open_logical_standby {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

if [ "$REMOTE_SIDE" -ne 1 ]; then
   err_exit "Database open should be performed on the standby side."
fi

echo "Converting instance ${ORACLE_SID}_stb to logical standby ..."

echo "Recover to logical standby ..."
sqlCommand="alter database recover to logical standby ${ORACLE_SID} ;"
run_query "$sqlCommand"

echo "Shutdown instance ..."
sqlCommand="shutdown abort"
run_query "$sqlCommand"

echo "Startup instance mounted ..."
sqlCommand="startup mount"
run_query "$sqlCommand"

echo "Open database ..."
sqlCommand="alter database open resetlogs;"
run_query "$sqlCommand"

echo "Start logical apply service ..."
sqlCommand="alter database start logical standby apply immediate;"
run_query "$sqlCommand"

echo "Done."
}

function db_status_check {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

sqlCommand="select db_unique_name || ' | ' || open_mode || ' | ' || database_role from v\$database ;"
echo -n "Checking database status ..."
result=$(run_query "$sqlCommand")
echo "Done."
echo "$result"
}

function dg_stop {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

if [ "$REMOTE_SIDE" -eq 1 ]; then
echo "Disabling DataGuard on standby ..."
sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database recover managed standby database cancel;
   alter system set log_archive_dest_state_2='DEFER';
   alter database activate standby database;
   alter database open ;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to disable DataGuard"
else
   echo "Done."
fi
else
echo "Disabling DataGuard on primary ..."
sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system archive log current;
   alter system set log_archive_dest_state_2='DEFER';
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to disable DataGuard"
else
   echo "Done."
fi
fi
}

function drop_standby {
[ -z "$PRIMARY_SID" ] && err_exit "Primary SID not set"
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set."
export ORACLE_SID=$PRIMARY_SID

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

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

sqlplus / as sysdba <<EOF
SHUTDOWN ABORT
EOF

echo "Done."
echo "Deleting database... "

rman <<EOF
connect target /
STARTUP FORCE MOUNT
SQL 'ALTER SYSTEM ENABLE RESTRICTED SESSION';
DROP DATABASE INCLUDING BACKUPS NOPROMPT;
EOF

echo "Done."
echo "Shutting instance down... "

sqlplus / as sysdba <<EOF
SHUTDOWN ABORT
EOF

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

while getopts "p:h:rkdcsmlqx" opt
do
  case $opt in
    p)
      PRIMARY_SID=$OPTARG
      ;;
    h)
      REMOTE_HOST=$OPTARG
      ;;
    r)
      REMOTE_SIDE=1
      ;;
    k)
      DG_STOP=1
      ;;
    d)
      DROP_DB=1
      ;;
    q)
      check_logical_standby_support
      exit 0
      ;;
    c)
      db_status_check
      exit 0
      ;;
    s)
      STOP_APPLY=1
      ;;
    m)
      PREP_LOGICAL=1
      ;;
    l)
      OPEN_LOGICAL=1
      ;;
    x)
      PUSH_FILES_TO_REMOTE=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

[ -z "$PRIMARY_SID" ] && err_exit "Primary SID is required"

if [ "$STOP_APPLY" -eq 1 ]; then
   db_stop_apply
   exit 0
fi

if [ "$PREP_LOGICAL" -eq 1 ]; then
   db_prep_primary_logical
   exit 0
fi

if [ "$OPEN_LOGICAL" -eq 1 ]; then
   db_open_logical_standby
   db_status_check
   exit 0
fi

if [ "$DG_STOP" -eq 1 ]; then
   dg_stop
   exit 0
fi

if [ "$DROP_DB" -eq 1 ]; then
   drop_standby
   exit 0
fi

if [ "$PUSH_FILES_TO_REMOTE" -eq 1 ]; then
   get_db_path
   copy_to_remote
   exit 0
fi

if [ "$REMOTE_SIDE" -eq 0 ]; then
   get_db_path
   create_pfile
   copy_to_remote
   listener_primary_config
   set_primary_db_parameters
   create_standby_logs
else
   get_password
   listener_standby_config
   standby_rman
fi
