#include <stdio.h>
#include <time.h>
#include "main_dbd.h"
#include "worker_dbd.h"
#include "insert_dbd.h"


extern qry_info_t       sQryInfo;
extern char             gcOnlyOneCycle;
extern int              giArgQryIdx;
extern pid_t            giMyPid;
thd_info_t              sThdInfo={0, };

extern int daDBOpen(qry_t *spQry);
extern int daDBPrepare(qry_t *spQry);
extern int daDBSelect(qry_t *spQry);


static int
daUpdWoker(qry_t *spQry)
{
    char    caCycle[8];
    char    caHms[16];
    char    caRsltCnt[8];
    char    caElapTime[8];
    char    caErrCd[8];
    char    caIdx[8];
    char    caPid[8];
    char    caRslt[2];

    TRY { 
        snprintf(caCycle, sizeof(caCycle), "%d", spQry->iCycle);

        snprintf(caRsltCnt   , sizeof(caRsltCnt) , "%d", spQry->iSelColCnt   );
        if (spQry->iCycle) strcpy(caHms, "");
        else snprintf(caHms, sizeof(caHms), "%02d:%02d:%02d", spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS);

        memset(caRslt, 0x00, sizeof(caRslt));
        caRslt[0] = spQry->cRslt;

        snprintf(caElapTime  , sizeof(caElapTime), "%d", spQry->iElapSec     );
        snprintf(caIdx     , sizeof(caIdx)   , "%d", giArgQryIdx);
        snprintf(caPid     , sizeof(caPid)   , "%d", giMyPid);
        snprintf(caErrCd     , sizeof(caErrCd)   , "%d", spQry->sErr.iErrCd  );


        const char *cppParams[11] = {
                spQry->caTitle      ,   // $1: WHERE title
                caRsltCnt           ,   // $2: result_count
                caCycle             ,   // $3: cycle
                caHms               ,   // $4: hms
                caRslt              ,   // $5: result
                caElapTime          ,   // $6: elapsed_time
                caIdx               ,   // $7: run_index
                caPid               ,   // $8: pid
                spQry->sErr.caPart  ,   // $9: error_part
                caErrCd             ,   // $10: error_code
                spQry->sErr.caErrMsg    // $11: error_msg
            };

        CALL(daUpdExec(spQry, spQry->cpIRsltUpdStmtName, 11, cppParams));
    } 
    CATCH 
    FINALLY 
    END 
}

static int
daWorkerMain(qry_t *spQry)
{
    char     cErr=DEF_NO;
    struct timespec sStart, sEnd;

    TRY { 
        // start 
        CLOCK_GETTIME(&sStart);
        if (spQry->cRunMethod == RUN_METHOD_SELECT) {
            CALL(daPgExecFunc(spQry));
        }
        else {
            if (spQry->cRunMethod == RUN_METHOD_INSERT) CALL(daPgCopyBegin(spQry));

            CALL(daDBSelect(spQry));

            if (spQry->cRunMethod == RUN_METHOD_INSERT) CALL(daPgCopyEnd(spQry));
        }
        spQry->cRslt = DEF_YES;
    } 
    CATCH 
        cErr=DEF_YES;
    FINALLY 
        // end
        extern int daStopQry(qry_t *spQry);
        CLOCK_GETTIME(&sEnd);
        spQry->iElapSec = (sEnd.tv_sec*NANO_CLOCK+sEnd.tv_nsec - sStart.tv_sec*NANO_CLOCK+sStart.tv_nsec)/1000;
        daUpdWoker(spQry);
        
        if(cErr == DEF_YES) {
            daStopQry(spQry);
        }
    END 
}


/**
 * 특정 시각(시, 분, 초)을 기준으로 오늘 또는 내일의 Unix 타임스탬프(초)를 구합니다.
 * @param target_hour   Target hour (0-23)
 * @param target_minute Target minute (0-59)
 * @param target_second Target second (0-59)
 * @return 현재 시간부터 목표 시간까지 남은 초를 저장할 변수의 주소
 */
time_t 
daHmsNxtSleepSec(int iH, int iM, int iS)
{
    // 1. 현재 시스템 시간 가져오기
    time_t      ttNow = time(NULL);
    struct tm   tmTgt;;
    time_t      ttSleepSec;
    
    // 현재 시간을 로컬 시간 구조체로 변환하여 기본값 채우기 (년, 월, 일 등 확보)
    localtime_r(&ttNow, &tmTgt);
    
    // 2. 목표 시분초 설정
    tmTgt.tm_hour = iH;
    tmTgt.tm_min  = iM;
    tmTgt.tm_sec  = iS;
    tmTgt.tm_isdst = -1; // 일광 절약 시간(DST) 자동 설정
    
    // 3. 오늘 기준 목표 시간을 epoch time으로 변환
    time_t ttTgtSec = mktime(&tmTgt);
    
    // 4. 시간이 이미 지났는지 비교 (현재 시간 > 목표 시간)
    if (ttNow >= ttTgtSec) {
        // 이미 지났다면 날짜를 하루(+1) 더함
        // mktime 함수는 tm_mday가 월말을 벗어나도(예: 31일->32일) 알아서 다음 달 1일로 보정해줍니다.
        tmTgt.tm_mday += 1; 
        ttTgtSec = mktime(&tmTgt); // 재계산
    }
    
    // 5. (옵션) 지금부터 몇 초 남았는지 계산
    ttSleepSec = difftime(ttTgtSec, ttNow);

    return ttSleepSec;
}

static char *
daGetCycleString(qry_t *spQry)
{
    static char caBuf[128];
    if (spQry->iCycle) {
        sprintf(caBuf, "%d", spQry->iCycle);
    }
    else {
        sprintf(caBuf, "%02d%02d%02d", spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS);
    }
    return(caBuf);
}

static void 
*daThdMon(void *arg)
{
    int     iThdIdx = *(int *)arg;
    struct  timespec    tsLstTs;
    (void)iThdIdx;

    CLOCK_GETTIME(&tsLstTs); 
    while (1) {
        // to sleep, for next cycle
        dcNextCycleSleep(&tsLstTs, 60, 0);

        LOGI("---------------------- status --------------------------------\n");
        for(int i=0; i<sQryInfo.iLstIdx; i++) {
            qry_t *spQry = &sQryInfo.saQry[i];
            LOGI("(%02d) [%s] %-30s %-4s 주기:%3d \n", i, daPrintRunMethod(spQry->cRunMethod)
                , spQry->caTitle, spQry->cRunYn == DEF_YES?"run":"stop", spQry->iCycle);
        }
        LOGI("--------------------------------------------------------------\n");
        if(iThdIdx == 100)  return(NULL);
    }
}

static void 
*daThdMain(void *arg)
{
    int     iThdIdx = *(int *)arg;
    int     iCycle;
    int     iAlertMicroSec;
    thd_t   *spThd = &sThdInfo.saThd[iThdIdx];
    qry_t   *spQry = &sQryInfo.saQry[iThdIdx];
    struct  timespec    tsLstTs;
    char    caThdNm[128];

    if (spQry->cRunMethod == RUN_METHOD_INSERT) {
        snprintf(caThdNm, sizeof(caThdNm), "%s_insert_%d", PRJ_NAME, iThdIdx);
    }
    else {
        snprintf(caThdNm, sizeof(caThdNm), "%s_merge_%d", PRJ_NAME, iThdIdx);
    }
    pthread_setname_np(pthread_self(), caThdNm);

    spQry->cRunYn = DEF_YES;
    
    CLOCK_GETTIME(&tsLstTs); 
    LOGD("%02d run thread :%-20s, cycle:%s\n", iThdIdx, spQry->caTitle, daGetCycleString(spQry));

    if(spQry->iCycle) iCycle = spQry->iCycle;
    else              iCycle = daHmsNxtSleepSec(spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS);

    iAlertMicroSec = spThd->iAlertMicroSec;

    daDBOpen(spQry);
    daPgOpen(spQry);

    daUpdInit(spQry);       // insert collect
    daUpdPrepare(spQry);    // update prepare 

    if (spQry->cRunMethod != RUN_METHOD_SELECT) {
        if (daDBPrepare(spQry)) return NULL;
    }

    if (spQry->cRunMethod == RUN_METHOD_MERGE) {
        if(daMrgPrepare(spQry)) return NULL;
     }

    while(1) {
        // query + insert
        if (spQry->cRunMethod != RUN_METHOD_SELECT) {
            daWorkerMain(spQry);
        }

        if(!spQry->iCycle) {
            LOGD("[%s] %02d:%02d:%02d sleep time:%d \n"
                , spQry->caTitle, spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS,  iCycle);
        }

        // to sleep, for next cycle
        dcNextCycleSleep(&tsLstTs, iCycle, iAlertMicroSec);

        if (spQry->cRunMethod == RUN_METHOD_SELECT) {
            daWorkerMain(spQry);
        }

        if(!spQry->iCycle) {
            iCycle = daHmsNxtSleepSec(spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS);
        }
    }

    return NULL;
}

void
daOnlyOneCycle()
{
    int         iF0;
    qry_t       *spQry;

    for (iF0=0; iF0<sQryInfo.iLstIdx; iF0++) {
        spQry = &sQryInfo.saQry[iF0];
        daWorkerMain(spQry);
    }
    return;
}


int
daRunWorker()
{
    int     iF0;
    int     *ipThdIdx;
    thd_t   *spThd;
    char    caThdNm[128];

    TRY { 
        if(gcOnlyOneCycle == DEF_YES) {
            daOnlyOneCycle();
            exit(0); 
        }

        sThdInfo.iUseThdCnt = sQryInfo.iLstIdx;
        for (iF0=0; iF0<sThdInfo.iUseThdCnt; iF0++) {
            spThd = &sThdInfo.saThd[iF0];

            ipThdIdx = malloc(sizeof(int)); ASSERT(ipThdIdx);
            *ipThdIdx = iF0;
            spThd->iQryIdx = iF0;
            spThd->iAlertMicroSec = ((iF0) % 10)*100000 + 50000;
            
            CALL(pthread_create(&spThd->ptThdId, NULL, daThdMain, ipThdIdx));
        }
        snprintf(caThdNm, sizeof(caThdNm), "dbd_main");
        pthread_setname_np(pthread_self(), caThdNm);

        ipThdIdx = malloc(sizeof(int)); ASSERT(ipThdIdx);
        *ipThdIdx = iF0;
        CALL(pthread_create(&spThd->ptThdId, NULL, daThdMon, ipThdIdx));
        sThdInfo.iUseThdCnt++;

        /* 모든 Thread 종료 대기 */
        for (iF0=0; iF0<sThdInfo.iUseThdCnt; iF0++) {
            spThd = &sThdInfo.saThd[iF0];
            pthread_join(spThd->ptThdId, NULL);
        }
    } 
    CATCH 
    FINALLY 
    END 
}
