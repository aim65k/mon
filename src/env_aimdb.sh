#!/bin/bash

# dir
export DBD_LOGDIR=$PRJHOME/mon/log
export DBD_DATDIR=$PRJHOME/mon/dat
export DBD_CFGDIR=$PRJHOME/mon/cfg
export DBD_BINDIR=$PRJHOME/mon/bin
export DBD_ADMIN_FILE=aimdb_process_list.cfg

# insert DB-postgreSQL
export INS_PG_HOST_IP=192.168.48.50
export INS_PG_PORT=5432
export INS_PG_USER=postgres
export INS_PG_PASS=1234
export INS_PG_DATABASE_NAME=aimdb

# oracle
export ORACLE_USER=itstone
export ORACLE_PASS=itstone
export ORACLE_SERVICE_NAME=orclpdb1

# mssql 
export MSSQL_USER=sa
export MSSQL_PASS="wjqthr79&("
export MSSQL_DSN=MyMssqlDsn

# mariaDB(test2)
export MARIA_HOST_IP=192.168.10.132
export MARIA_PORT=3306
export MARIA_USER=itstone
export MARIA_PASS=itstone
export MARIA_DATABASE_NAME=employees

# postgreSQL
export PG_HOST_IP=192.168.10.132
export PG_PORT=5432
export PG_USER=itstone
export PG_PASS=itstone
export PG_DATABASE_NAME=mondb

#eof
