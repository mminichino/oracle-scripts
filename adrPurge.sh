#!/bin/sh
NODE=$(uname -n)

[ ! -d $HOME/log ] && mkdir $HOME/log
[ ! -d $HOME/log ] && echo "Can not create $HOME/log" && exit 1

exec 2>&1
exec > $HOME/log/${NODE}_trace_purge.log

export PATH=/usr/lib64/qt-3.3/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$HOME/bin
export START_PATH=$PATH
export ORACLE_HOME=/opt/app/oracle/product/19.3.0/dbhome_1
export GRID_HOME=/opt/app/grid/product/19.3.0/grid_1
export PATH=$START_PATH:$ORACLE_HOME/bin:$GRID_HOME/bin:$ORACLE_HOME/OPatch
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

echo "INFO: adrci purge started at `date`"
adrci exec="show homes"|grep -v : | while read file_line
do
echo "INFO: adrci purging diagnostic destination " $file_line
echo "INFO: purging ALERT older than 3 days"
adrci exec="set homepath $file_line;purge -age 4320 -type ALERT"
echo "INFO: purging INCIDENT older than 3 days"
adrci exec="set homepath $file_line;purge -age 4320 -type INCIDENT"
echo "INFO: purging TRACE older than 3 days"
adrci exec="set homepath $file_line;purge -age 4320 -type TRACE"
echo "INFO: purging CDUMP older than 3 days"
adrci exec="set homepath $file_line;purge -age 4320 -type CDUMP"
echo "INFO: purging HM older than 3 days"
adrci exec="set homepath $file_line;purge -age 4320 -type HM"
echo ""
done
echo "INFO: adrci purge finished at `date`"

echo "INFO: Begin audit purge..."
cd /opt/app/oracle/admin || exit 1
find . -name \*.aud  -mtime +1 -printf '%p\n' -exec rm -rf {} \;
echo "INFO: Audit purge finished at `date`"
