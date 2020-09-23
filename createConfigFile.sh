#!/bin/sh
#
CONFIG_DIR=""

err_end () {
  echo "Error: $1"
  [ -n "$tempfile" -a -f "$tempfile" ] && {
     echo "Current configuration file contents:"
     cat $tempfile
     rm $tempfile
  }
  exit 1
}

while getopts "s:d:" opt
do
  case $opt in
    s)
      export ORACLE_SID=$OPTARG
      ;;
    d)
      CONFIG_DIR=$OPTARG
      ;;
    \?)
      err_end "Usage: $0 [ -s ORACLE_SID | -d /config/dir ]"
      ;;
  esac
done

ORAENV_ASK=NO
source oraenv

# Make sure the environment is properly set
if [ -z "$ORACLE_SID" -o -z "$ORACLE_HOME" ]
then
   echo "Oracle environment not set. Please set ORACLE_SID and ORACLE_HOME environment variables."
   exit 1
fi

status=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select status from v\\$instance ;
   exit;
EOF`

# Make sure the database is open
if [ "$status" != "OPEN" ]; then
   err_end "Database $ORACLE_SID not open. Please start the DB to continue."
fi

tempfile=$(mktemp)

# Get list of datafiles
if [ -z "$CONFIG_DIR" ]; then
datafiles=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile ;
   exit;
EOF`
else
datafiles=$(ls $CONFIG_DIR/data* 2>/dev/null)
fi
ret=$?

# Write datafile config to file
if [ $ret -eq 0 ] && [ -n "$datafiles" ]; then
   filearray=($datafiles)
   filecount=${#filearray[@]}
   firstfilename=$(echo $datafiles | awk '{print $1}')
   datadirname=$(dirname $firstfilename)
   echo -n "DATAFILES=" > $tempfile
   count=1
   for filename in $datafiles; do
       [ "$count" -eq 1 ] && firstdbf=$filename
       if [ $count -eq $filecount ]; then
          echo "${filename}"
       else
          echo -n "${filename},"
       fi
   count=$(($count + 1))
   done >> $tempfile
else
   err_end "can not get datafiles $datafiles"
fi

# Write datafile mount point
dbfmountpoint=$(cd $(dirname $firstdbf); df -h . | tail -n 1 | awk '{print $NF}')
echo "DATAFILEMOUNTPOINT=$dbfmountpoint" >> $tempfile

# Write SID to file
echo "ORACLE_SID=$ORACLE_SID" >> $tempfile

# Get DB log mode
logmode=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select log_mode from v\\$database;
   exit;
EOF`

# If DB is in log mode save config to file
if [ "$logmode" = "ARCHIVELOG" ]; then
archfiles=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select destination from v\\$archive_dest where destination is not null ;
   exit;
EOF`
ret=$?
   if [ $ret -ne 0 -o -z "$archfiles" ]; then
      err_end "can not get archive log destinations $archfiles"
   fi
   archarray=($archfiles)
   archcount=${#archarray[@]}
   echo -n "ARCHDIRS=" >> $tempfile
   count=1
   for dirname in $archfiles; do
       if [ $count -eq $archcount ]; then
          echo "${dirname}"
       else
          echo -n "${dirname},"
       fi
   count=$(($count + 1))
   done >> $tempfile
   echo "ARCHIVELOGMODE=true" >> $tempfile
else
   echo "ARCHIVELOGMODE=false" >> $tempfile
fi

# Gather data on redo 
redogroups=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select group# from v\\$logfile;
   exit;
EOF`

redocount=$(echo "$redogroups" | wc -l)
redounique=$(echo "$redogroups" | uniq -u | wc -l)
redopergroup=$(printf "%.0f" $(($redocount / $redounique)))

redosize=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select bytes/1024/1024 from v\\$log;
   exit;
EOF`

sizesum=0
for logsize in $redosize; do
    sizesum=$(( $logsize + $sizesum ))
done

avgsize=$(( $sizesum / $redounique ))

echo "REDOGROUPS=$redounique" >> $tempfile
echo "REDOPERGROUP=$redopergroup" >> $tempfile
echo "REDOSIZE=$avgsize" >> $tempfile

# Gather data on temp tablespace
tempdbfs=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select bytes from v\\$tempfile ;
   exit;
EOF`

if [ -n "$tempdbfs" ]; then
   total=0
   for amount in $tempdbfs; do
       total=$(( $amount + $total ))
   done
   echo "TEMP=true" >> $tempfile
   echo "TEMPSIZE=$total" >> $tempfile
fi

dbcharset=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select value from nls_database_parameters where parameter='NLS_CHARACTERSET';
   exit;
EOF`

echo "DBCHARSET=$dbcharset" >> $tempfile

dbversion=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select version from v\\$instance ;
   exit;
EOF`

echo "DBVERSION=$dbversion" >> $tempfile

# Create PFILE if not present
if [ ! -f $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ]; then
   echo "PFILE not found, creating ..."
sqlplus -S / as sysdba << EOF
create PFILE='$ORACLE_HOME/dbs/init${ORACLE_SID}.ora' from SPFILE;
EOF
else
   echo "PFILE found at $ORACLE_HOME/dbs/init${ORACLE_SID}.ora"
fi

if [ -n "$CONFIG_DIR" ]; then
   configDirLoc=$CONFIG_DIR
else
   configDirLoc=$dbfmountpoint
fi

# Create config directory
if [ -d "$configDirLoc/dbconfig" ]; then
   [ ! -w "$configDirLoc/dbconfig" ] && err_end "Can not write to config directory $configDirLoc/dbconfig"
   echo "DB config directory exists; overwriting..."
else
   echo "DB config directory does not exist; creating ..."
   mkdir $configDirLoc/dbconfig || err_end "Can not create config directory."
fi

# Copy files to config directory
cp $tempfile $configDirLoc/dbconfig/${ORACLE_SID}.dbconfig

cp $ORACLE_HOME/network/admin/listener.ora $configDirLoc/dbconfig/
cp $ORACLE_HOME/network/admin/sqlnet.ora $configDirLoc/dbconfig/
cp $ORACLE_HOME/network/admin/tnsnames.ora $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/dbs/orapw${ORACLE_SID} ] && cp $ORACLE_HOME/dbs/orapw${ORACLE_SID} $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ] && cp $ORACLE_HOME/dbs/init${ORACLE_SID}.ora $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora ] && cp $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora $configDirLoc/dbconfig/

echo "DB ${ORACLE_SID} configuration file: $configDirLoc/dbconfig/${ORACLE_SID}.dbconfig"

cat $configDirLoc/dbconfig/${ORACLE_SID}.dbconfig
rm $tempfile
