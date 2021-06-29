#!/bin/sh

VERSION=$(sqlplus -V | sed -n -e 's/^SQL.*Release \([0-9]*\)\..*$/\1/p')

if [ "$VERSION" -ge 12 ]
then
sqlplus -S / as sysdba<<EOF
column svrname format a15
column dirname format a40
column nfsversion format a10
select svrname, dirname, nfsversion from v\$dnfs_servers ;
EOF
else
sqlplus -S / as sysdba<<EOF
column svrname format a15
column dirname format a40
select svrname, dirname from v\$dnfs_servers ;
EOF
fi
