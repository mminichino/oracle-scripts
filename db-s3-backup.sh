#!/bin/sh
#
SCRIPTLOC=$(cd $(dirname $0) && pwd)
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
LOGFILE=$SCRIPTLOC/log/sql.trc
HOSTNAME=$(uname -n)
BACKUP_BUCKET="orabkup"
AUTH_KEY=""
ENDPOINT=""
REGION="us-east-1"

function log_output {
    DATE=$(date '+%m-%d-%y_%H:%M:%S')
    while read line; do
        [ -z "$line" ] && continue
        echo "$DATE $HOSTNAME: $line" >> $LOGFILE
    done
}

function err_exit {
   DATE=$(date '+%m%d%y-%H%M%S')" "$(uname -n)
   LEVEL="ERROR"
   if [ -n "$2" ]; then
      if [ "$2" -eq 0 ]; then
         LEVEL="INFO"
      fi
   fi
   if [ -n "$1" ]; then
      echo "${LEVEL}: $1" 2>&1 | log_output
      echo "$1"
   else
      echo "Usage: $0 -s ORACLE_SID -b | -e | -c | -q"
   fi
   if [ -n "$2" ]; then
      exit $2
   else
      exit 1
   fi
}

if [ -z "$(which stat)" ]; then
   err_exit "This script requires the stat utility."
fi

while getopts "s:d:b:p:e:r:" opt
do
  case $opt in
    s)
      export ORACLE_SID=$OPTARG
      ;;
    d)
      BACKUP_DIR=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    b)
      BACKUP_BUCKET=$OPTARG
      ;;
    p)
      AUTH_KEY=$OPTARG
      ;;
    e)
      ENDPOINT=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    r)
      REGION=$OPTARG
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$(cut -d: -f 1 /etc/oratab | grep $ORACLE_SID)" ]; then
   # Try to get grid home
   GRID_HOME=$(dirname $(dirname $(ps -ef | grep evmd.bin | grep -v grep | awk '{print $NF}')))
   if [ -n "$GRID_HOME" ]; then
      export START_PATH=$PATH
      export PATH=$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH=$GRID_HOME/lib
      ORACLE_HOME=$(srvctl config database -db $ORACLE_SID | grep -i -e "^oracle home" -e "^PRCD-1229" | awk '{print $NF}' | sed -e 's/\.$//')
      [ -z "$ORACLE_HOME" ] && err_exit "$ORACLE_SID not properly configured."
      LOCAL_ORACLE_SID=$(basename $(ls $ORACLE_HOME/dbs/hc_${ORACLE_SID}*.dat) | sed -e 's/hc_//' -e 's/\.dat//')
      if [ -z "$LOCAL_ORACLE_SID" ]; then
         err_exit "Can not configure local instance SID from Grid Home $GRID_HOME"
      fi
      echo "CRS found, configured instance $LOCAL_ORACLE_SID from Grid." | log_output
      export PATH=$ORACLE_HOME/bin:$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH==$ORACLE_HOME/lib
      GLOBAL_SID=$ORACLE_SID
      export ORACLE_SID=$LOCAL_ORACLE_SID
   else
      err_exit "DB Instance $ORACLE_SID not found in /etc/oratab."
   fi
else
   ORAENV_ASK=NO
   source oraenv
fi

if [ -n "$GLOBAL_SID" ]; then
   DBNAME=$GLOBAL_SID
else
   DBNAME=$ORACLE_SID
fi

if [ "$(stat -t -c '%u' /etc/oratab)" != "$(id -u)" ]; then
   err_exit "This script shoud be run as the oracle user."
fi

if [ "$OPSET" -ne 2 ]; then
   err_exit
fi

if [ ! -d "$BACKUP_DIR" ];then
   err_exit "Backup directory $BACKUP_DIR does not exist."
fi

if [ -z "$ORACLE_SID" -a -z "$(which sqlplus 2>/dev/null)" ]; then
   err_exit "Environment not properly set."
fi

if [ -z "$(which aws 2>/dev/null)" ]; then
   err_exit "AWS CLI is required."
fi

if [ -n "$AUTH_KEY" ]; then
   awsParams="--profile $AUTH_KEY"
fi

aws --endpoint-url $ENDPOINT --region $REGION --no-verify-ssl $awsParams s3 ls > /dev/null 2>&1

if [ $? -ne 0 ]; then
   err_exit "Failed to access $ENDPOINT - can not list buckets."
fi

aws --endpoint-url $ENDPOINT --region $REGION --no-verify-ssl $awsParams s3api head-bucket --bucket $BACKUP_BUCKET > /dev/null 2>&1

if [ $? -ne 0 ]; then
   err_exit "Failed to access bucket $BACKUP_BUCKET - missing or inaccessible."
fi

$SCRIPTLOC/db-incr-merge.sh -s $DBNAME -d $BACKUP_DIR -q -n

echo "Copying backup to S3 endpoint $ENDPOINT bucket $BACKUP_BUCKET" | log_output

aws --endpoint-url $ENDPOINT --region $REGION --no-verify-ssl $awsParams s3 rm s3://$BACKUP_BUCKET/archivelog/ --recursive 2>&1 | grep -v InsecureRequestWarning | log_output

if [ $? -ne 0 ]; then
   err_exit "Failed to copy backup files to S3 endpoint $ENDPOINT"
fi

cd $BACKUP_DIR 2>/dev/null || err_exit "Can not change to backup directory $BACKUP_DIR"
aws --endpoint-url $ENDPOINT --region $REGION --no-verify-ssl $awsParams s3 cp . s3://$BACKUP_BUCKET --recursive --no-progress 2>&1 | grep -v InsecureRequestWarning | log_output

if [ $? -ne 0 ]; then
   err_exit "Failed to copy backup files to S3 endpoint $ENDPOINT"
fi

echo "Backup and transfer complete." | log_output
