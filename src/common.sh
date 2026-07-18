#!/bin/bash
ARG_NUM=$#
if (( ARG_NUM > 1 )); then
    echo "Usage $0 target_name, exit 1"
    exit
fi
ARG_NM=$1

[[ $ARG_NM == "admin" ]] && return

. env_$ARG_NM.sh

HEADER_FILE_NM=$PRJHOME/mon/src/query.inc

fiprint()
{
    echo "$*" > $HEADER_FILE_NM
}

faprint()
{
    echo "$*" >> $HEADER_FILE_NM
}

hide_query()
{
    cd $DBD_CFGDIR   >> /dev/null
    fiprint "#include <stdio.h>"
    count=${#query_file[@]}
    idx=0
    for file_nm in ${query_file[@]}; do
        #echo "$file_nm"
        xxd -i $file_nm | sed 's/unsigned int/const unsigned int/g' > $file_nm.h
        mv $file_nm.h $PRJHOME/mon/src/query$idx.inc
        faprint "#include \"query$idx.inc\""

        idx=$((idx +1))
    done

    faprint ""
    faprint "int    siQryCnt=$count;"
    faprint "unsigned char *scpaQry[$((count+1))] = {"
    for file_nm in ${query_file[@]}; do
        faprint "   ${file_nm//./_},"
    done
    faprint "   NULL"
    faprint "};"

    faprint ""
    faprint "unsigned int siaQryLen[$((count+1))] = {"
    for file_nm in ${query_file[@]}; do
        faprint "   ${file_nm//./_}_len,"
    done
    faprint "   0"
    faprint "};"

    cd - >> /dev/null
}

hide_query


#eof
