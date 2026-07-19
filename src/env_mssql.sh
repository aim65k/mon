#!/bin/bash

# dir
export DBD_LOGDIR=$PRJHOME/mon/log
export DBD_DATDIR=$PRJHOME/mon/dat
export DBD_CFGDIR=$PRJHOME/mon/cfg
export DBD_BINDIR=$PRJHOME/mon/bin
export DBD_ADMIN_FILE=mssql_process_list.cfg

# insert DB-postgreSQL(test2)
export INS_PG_HOST_IP=192.168.10.132
export INS_PG_PORT=5432
export INS_PG_USER=itstone
export INS_PG_PASS=itstone
export INS_PG_DATABASE_NAME=mondb

# mssql 
export MSSQL_USER=sa
export MSSQL_PASS="wjqthr79&("
export MSSQL_DSN=MyMssqlDsn

export query_file=("mssql_test.sql")
#eof
