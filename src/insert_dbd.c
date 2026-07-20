#include "common_dbd.h"
#include "insert_dbd.h"

char gcaPgHostIp[128]; 
char gcaPgPort[128];
char gcaPgDbNm[128];
char gcaPgUser[128];
char gcaPgPass[128];
extern char gcDebugMode;

static void 
daPgDie(qry_t *spQry, PGresult *res, const char *msg)
{
    if (res) {
        LOGE("[%s] POSTGRES [%s] status=%s err=[%s]\n", spQry->caTitle, msg, PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
        PQclear(res);
    }
    else {
        if (spQry->spPgConn) {
         LOGE("[%s] POSTGRES CONN [%s] status=%d err=[%s]\n", spQry->caTitle, msg, PQstatus(spQry->spPgConn), PQerrorMessage(spQry->spPgConn));
        }
    }    

    exit(1);
}

static void 
daPgLive(qry_t *spQry, PGresult *res, const char *msg)
{
    if (res) {
        LOGE("[%s] POSTGRES [%s] status=%s err=[%s]\n", spQry->caTitle, msg, PQresStatus(PQresultStatus(res)), PQresultErrorMessage(res));
        PQclear(res);
    }
    else {
        if (spQry->spPgConn) {
         LOGE("[%s] POSTGRES CONN [%s] status=%d err=[%s]\n", spQry->caTitle, msg, PQstatus(spQry->spPgConn), PQerrorMessage(spQry->spPgConn));
        }
    }    
    return;
}

int 
daPgOpen(qry_t *spQry)
{
        /* PostgreSQL connect */
    char    caPgConnInfo[1024];
    snprintf(caPgConnInfo, sizeof(caPgConnInfo), "host=%s port=%s dbname=%s user=%s password=%s"
        , gcaPgHostIp, gcaPgPort, gcaPgDbNm, gcaPgUser, gcaPgPass);

    spQry->spPgConn = PQconnectdb(caPgConnInfo);
    if (PQstatus(spQry->spPgConn) != CONNECTION_OK) {
        LOGE("connect fail, connect info:[%s]\n", caPgConnInfo);
        daPgDie(spQry, NULL, "PostgreSQL connect failed");
    }
    return(0);

}

int
daPgCopyBegin(qry_t *spQry)
{
    PGresult *res = NULL;

    res = PQexec(spQry->spPgConn, spQry->cpCopyCmd);

    if (res == NULL) {
        daPgDie(spQry, NULL, "PQexec COPY returned NULL");
        return -1;
    }

    if (PQresultStatus(res) != PGRES_COPY_IN) {
        LOGE("[%s] COPY FROM STDIN failed cmd:[%s]\n",
             spQry->caTitle, spQry->cpCopyCmd);
        daPgDie(spQry, res, "COPY FROM STDIN start failed");
        return -1;
    }

    PQclear(res);
    return 0;
}
int
daPgCopyPutRow(qry_t *spQry, const char *row)
{
    int ret;

    if (row == NULL)
        return -1;

    ret = PQputCopyData(spQry->spPgConn, row, (int)strlen(row));

    if (ret != 1) {
        LOGE("[%s] PQputCopyData failed row:[%s]\n",
             spQry->caTitle, row);
        return -1;
    }

    return 0;
}

int
daPgExecFunc(qry_t *spQry)
{
    TRY { 
        // 2. 스토어드 함수 호출 쿼리 실행
        // 결과가 단일 값인 경우 "SELECT aim_func()"
        if (gcDebugMode == DEF_YES) LOGD("[%s] run exe:[%s]\n", spQry->caTitle, spQry->cpSelQry);
        PGresult *res = PQexec(spQry->spPgConn, spQry->cpSelQry);
    
        // 쿼리 실행 상태 체크
        if (PQresultStatus(res) != PGRES_TUPLES_OK) {
            daPgDie(spQry, res, "함수 호출 실패, exit");
        }
    
        // 3. 함수 반환값 출력 (결과가 있는 경우)
        // 0번째 행(Row), 0번째 열(Column)의 값을 가져옴
        if (PQntuples(res) > 0) {
            char *result_val = PQgetvalue(res, 0, 0);
            LOGD("[%s] ret val:[%s]\n", spQry->caTitle, result_val);
        } else {
            LOGD("함수가 성공적으로 실행되었습니다. (반환값 없음)\n");
        }
    
        // 4. 자원 해제 및 연결 종료
        PQclear(res);
    } 
    CATCH 
    FINALLY 
    END 
}
extern int daStopQry(qry_t *spQry);
int
daPgCopyEnd(qry_t *spQry)
{
    PGresult *res = NULL;

    if (PQputCopyEnd(spQry->spPgConn, NULL) != 1) {
        daPgDie(spQry, NULL, "PQputCopyEnd failed");
        return -1;
    }

    while ((res = PQgetResult(spQry->spPgConn)) != NULL) {
        if (PQresultStatus(res) != PGRES_COMMAND_OK) {
            daPgLive(spQry, res, "COPY result failed");
            daStopQry(spQry);
            LOGE("[%s] 복귀..?? \n", spQry->caTitle);
            return -1;
        }
        PQclear(res);
    }

    
    //LOGD("copy end:%-23s 주기:%-4d 건수:%d\n", spQry->caTitle, spQry->iCycle, spQry->iSelCnt);

    return 0;
}

#if 0
int
daInsertToPostgre(qry_t *spQry)
{
    int         iRet;
    PGresult    *res = NULL;

    res = PQexec(spQry->spPgConn, spQry->cpCopyCmd);
    if (res == NULL) {
        daPgDie(spQry, NULL, "PQexec returned NULL");
    }

    if (PQresultStatus(res) != PGRES_COPY_IN) {
        LOGE("[%s] COPY FROM STDIN, copy cmd:[%s]\n", spQry->caTitle, spQry->cpCopyCmd);
        daPgDie(spQry, res, "COPY FROM STDIN start failed");
    }
    PQclear(res);
    res = NULL;
    
    iRet = PQputCopyData(spQry->spPgConn, spQry->cpSelResult, (int)strlen(spQry->cpSelResult));
    if (iRet != 1) {
        LOGE("[%s] PQputCopyData insert failed sel result:[%s]\n", spQry->caTitle, spQry->cpSelResult);
        LOGE("PQputCopyData insert failed \n");
    }

    if (PQputCopyEnd(spQry->spPgConn, NULL) != 1) {
        daPgDie(spQry, NULL, "PQputCopyEnd failed");
    }

    while ((res = PQgetResult(spQry->spPgConn)) != NULL) {
        if (PQresultStatus(res) != PGRES_COMMAND_OK) {
            LOGE("[%s], copydata[%s]\n", spQry->caTitle, spQry->cpSelResult);
            daPgDie(spQry, res, "COPY result failed");
        }
        PQclear(res);
    }
    PQclear(res);
    LOGD("insert:%-23s 주기:%-4d 건수:%d \n"
            , spQry->caTitle, spQry->iCycle, spQry->iSelCnt);
    //LOGD("not insert:%-23s 주기:%-4d 건수:%d \n", spQry->caTitle, spQry->iCycle, spQry->iSelCnt);

    FREE(spQry->cpSelResult);
    //if (spQry->spPgConn) PQfinish(spQry->spPgConn);
    return(0);

}
#endif

int
daMrgPrepare(qry_t *spQry)
{
    PGresult *res = NULL;

    TRY { 
        snprintf(spQry->caMrgStmtName, sizeof(spQry->caMrgStmtName), "mrg_%s", spQry->caTitle);

        if (gcDebugMode == DEF_YES) LOGD("PG prepare statement:[%s] \n", spQry->caMrgStmtName);
        res = PQprepare(spQry->spPgConn, spQry->caMrgStmtName, spQry->cpMrgQry, spQry->iSelColCnt, NULL);
        if (res == NULL) {
            daPgDie(spQry, NULL, "PQprepare merge returned NULL");
        }
      
        if (PQresultStatus(res) != PGRES_COMMAND_OK) {
            daPgDie(spQry, res, "PQprepare merge failed");
        }
     
        PQclear(res);
    }
    CATCH 
    FINALLY 
    END 
}

int
daMrgRowToPostgre(qry_t *spQry)
{
    PGresult   *res = NULL;
    const char **paramValues;
    int        *paramLengths;
    int        *paramFormats;
    int        i;

    paramValues  = (const char **)dcMalloc(sizeof(char *) * spQry->iSelColCnt);
    paramLengths = (int *)dcMalloc(sizeof(int) * spQry->iSelColCnt);
    paramFormats = (int *)dcMalloc(sizeof(int) * spQry->iSelColCnt);

    for (i = 0; i < spQry->iSelColCnt; i++) {
        if (spQry->cppMrgRow[i][0] == 0x00) {
            paramValues[i] = NULL;          /* NULL */
            paramLengths[i] = 0;
        } else {
            paramValues[i] = spQry->cppMrgRow[i];
            paramLengths[i] = (int)strlen(spQry->cppMrgRow[i]);
        }

        paramFormats[i] = 0;                /* text format */
    }

    res = PQexecPrepared(spQry->spPgConn, spQry->caMrgStmtName
            , spQry->iSelColCnt, paramValues, paramLengths, paramFormats, 0);
    if (res == NULL) {
        FREE(paramValues);
        FREE(paramLengths);
        FREE(paramFormats);
        daPgDie(spQry, NULL, "PQexecPrepared merge returned NULL");
        return -1;
    }

    if (PQresultStatus(res) != PGRES_COMMAND_OK) {
        LOGE("[%s] merge failed col_cnt:%d, sql:[%s]\n", spQry->caTitle, spQry->iSelColCnt, spQry->cpMrgQry);
        daPgDie(spQry, res, "PQexecPrepared merge failed");

        FREE(paramValues);
        FREE(paramLengths);
        FREE(paramFormats);
        return -1;
    }

    PQclear(res);

    FREE(paramValues);
    FREE(paramLengths);
    FREE(paramFormats);

    return 0;
}

void
daPrintInsReslt(qry_t *spQry)
{
    if (spQry->iCycle) {
        LOGD("[%-6s] %-16s 주기:%-3d, 건수:%d\n", daPrintRunMethod(spQry->cRunMethod)
            , spQry->caTitle, spQry->iCycle, spQry->iSelCnt);
    }
    else {
        LOGD("[%-6s] %-16s 주기:[%02d:%02d:%02d], 건수:%d\n", daPrintRunMethod(spQry->cRunMethod)
            , spQry->caTitle, spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS, spQry->iSelCnt);
    }
    return;
}
