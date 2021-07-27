#!/bin/sh
sqlplus -S / as sysdba<<EOF
column REALTIME_APPLY format a14
column STATE format a10
select PRIMARY_DBID, REALTIME_APPLY, STATE from v\$logstdby_state ;
EOF
