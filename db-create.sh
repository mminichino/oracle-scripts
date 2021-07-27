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
PWDFILE_ONLY=0
ASM_MODE=0
FRA_LOG_MODE=0

function print_usage {
   echo "Usage: $0 -s SID -p pdb_name -c -a -d data_dir -r reco_dir -l -g -w -m -f"
   echo "          -s Oracle SID (oradb by default)"
   echo "          -p PDB name (pdb_oradb by default)"
   echo "          -c Create a CDB with PDB (defaults to Non-CDB)"
   echo "          -a Ask for sys/system password (defaults to randomly gemnerated)"
   echo "          -d Data directory root (required, must exist)"
   echo "          -r Recovery directory (defaults to data_dir/fra)"
   echo "          -l Setup listener and exit (use -s to set SID)"
   echo "          -g Enable archivelog and exit (use -s to set SID)"
   echo "          -w Create Oracle password file and exit (use -s to set SID)"
   echo "          -m Enable ASM mode (provide disk group with -d option)"
   echo "          -f Use FRA for archive logs"
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

function create_password_file {
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set."
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."
which orapwd >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "orapwd not found."
if [ -f $ORACLE_HOME/dbs/orapw${ORACLE_SID} ]; then
   info_msg "Password file already exists."
   return
fi

get_password

orapwd file=$ORACLE_HOME/dbs/orapw${ORACLE_SID} password=${ORACLE_PWD} entries=30
}

function listener_register {
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."

if [ -z "$(ps -ef |grep ora_pmon_$ORACLE_SID | grep -v grep | awk '{print $NF}')" ]; then
   info_msg "Register listener: Instance $ORACLE_SID not running"
   return
fi

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo -n "Dynamically registering SID $ORACLE_SID ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set local_listener = '' ;
   alter system register ;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to register instance"
else
   echo "Done."
fi
}

function listener_config {

LSNR_RUNNING=0
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

which lsnrctl >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "lsnrctl not found"

lsnrctl status >/dev/null 2>&1
if [ $? -eq 0 ]; then
   info_msg "Listener running"
   LSNR_RUNNING=1
fi

LOCAL_HOSTNAME=$(hostname -f)
[ -z "$LOCAL_HOSTNAME" ] && err_exit "Can not get local host name."

if [ -n "$1" ]; then

echo "Configuring instance $1 on node $LOCAL_HOSTNAME"

grep -i $1 $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
[ $? -eq 0 ] && info_msg "Instance $1 already configured" && return

cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
${1^^} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $1)
    )
  )

LISTENER_${1^^} =
  (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))

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
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))
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

if [ "$FRA_LOG_MODE" -eq 0 ]; then
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
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."
LOCAL_HOSTNAME=$(hostname -f)

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo -n "Set local_listener ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=$LOCAL_HOSTNAME)(PORT=1521))';
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

function fs_prep {
[ -z "$DATADIR" ] && err_exit "Data directory is required"

[ ! -d "$DATADIR" -o ! -w "$DATADIR" ] && err_exit "Data directory is not accessible"

LOGDIR=$DATADIR/log

if [ ! -d $LOGDIR ]; then
   mkdir $LOGDIR || err_exit "Can not create log directory"
else
   warn_msg "Log directory $LOGDIR exists"
fi

[ -n "$RECODIR" ] && [ ! -d "$RECODIR" ] && [ ! -w "$RECODIR" ] && err_exit "Recovery directory is not accessible"

if [ -z "$RECODIR" -a ! -d $DATADIR/fra ]; then
   mkdir $DATADIR/fra || err_exit "Can not create recovery directory"
   RECODIR=$DATADIR/fra
elif [ -z "$RECODIR" -a -d $DATADIR/fra ]; then
   RECODIR=$DATADIR/fra
   warn_msg "Recovery directory $DATADIR/fra exists"
fi

if [ ! -d $DATADIR/dbf ]; then
   mkdir $DATADIR/dbf || err_exit "Can not create data file directory"
else
   warn_msg "Data file directory $DATADIR/dbf exists"
fi

DATAFILEDIR=$DATADIR/dbf
}

function asm_prep {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID is not set"
HOST_GRID_HOME=$(dirname $(dirname $(ps -ef |grep evmd.bin | grep -v grep | awk '{print $NF}')))
[ -z "$HOST_GRID_HOME" ] && err_exit "Oracle CRS does not seem to be running"
HOST_ASM_INSTANCE=$(ps -ef | grep pmon_+ASM | grep -v grep | awk '{print $NF}' | sed -e 's/^.*_pmon_//')
[ -z "$HOST_ASM_INSTANCE" ] && err_exit "ASM does not appear to be running"

ORACLE_HOME_SAVE=$ORACLE_HOME
PATH_SAVE=$PATH
ORACLE_SID_SAVE=$ORACLE_SID

export ORACLE_HOME=$HOST_GRID_HOME
export PATH=$ORACLE_HOME/bin:$PATH
export ORACLE_SID=$HOST_ASM_INSTANCE

asmcmd ls $DATADIR >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Disk group $DATADIR does not exist."

if [ -n "$RECODIR" ]; then
   asmcmd ls $RECODIR >/dev/null 2>&1
   [ $? -ne 0 ] && err_exit "Disk group $DATADIR does not exist."
   LOGDIR=$RECODIR
else
   RECODIR=$DATADIR
   LOGDIR=$DATADIR
fi

DATAFILEDIR=$DATADIR

export ORACLE_HOME=$ORACLE_HOME_SAVE
export PATH=$PATH_SAVE
export ORACLE_SID=$ORACLE_SID_SAVE
}

while getopts "s:p:cad:r:lgwmf" opt
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
    w)
      PWDFILE_ONLY=1
      ;;
    m)
      ASM_MODE=1
      DBCARSPFILE="dbca-si-asm.rsp"
      ;;
    f)
      FRA_LOG_MODE=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

if [ "$CREATE_PDB" -eq 1 ]; then
   if [ "$ASM_MODE" -eq 1 ]; then
      DBCARSPFILE="dbca-si-cdb-asm.rsp"
   else
      DBCARSPFILE="dbca-si-cdb.rsp"
   fi
fi

export ORACLE_SID=${SID_ARG:-oradb}
export ORACLE_PDB=${PDB_ARG:-pdb_oradb}
[ -n "$SID_ARG" -a -z "$PDB_ARG" ] && PDB_ARG=pdb_${SID_ARG}

get_version

if [ "$LISTENER_ONLY" -eq 1 ]; then
   listener_config
   [ -n "$SID_ARG" ] && listener_config $SID_ARG
   [ -n "$SID_ARG" ] && listener_register
   exit 0
fi

if [ "$PWDFILE_ONLY" -eq 1 ]; then
   create_password_file
   exit 0
fi

if [ "$ASM_MODE" -eq 0 ]; then
   fs_prep
else
   asm_prep
fi

if [ "$ENABLELOG_ONLY" -eq 1 ]; then
   [ -n "$SID_ARG" ] && export ORACLE_SID=${SID_ARG}
   enable_archlog
   exit 0
fi

if [ "$SET_PASSWORD" -eq 0 ]; then
   export ORACLE_PWD="$(openssl rand -base64 8 | sed -e 's/[+/=]/#/g')0"
   echo "ORACLE PASSWORD FOR SYS AND SYSTEM: $ORACLE_PWD";
else
   get_password
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

if [ -f /tmp/dbca.rsp  ]; then
   info_msg "/tmp/dbca.rsp exists"
   echo -n "Remove? (y/n): "
   read ANSWER

   if [ "$ANSWER" == "y" ]; then
      rm /tmp/dbca.rsp
   else
      echo "Aborting ..."
      exit 1
   fi
fi

[ ! -f $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE ] && err_exit "Can not open response file template $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE"

cp $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE /tmp/dbca.rsp

if [ "$CREATE_PDB" -eq 0 ]; then
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATAFILEDIR|g" /tmp/dbca.rsp
   sed -i -e "s|###RECODIR###|$RECODIR|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" /tmp/dbca.rsp
else
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATAFILEDIR|g" /tmp/dbca.rsp
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
