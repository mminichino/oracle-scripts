#!/bin/bash
#
#
unset SID_ARG
unset PDB_ARG
unset DATADIR
unset RECODIR
CREATE_PDB=0
SET_PASSWORD=0
ORACLE_CHARACTERSET=US7ASCII
SCRIPTDIR=$(cd $(dirname $0) && pwd)
DBCARSPFILE="dbca-si.rsp"
LISTENER_ONLY=0
ENABLELOG_ONLY=0

function print_usage {
   echo "Usage: $0 -s SID -p pdb_name -c -a -d data_dir -r reco_dir -l -g"
   echo "          -s Oracle SID (oradb by default)"
   echo "          -p PDB name (pdb_oradb by default)"
   echo "          -c Create a CDB with PDB (defaults to Non-CDB"
   echo "          -a Ask for sys/system password (defaults to randomly gemnerated)"
   echo "          -d Data directory root (required, must exist)"
   echo "          -r Recovery directory (defaults to data_dir/fra)"
   echo "          -l Setup listener and exit (use -s to set SID)"
   echo "          -g Enable archivelog and exit (use -s to set SID)"
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

function listener_config {

LSNR_RUNNING=0
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

which lsnrctl 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "lsnrctl not found"

lsnrctl status 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   info_msg "Listener running"
   LSNR_RUNNING=1
fi

if [ -n "$1" ]; then

echo "Configuring instance $1 on node $(uname -n)"

grep -i $1 $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
[ $? -eq 0 ] && info_msg "Instance $1 already configured" && return

cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
$1=
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $1)
    )
  )
EOF

[ $LSNR_RUNNING -eq 1 ] && lsnrctl reload

return

fi

[ $LSNR_RUNNING -eq 1 ] && return

echo "Configuring listener on node $(uname -n)"

mkdir -p $ORACLE_HOME/network/admin
echo "NAME.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)" > $ORACLE_HOME/network/admin/sqlnet.ora

cat <<EOF > $ORACLE_HOME/network/admin/listener.ora
LISTENER =
(DESCRIPTION_LIST =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1))
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
  )
)

DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
EOF

lsnrctl start

}

function enable_archlog {

[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID is not set"
[ -z "$LOGDIR" ] && err_exit "Log directory is not set"

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo -n "Setting archive log destination to $LOGDIR ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   ALTER SYSTEM SET log_archive_dest_1='location=$LOGDIR' SCOPE=spfile;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set log destination"
else
   echo "Done."
fi

echo -n "Shutting down instance ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   shutdown immediate;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to shutdown instance $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Starting instance mounted ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   startup mount;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to start instance $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Setting archive log mode ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database archivelog;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set archive log mode for $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Opening database ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database open;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to open $ORACLE_SID ..."
else
   echo "Done."
fi

}

function add_local_listener {

echo -n "Set local_listener ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=0.0.0.0)(PORT=1521))';
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set local_listener"
else
   echo "Done."
fi

}

function get_version {

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

oracleVersionMaj=$(sqlplus -V | grep -i version | sed -e 's/^.* \([0-9]*\)\..*$/\1/')
oracleVersionMin=$(sqlplus -V | grep -i version | sed -e 's/^.* [0-9]*\.\([0-9]*\).*$/\1/')

[ -z "$oracleVersionMaj" -o -z "$oracleVersionMin" ] && err_exit "Can not determine software version"

}

while getopts "s:p:cad:r:lg" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    p)
      PDB_ARG=$OPTARG
      ;;
    c)
      CREATE_PDB=1
      DBCARSPFILE="dbca-si-cdb.rsp"
      ;;
    a)
      SET_PASSWORD=1
      ;;
    d)
      DATADIR=$OPTARG
      ;;
    r)
      RECODIR=$OPTARG
      ;;
    l)
      LISTENER_ONLY=1
      ;;
    g)
      ENABLELOG_ONLY=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

get_version

if [ "$LISTENER_ONLY" -eq 1 ]; then
   listener_config
   [ -n "$SID_ARG" ] && listener_config $SID_ARG
   exit 0
fi

[ -z "$DATADIR" ] && err_exit "Data directory is required"

[ ! -d "$DATADIR" -o ! -w "$DATADIR" ] && err_exit "Data directory is not accessible"

LOGDIR=$DATADIR/log

if [ ! -d $LOGDIR ]; then
   mkdir $LOGDIR || err_exit "Can not create log directory"
else
   warn_msg "Log directory $LOGDIR exists"
fi

if [ "$ENABLELOG_ONLY" -eq 1 ]; then
   [ -n "$SID_ARG" ] && export ORACLE_SID=${SID_ARG}
   enable_archlog
   exit 0
fi

[ -n "$SID_ARG" -a -z "$PDB_ARG" ] && PDB_ARG=pdb_${SID_ARG}

[ -n "$RECODIR" ] && [ ! -d "$RECODIR" ] && [ ! -w "$RECODIR" ] && err_exit "Recovery directory is not accessible"

if [ -z "$RECODIR" -a ! -d $DATADIR/fra ]; then
   mkdir $DATADIR/fra || err_exit "Can not create recovery directory"
else
   warn_msg "Recovery directory $DATADIR/fra exists"
fi

if [ ! -d $DATADIR/dbf ]; then
   mkdir $DATADIR/dbf || err_exit "Can not create data file directory"
else
   warn_msg "Data file directory $DATADIR/dbf exists"
fi

DATADIR=$DATADIR/dbf

export ORACLE_SID=${SID_ARG:-oradb}
export ORACLE_PDB=${PDB_ARG:-pdb_oradb}

if [ "$SET_PASSWORD" -eq 0 ]; then
   export ORACLE_PWD="$(openssl rand -base64 8 | sed -e 's/[+/=]/#/g')0"
   echo "ORACLE PASSWORD FOR SYS AND SYSTEM: $ORACLE_PWD";
else
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
fi

echo -n "Oracle password: "
if [ "$SET_PASSWORD" -eq 0 ]; then
   echo $ORACLE_PWD
else
   echo "********"
fi
echo "Oracle SID     : $ORACLE_SID"
echo "DB Version     : ${oracleVersionMaj}.${oracleVersionMin}"
echo -n "Create PDB     : "
if [ "$CREATE_PDB" -eq 0 ]; then
   echo "No"
else
   echo "Yes"
   echo "PDB Name       : $ORACLE_PDB"
fi
echo "Character Set  : $ORACLE_CHARACTERSET"
echo "Data File Dir  : $DATADIR"
echo "Recovery Dir   : $RECODIR"
echo "Log Dir        : $LOGDIR"
echo ""

[ -f /tmp/dbca.rsp  ] && err_exit "/tmp/dbca.rsp exists"
[ ! -f $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE ] && err_exit "Can not open response file template $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE"

cp $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE /tmp/dbca.rsp

if [ "$CREATE_PDB" -eq 0 ]; then
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATADIR|g" /tmp/dbca.rsp
   sed -i -e "s|###RECODIR###|$RECODIR|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" /tmp/dbca.rsp
else
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATADIR|g" /tmp/dbca.rsp
   sed -i -e "s|###RECODIR###|$RECODIR|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PDB###|$ORACLE_PDB|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" /tmp/dbca.rsp
fi

listener_config

dbca -silent -createDatabase -responseFile /tmp/dbca.rsp || err_exit "Database $ORACLE_SID create failed"

listener_config $ORACLE_SID

if [ "$CREATE_PDB" -eq 1 ]; then
echo -n "Set PDB $ORACLE_PDB to auto open ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   ALTER PLUGGABLE DATABASE $ORACLE_PDB SAVE STATE;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set PDB state"
else
   echo "Done."
fi
fi

enable_archlog

add_local_listener

rm /tmp/dbca.rsp
exit 0
