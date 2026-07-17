#!/bin/bash
PGNM=$0
ARG_NUM=$#

if (( ARG_NUM != 1 )); then
    echo "Usage $PGNM target_name, exit 1"
    exit
fi
ARG_NM=$1

if [[ $ARG_NM != "oracle" && $ARG_NM != "maria" 
   && $ARG_NM != "mssql" && $ARG_NM != "pg" ]]; then
    echo "Usage $PGNM target_name, exit 2"
    exit
fi
. common.sh $ARG_NM


TODAY_TIME=$(date "+%Y%m%d_%H%M%S")
HISTORY_FILE_NAME="dbd_history_dbd.txt"

OWNER_NAME=dbd_oracle.dbd_oracle
BIN_DIR=/dbdpkg/mon/bin

readYn()
{
    MSG="$*"
    RET="N"
    read -e -n 2 -p "$MSG (Y/any key) " ANS
    [[ ${ANS:0:1} =~ [Yy] ]] && RET="Y"
}

compile()
{
    TGT_NM=$1
    echo ""
    echo "$TGT_NM compile ----------------------------------------------------------"
    make -f ${TGT_NM}.make clean; 
    make -f ${TGT_NM}.make; 
}

all_compile()
{
    if [[ $ARG_NM == "all" ]]; then
        compile pg
        compile mssql
        compile maria
        compile oracle
    else
        compile $ARG_NM
    fi
}

delete_core_file()
{
    rm -f core.dbd_*
}

copy_binary()
{
    BIN_NM=dbd_$1
    [[ ! -d ${BIN_DIR}/old ]] && sudo mkdir ${BIN_DIR}/old
    [[ -f ${BIN_DIR}/${BIN_NM} ]] && sudo mv ${BIN_DIR}/${BIN_NM} ${BIN_DIR}/old/${BIN_NM}_${TODAY_TIME}
    sudo cp ${BIN_NM} /dbdpkg/mon/bin
    sudo chown ${OWNER_NAME} ${BIN_DIR}/${BIN_NM}
}

copy_env()
{
    ENV_NM=env_$1.sh
    TMP_FILE=tmp.txt
    [[ ! -d ${BIN_DIR}/old ]] && sudo mkdir ${BIN_DIR}/old
    [[ -f ${BIN_DIR}/${ENV_NM} ]] && sudo mv ${BIN_DIR}/${ENV_NM} ${BIN_DIR}/old/${ENV_NM}_${TODAY_TIME}
    grep -v query_file ${ENV_NM} > tmp.txt
    sudo mv ${TMP_FILE} /dbdpkg/mon/bin/${ENV_NM}
    sudo chown ${OWNER_NAME} ${BIN_DIR}/${ENV_NM}
}

all_copy_env()
{
    if [[ $ARG_NM == "all" ]]; then
        copy_env pg
        copy_env mssql
        copy_env maria
        copy_env oracle
    else
        copy_env $ARG_NM
    fi
}

all_copy_binary()
{
    if [[ $ARG_NM == "all" ]]; then
        copy_binary pg
        copy_binary mssql
        copy_binary maria
        copy_binary oracle
    else
        copy_binary $ARG_NM
    fi
}

make_tags()
{
    cd $PRJHOME
    ctags -R .
    cd -
}

make_tags

delete_core_file

hide_query

all_compile

[[ $? != 0 ]] && exit

readYn  "/dbdpkg/에 배포할까요 ?"

if [[ $? == 0 && $RET == "Y" ]]; then
    read -e  -p "배포내용:" contents
    readYn "배포내용: [$contents] 맞나요 ?"
    if [[ $RET == "Y" ]]; then

        echo "$TODAY_TIME: $contents" >> $HISTORY_FILE_NAME
        $PRJHOME/util/version.sh dbd $TODAY_TIME

        all_compile
        all_copy_env
        all_copy_binary
        backup.sh $TODAY_TIME "$contents" > /dev/null
        echo "[$contents] 배포를 완료하였습니다" 
     else
        echo "배포하지 않았습니다."
     fi
fi

echo ""
#eof
