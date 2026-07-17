#include "main_dbd.h"
#include "worker_dbd.h"
#include "version_dbd.inc"
#include "common_dbd.h"
#include "string_db.h"
#include "daemon_db.h"
#include "func_db.h"
#include "query.inc"

qry_info_t      sQryInfo={0, };

static char scStdoutYn = DEF_NO;
static char scaQryFileNm[128];
static char scaArgQryFileNm[128];
static int  siArgQryIdx=-1;
       char gcDebugMode = DEF_NO;  
       char gcOnlyOneCycle = DEF_NO;
       char scRestartYn=DEF_NO;
       char scaPgNm[128];
       char scaTgtTitle[128];
       char gcOnlyOneTitle = DEF_NO;

extern char gcaPgHostIp[128]; 
extern char gcaPgPort[128];
extern char gcaPgDbNm[128];
extern char gcaPgUser[128];
extern char gcaPgPass[128];

static void
daGetDupChkFileNm(char *cpFileNm, int iFileNmLen)
{
    const char  *cpDir = ENV_REQUIRED(DBD_DATDIR);
    char        *cpNmP;

    if(strlen(scaArgQryFileNm) > 0) {
        cpNmP = strrchr(scaQryFileNm, '/');
        if(cpNmP)   cpNmP ++;
        else        cpNmP = scaQryFileNm;

        if (gcOnlyOneTitle == DEF_YES) {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%s_%s.dat", cpDir, scaPgNm, cpNmP, scaTgtTitle);
        }
        else {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%s.dat", cpDir, scaPgNm, cpNmP);
        }
    }
    else {  // for index of file
        if (gcOnlyOneTitle == DEF_YES) {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%02d_%s.dat", cpDir, scaPgNm, siArgQryIdx, scaTgtTitle);
        }
        else {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%02d.dat", cpDir, scaPgNm, siArgQryIdx);
        }
    }
    return;
}

static void
daGetLogFileNm(char *cpFileNm, int iFileNmLen)
{
    const char      *cpDir = ENV_OPTIONAL(DBD_LOGDIR, "./");
    char            caDt[30];
    struct timeval  tv;
    struct tm       tm_time; 

    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm_time);
    strftime(caDt, sizeof(caDt), "%Y%m%d", &tm_time);

    if(strlen(scaArgQryFileNm) > 0) {
        if (gcOnlyOneTitle == DEF_YES) {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%s_%s.log", cpDir, scaQryFileNm, scaTgtTitle, caDt);
        }
        else {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%s.log", cpDir, scaQryFileNm, caDt);
        }
    }
    else {  // for index of file
        if (gcOnlyOneTitle == DEF_YES) {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%02d_%s_%s.log", cpDir, scaPgNm, siArgQryIdx, scaTgtTitle, caDt);
        }
        else {
            snprintf(cpFileNm, iFileNmLen, "%s/%s_%02d_%s.log", cpDir, scaPgNm, siArgQryIdx, caDt);
        }
    }
    return;
}

static void
daGetQueryFileNm(char *cpFileNm, int iFileNmLen)
{
    char    *cpRet;

    cpRet = strchr(scaArgQryFileNm, '/');
    if (cpRet) {
        snprintf(cpFileNm, iFileNmLen, "%s", scaArgQryFileNm);
    }
    else {
        const char *cpDir = ENV_OPTIONAL(DBD_CFGDIR, NULL);
        if(!cpDir)   snprintf(cpFileNm, iFileNmLen, "%s/%s", "./"   , scaQryFileNm);
        else         snprintf(cpFileNm, iFileNmLen, "%s/%s", cpDir  , scaQryFileNm);
    }

    return;
}

static int
daChkCycle(qry_t *spQry, char *cpBuf, char *cpLine, int iLineNo)
{
    int     iCnt;
    char    caBuf[32];
    char    *cpStop;
    
    TRY { 
        iCnt = dcCountChar(cpBuf, strlen(cpBuf), ':');
        if(iCnt == 2) { // 특정시간
            LOGD("시간 \n");
            dcNthString(cpBuf, ':', 1, caBuf, sizeof(caBuf));
            if(dcIsNumber(caBuf, strlen(caBuf)) == DEF_FALSE) {
                LOGE("[ERROR] %d line, 시간에서 시는[%s]는 숫자만 가능합니다...[%s]\n", iLineNo, caBuf, cpLine);
                THROW(1);
            }
            spQry->sHms.iH = strtol(caBuf, &cpStop, 10);
            

            dcNthString(cpBuf, ':', 2, caBuf, sizeof(caBuf));
            if(dcIsNumber(caBuf, strlen(caBuf)) == DEF_FALSE) {
                LOGE("[ERROR] %d line, 시간에서 시는[%s]는 숫자만 가능합니다...[%s]\n", iLineNo, caBuf, cpLine);
                THROW(1);
            }
            spQry->sHms.iM = strtol(caBuf, &cpStop, 10);

            dcNthString(cpBuf, ':', 3, caBuf, sizeof(caBuf));
            if(dcIsNumber(caBuf, strlen(caBuf)) == DEF_FALSE) {
                LOGE("[ERROR] %d line, 시간에서 시는[%s]는 숫자만 가능합니다...[%s]\n", iLineNo, caBuf, cpLine);
                THROW(1);
            }
            spQry->sHms.iS = strtol(caBuf, &cpStop, 10);

            LOGD("[%02d:%02d:%02d]\n", spQry->sHms.iH, spQry->sHms.iM, spQry->sHms.iS);
            spQry->iCycle = 0;
        }
        else {
            if(dcIsNumber(cpBuf, strlen(cpBuf)) == DEF_FALSE) {
                LOGE("[ERROR] %d line, 반복 주기[%s]는 숫자만 가능합니다...[%s]\n", iLineNo, cpBuf, cpLine);
                THROW(2);
            }
            spQry->iCycle = strtol(cpBuf, &cpStop, 10);
            spQry->sHms.iH = spQry->sHms.iM = spQry->sHms.iS = 0;
        }
    } 
    CATCH 
    FINALLY 
    END 
}

int
daReadQueryFile()
{
    char    caLine[1024], *cpLine;
    char    caTitle[128];
    char    caBuf[128], caTmp[128];
    char    *cpSemiRet, *cpCmtRet;
    FILE    *fpFile;
    char    caFileNm[256];
    char    cCh, cUseYn;
    qry_t   *spQry;
    int     iLineNo=0, iCpLen;
    char    caQuery[DBD_QUERY_MAX_LEN];
    
    TRY {

        if(siArgQryIdx < 0) {
            if(strlen(scaQryFileNm) <=  0) {
                EXIT("cfg file name not found \n");
            }
            daGetQueryFileNm(caFileNm, sizeof(caFileNm));
            fpFile = fopen(caFileNm, "r");
            if(fpFile == NULL) {
                LOGE("[%s] file을 open하지 못했습니다.[%d,%s] \n", caFileNm, errno, strerror(errno));
                THROW(1);
            }
        }
        else {
            fpFile = fmemopen((void *)scpaQry[siArgQryIdx-1], siaQryLen[siArgQryIdx-1], "r");
            if(fpFile == NULL) {
                LOGE("fmemopen() fail, idx:%d, [%d,%s] \n", siArgQryIdx, errno, strerror(errno));
                THROW(1);
            }
        }


        sQryInfo.iLstIdx=0;
        spQry = &sQryInfo.saQry[0];

        cUseYn = DEF_YES;
        memset(caQuery, 0x00, sizeof(caQuery));
        while(1) {
            if(!fgets(caLine, sizeof(caLine), fpFile))  break;

            iLineNo++;
            if(strlen(caLine) > 1)  caLine[strlen(caLine)-1] = 0x00;

            dcAllTrimLen(caLine, strlen(caLine));
            if (caLine[0] == '#' || !strlen(caLine))   continue;

            cpLine = caLine;
            if(caLine[0] == '[') {
                // 타이틀
                dcNthString(cpLine+1, ',', 1, caTitle, sizeof(caTitle));
        
                if (gcOnlyOneTitle == DEF_YES && STRLCMP(caTitle, scaTgtTitle, strlen(caTitle))) {
                    cUseYn = DEF_NO;
                    continue;
                }

                // 사용유무
                dcNthString(cpLine+1, ',', 2, caBuf, sizeof(caBuf));
                dcAllTrimLen(caBuf, strlen(caBuf));

                cCh = caBuf[0];
                if (cCh != 'Y' && cCh != 'y') {
                    LOGD("skp: [%s]\n", caLine);
                    cUseYn = DEF_NO;
                    continue;
                }
                else {
                    cUseYn = DEF_YES;
                }

                // 현재까지의 query처리 후 초기화
                if (sQryInfo.iLstIdx) {

                    iCpLen  = strlen(caQuery);
                    spQry->cpOrgQuery = (char *)dcMalloc(iCpLen + 1);
                    memcpy(spQry->cpOrgQuery, caQuery, iCpLen);

                    memset(caQuery, 0x00, sizeof(caQuery));
                    spQry = &sQryInfo.saQry[sQryInfo.iLstIdx];
                    sQryInfo.iLstIdx ++;
                }

                snprintf(spQry->caTitle, sizeof(spQry->caTitle), "%s", caTitle);

                // 수집주기
                dcNthString(cpLine+1, ',', 3, caBuf, sizeof(caBuf));

                dcNthString(caBuf, ']', 1, caTmp, sizeof(caTmp));
                dcAllTrimLen(caTmp, strlen(caTmp));
                strcpy(caBuf, caTmp);

                //if(strlen(caBuf) > 1) caBuf[strlen(caBuf)] = 0x00;
                CALL(daChkCycle(spQry, caBuf, caLine, iLineNo));
            }
            else {
                if (cUseYn == DEF_NO) continue;
                if (!sQryInfo.iLstIdx) sQryInfo.iLstIdx ++;

                if (sQryInfo.iLstIdx >=DBD_QUERY_MAX_CNT) {
                    LOGE("현재 query는 %d개까지 실행할수 있습니다. 그래서 exit합니다 \n", DBD_QUERY_MAX_CNT);
                    exit(-1);
                }

                if (strlen(caQuery)) strcat(caQuery, " ");

                // ; 제거
                cpSemiRet = strchr(caLine, ';');
                if (cpSemiRet) *cpSemiRet = ' ';
    
                // 주석 제거
                cpCmtRet = strcasestr(caLine, "--");
                if (!cpCmtRet) {
                    strcat(caQuery, caLine);
                }
                else {
                    iCpLen = strlen(caLine) - strlen(cpCmtRet);
                    if(iCpLen > 0) strncat(caQuery, caLine, iCpLen);
                }
            }
        
            if (sQryInfo.iLstIdx >= DBD_QUERY_MAX_CNT) {
                LOGE("query 건수가 설정한 값 %s 을 초과하였습니다. 그래서 exit합니다. \n", DBD_QUERY_MAX_CNT);
                exit(-1);
            }
        }

        iCpLen  = strlen(caQuery);
        if(iCpLen > 0) {
            spQry->cpOrgQuery = (char *)dcMalloc(iCpLen + 1);
            memcpy(spQry->cpOrgQuery, caQuery, iCpLen);
        }


        // query 양을 줄이기 위해 space가 2개 이상인것을 1개로 줄인다.
        int     iIdx=0, iLen, iF0, iF1;
        char    cCh, cPreSpace;
        memset(caQuery, 0x00, sizeof(caQuery));
        for(iF0=0; iF0<sQryInfo.iLstIdx; iF0++) {
            spQry = &sQryInfo.saQry[iF0];
            
            cPreSpace=DEF_NO;
            iLen = strlen(spQry->cpOrgQuery);
            iIdx = 0;
            for(iF1=0; iF1<iLen; iF1++) {
                cCh = spQry->cpOrgQuery[iF1];
                if (cCh == ' ')  {
                    if (cPreSpace == DEF_NO) {
                        cPreSpace = DEF_YES;
                        caQuery[iIdx++] = cCh;
                    }
                    else {
                        continue;
                    }
                }
                else {
                    cPreSpace = DEF_NO;
                    caQuery[iIdx++] = cCh;
                }
            } /* for(iF1=0; iF1<iLen; iF1++) */
            caQuery[iIdx] = 0x00;

            spQry->cpQuery = (char *)dcMalloc(iIdx+1);
            memcpy(spQry->cpQuery, caQuery, iIdx);
        }
    

        #ifdef  DEBUG
        LOGD("----------------------------------------------\n");
        LOGD("query count:%d\n", sQryInfo.iLstIdx);
        for(iF0=0; iF0<sQryInfo.iLstIdx; iF0++) {
            spQry = &sQryInfo.saQry[iF0];
            LOGD("title:[%s], cycle:%d, query:[%s]\n"
                ,spQry->caTitle, spQry->iCycle, spQry->cpOrgQuery);
            LOGD("title:[%s], cycle:%d, query:[%s]\n"
                ,spQry->caTitle, spQry->iCycle, spQry->cpQuery);
        }
        LOGD("----------------------------------------------\n");
        #endif
        fclose(fpFile);

        if(strlen(spQry->caTitle) == 0) {
            strcpy(spQry->caTitle, "no_name");
            spQry->iCycle = 10;
        }
        
    }
    CATCH
    FINALLY
    END
}

static int
daGetInsQry(qry_t *spQry)
{
    char    *cpStr, *cpRet;
    int     iCpLen;

    TRY {
        cpStr = spQry->cpQuery;

        cpRet = strcasestr(cpStr, "with");
        if (cpRet) {
            iCpLen = cpRet - cpStr;
            spQry->cpInsQry = (char *)dcMalloc(iCpLen + 1);
            memcpy(spQry->cpInsQry, cpStr, iCpLen);

            iCpLen = strlen(cpRet);
            spQry->cpSelQry = (char *)dcMalloc(iCpLen + 1);
            memcpy(spQry->cpSelQry, cpRet, iCpLen);
        }
        else {
            cpRet = strcasestr(cpStr, "select ");
            if (cpRet) {
                iCpLen = cpRet - cpStr;
                spQry->cpInsQry = (char *)dcMalloc(iCpLen + 1);
                memcpy(spQry->cpInsQry, cpStr, iCpLen);
        
                iCpLen = strlen(cpRet);
                spQry->cpSelQry = (char *)dcMalloc(iCpLen + 1);
                memcpy(spQry->cpSelQry, cpRet, iCpLen);
             }
            else {
                spQry->cpInsQry = NULL;
                iCpLen = strlen(cpStr);
                spQry->cpSelQry = (char *)dcMalloc(iCpLen + 1);
                memcpy(spQry->cpSelQry, cpStr, iCpLen);
            }
        }
    }
    CATCH 
        LOGE("%s select 문을 못찾음 \n", __func__);
        LOGE("query:[%s] \n", cpStr);
    FINALLY
    END
}

static int 
daGetInsColFromInsQry(qry_t *spQry)
{
    int     iF0;
    int     iCpLen;
    int     iIdx;
    int     iRestLen;
    char    *cpStr, *cpRet;
    const char *cpCon=" into ";
    char    caCmd[DBD_COPY_CMD_MAX_LEN], *cpCmd;


    TRY { 
        // into 문 찾기
        if(!spQry->cpInsQry) { LOGE("cpInsQry is null \n"); THROW(1); }

        cpStr = spQry->cpInsQry;
        cpRet = strcasestr(cpStr, cpCon);
        if (!cpRet)  { LOGE("%s into 문을 못찾음:[%s] \n", __func__, cpStr); THROW(2); }
        
        // table이름 찾기
        cpStr = cpRet+strlen(cpCon);
        iCpLen = strlen(cpStr);

        // 처음 space가 올수있는데.....????
    
        for (iF0=0; iF0<iCpLen; iF0++) {
            if (cpStr[iF0] == '(' || cpStr[iF0] == ' ' || cpStr[iF0] == '\n')   break;
            spQry->caInsTblNm[iF0] = cpStr[iF0];
        }

        if (iF0 == iCpLen && !strlen(spQry->caInsTblNm)) { 
            LOGE("%s table 이름을 구하지 못함[%s] \n", __func__, cpStr); THROW(1);
        }
        spQry->caInsTblNm[iF0] = 0x00;
        //LOGD("table name: [%s]\n", spQry->caInsTblNm);


        // 컬럼이름 찾기
        cpRet = strchr(cpStr, '(');
        if (!cpRet) { LOGE("%s 컬럼이름을 구할때 (를 못찾음[%s] \n", __func__, cpStr); THROW(1); }

        cpStr = cpRet + 1;
        spQry->iInsColCnt = 0;

        iCpLen = strlen(cpStr);
        iIdx=0;
        for (iF0=0; iF0<iCpLen; iF0++) {
            if (cpStr[iF0] == ' ')  continue;       // skip space
            if (cpStr[iF0] == ',' || cpStr[iF0] == '\n' || cpStr[iF0] == ')') 
            { 
                spQry->iInsColCnt ++; 
                if (spQry->iInsColCnt >= DBD_COL_MAX_CNT) {
                    LOGE("limit, 컬럼의 최대개수 %d 를 초과하여 exit 합니다.\n", DBD_COL_MAX_CNT);
                    exit(-1);
                }
                iIdx=0;      
                continue; 
            }
            spQry->ca2InsColNm[spQry->iInsColCnt][iIdx++] = cpStr[iF0];
        }

        // copy command 문장 완성
        snprintf(caCmd, sizeof(caCmd), "COPY %s (", spQry->caInsTblNm);

        for (iF0=0; iF0<spQry->iInsColCnt; iF0++) {
            strcat(caCmd, spQry->ca2InsColNm[iF0]); 
            if (iF0 != spQry->iInsColCnt-1) strcat(caCmd, ", ");
        }
        cpCmd = &caCmd[strlen(caCmd)];
        iRestLen = sizeof(caCmd) - strlen(caCmd);

        snprintf(cpCmd, iRestLen, ") FROM STDIN WITH (FORMAT text, DELIMITER E'\\t')");
        iCpLen = strlen(caCmd);
        spQry->cpCopyCmd = (char *)dcMalloc(iCpLen + 1);
        memcpy(spQry->cpCopyCmd, caCmd, iCpLen);
        
        #ifdef  DEBUG
        // 출력
        for (iF0=0; iF0<spQry->iInsColCnt; iF0++) {
            LOGD("%d [%s]\n", iF0, spQry->ca2InsColNm[iF0]);
        }
        #endif
    } 
    CATCH 
    FINALLY 
    END 
}

static char
daIsInsKeyCol(qry_t *spQry, char *cpStr)
{
    int     iF0;
    for (iF0=0; iF0<spQry->iKeyColCnt; iF0++) {
        if (strlen(cpStr) == strlen(spQry->ca2KeyColNm[iF0])
            && !memcmp(cpStr, spQry->ca2KeyColNm[iF0], strlen(cpStr)))   break;
    }
    
    if (iF0 == spQry->iKeyColCnt)   return(DEF_NO);
    return(DEF_YES);
}

static int
daGetKeyColFromMrgQry(qry_t *spQry)
{
    char    caBuf[256], caCols[1024];
    char    *cpP, *cpRet1, *cpRet2;
    int     iCpLen, iColIdx;

    TRY { 
        cpP = spQry->cpQuery;
        cpRet1 = strcasestr(cpP, " on (");
        if(!cpRet1) { LOGE("not found on in the MERGE\n"); THROW(1); }

        cpP = cpRet1 + 5;

        cpRet2 = strchr(cpP, ')');
        if(!cpRet2) { LOGE("not found ) in the MERGE\n"); THROW(1); }
        memset(caBuf, 0x00, sizeof(caBuf));
        iCpLen = cpRet2 - cpP;

        iColIdx = 0;
        strncpy(caCols, cpP, iCpLen);
        cpP = caCols;
        LOGD("keys:[%s]\n", caCols);
        while(1) {
            if (!cpP)   break;
            cpRet1 = strchr(cpP, '=');
            cpRet2 = strchr(cpP, '.');
        
            MEMSET(caBuf);
            if(cpRet2) {
                strncpy(caBuf, cpRet2+1, (cpRet1-1)-(cpRet2+1));
                dcAllTrimLen(caBuf, strlen(caBuf));
                strcpy(spQry->ca2KeyColNm[iColIdx++], caBuf);
                LOGD("key: %d, [%s] \n", iColIdx-1, spQry->ca2KeyColNm[iColIdx-1]);
            }   
            else {
                strncpy(caBuf, cpP, cpRet1-cpP);
                dcAllTrimLen(caBuf, strlen(caBuf));
                strcpy(spQry->ca2KeyColNm[iColIdx++], caBuf);
                LOGD("key: %d, [%s] \n", iColIdx-1, spQry->ca2KeyColNm[iColIdx-1]);
            }
            if (iColIdx >= DBD_COL_MAX_CNT) {
                LOGE("limit, 컬럼의 최대개수 %d 를 초과하여 exit 합니다.\n", DBD_COL_MAX_CNT);
                exit(-1);
            }

            // skip AND
            cpRet2 = strstr(cpRet1, " AND ");
            cpP = cpRet2;
        }
        spQry->iKeyColCnt = iColIdx;
    } 
    CATCH 
    FINALLY 
    END 
}

static int
daGetInsColFromMrgQry(qry_t *spQry)
{
    char    caBuf[256], caCols[1024];
    char    *cpP, *cpRet1;
    int     iCpLen;

    cpP = spQry->cpQuery;
    TRY { 
        cpRet1 = strcasestr(cpP, " INSERT (");
        if(!cpRet1) { LOGE("not found INSERT in the MERGE\n"); THROW(1); }

        cpP = cpRet1 + 9;
        cpRet1 = strchr(cpRet1, ')');
        if(!cpRet1) { LOGE("not found INSERT ) in the MERGE\n"); THROW(1); }
    
        iCpLen = cpRet1 - cpP;
    
        memset(caCols, 0x00, sizeof(caCols));
        memcpy(caCols, cpP, iCpLen);
    
        dcAllTrimLen(caCols, iCpLen); 
        LOGD("cols:[%s]\n", caCols);
        cpP = caCols;

        int iColIdx=0;
        int iNoKeyColIdx=0;
        while(1) {
            memset(caBuf, 0x00, sizeof(caBuf));
            cpRet1 = strchr(cpP, ',');
            if(!cpRet1) break;
        
            iCpLen = cpRet1 - cpP;
            strncpy(caBuf, cpP, iCpLen);
            dcAllTrimLen(caBuf, strlen(caBuf));
            if (daIsInsKeyCol(spQry, caBuf) == DEF_NO) {
                strcpy(spQry->ca2NoKeyColNm[iNoKeyColIdx++], caBuf);
            }
            strcpy(spQry->ca2InsColNm[iColIdx++], caBuf);
            cpP = cpRet1+1;
        }
        strcpy(caBuf, cpP);
        dcAllTrimLen(caBuf, strlen(caBuf));
        if (daIsInsKeyCol(spQry, caBuf) == DEF_NO) {
            strcpy(spQry->ca2NoKeyColNm[iNoKeyColIdx++], caBuf);
        }
        strcpy(spQry->ca2InsColNm[iColIdx++], caBuf);
        if (iColIdx >= DBD_COL_MAX_CNT) {
            LOGE("limit, 컬럼의 최대개수 %d 를 초과하여 exit 합니다.\n", DBD_COL_MAX_CNT);
            exit(-1);
        }

        spQry->iInsColCnt = iColIdx;
        spQry->iNoKeyColCnt = iNoKeyColIdx;


        int iF0;
        for (iF0=0; iF0<spQry->iNoKeyColCnt; iF0++) {
            LOGD("%d, [%s]\n", iF0, spQry->ca2NoKeyColNm[iF0]);
        }
    } 
    CATCH 
    FINALLY 
    END 
}

static int
daGenUpsertQryFromMrgQry(qry_t *spQry)
{
    int         iF0, iCpLen;
    char        *cpP;
    char        caQuery[DBD_QUERY_MAX_LEN];

    TRY { 
        memset(caQuery, 0x00, sizeof(caQuery));
        cpP = caQuery;
        // table name
        cpP += sprintf(cpP, "INSERT INTO %s (", spQry->caInsTblNm);
    
        for (iF0=0; iF0<spQry->iInsColCnt; iF0++) {
            // column name
            cpP += sprintf(cpP, "%s", spQry->ca2InsColNm[iF0]);  
            if (iF0 != (spQry->iInsColCnt-1)) {
                strcat(cpP, ", ");  cpP += 2;
            }
        }
        cpP += sprintf(cpP, ") VALUES (");
    
        for (iF0=0; iF0<spQry->iInsColCnt; iF0++) {
            cpP += sprintf(cpP, "$%d", iF0+1);  
            if (iF0 != (spQry->iInsColCnt-1)) {
                strcat(cpP, ", ");  cpP += 2;
            }
        }
        cpP += sprintf(cpP, ")");

        if (spQry->cMrgWhenMatchYn == DEF_YES) {   // when match가 없으면 update가 없다. 
            cpP += sprintf(cpP, " ON CONFLICT (");
        
            for (iF0=0; iF0<spQry->iKeyColCnt; iF0++) {
                // key column name
                cpP += sprintf(cpP, "%s", spQry->ca2KeyColNm[iF0]);  
                if (iF0 != (spQry->iKeyColCnt-1)) {
                    strcat(cpP, ", ");  cpP += 2;
                }
            }
            cpP += sprintf(cpP, ") DO UPDATE SET ");
        
            for (iF0=0; iF0<spQry->iNoKeyColCnt; iF0++) {
                cpP += sprintf(cpP, "%s = EXCLUDED.%s", spQry->ca2NoKeyColNm[iF0], spQry->ca2NoKeyColNm[iF0]);  
                if (iF0 != (spQry->iNoKeyColCnt-1)) {
                    strcat(cpP, ", ");  cpP += 2;
                }
            }
        } 
        else {  // ON CONFLICT ( con_id, originating_timestamp, message_hash) DO NOTHING
            cpP += sprintf(cpP, " ON CONFLICT (");
        
            for (iF0=0; iF0<spQry->iKeyColCnt; iF0++) {
                // key column name
                cpP += sprintf(cpP, "%s", spQry->ca2KeyColNm[iF0]);  
                if (iF0 != (spQry->iKeyColCnt-1)) {
                    strcat(cpP, ", ");  cpP += 2;
                }
            }
            cpP += sprintf(cpP, ") DO NOTHING");
        }
        iCpLen = strlen(caQuery);
        spQry->cpMrgQry = (char *)dcMalloc(iCpLen + 1);
        memcpy(spQry->cpMrgQry, caQuery, iCpLen);
        
        LOGD("upsert:[%s]\n", spQry->cpMrgQry);
        LOGD("spQry->cRunMethod:%c[%s]\n", spQry->cRunMethod, daPrintRunMethod(spQry->cRunMethod));
    }
    CATCH 
    FINALLY 
    END 
}

int
daGetMrgQry(qry_t *spQry)
{
    char    *cpP, *cpRet1, *cpRet2;
    int     iCpLen;

    TRY { 
        cpP = spQry->cpQuery;

        // select 구함.
        cpRet1 = strcasestr(cpP, "using");
        if(!cpRet1) { LOGE("not found USING in the MERGE\n"); THROW(1); }
        cpP = cpRet1;

        cpRet1 = strcasestr(cpP, "select");
        if(!cpRet1) { LOGE("not found select in the MERGE\n"); THROW(1); }


        cpRet2 = strcasestr(cpP, " on (");
        if(!cpRet2) { LOGE("not found on in the MERGE\n"); THROW(1); }

        for (cpP=cpRet2; *cpP; cpP--) {
            cpRet2--; if(*cpP == ')')     break;
        }        

        iCpLen = cpRet2 - cpRet1;

        spQry->cpSelQry = (char *)dcMalloc(iCpLen + 1);
        memcpy(spQry->cpSelQry, cpRet1, iCpLen);
        LOGD("select:[%s]\n", spQry->cpSelQry);


        cpP = spQry->cpQuery;
        cpRet1 = strcasestr(cpP, " INTO ");
        if(!cpRet1) { LOGE("not found INTO in the MERGE\n"); THROW(1); }
        cpP = cpRet1 + 6;
    
        cpRet1 = strchr(cpP, ' ');
        iCpLen = cpRet1 - cpP;
        memcpy(spQry->caInsTblNm, cpP, iCpLen);
        LOGD("table:[%s]\n", spQry->caInsTblNm);

        if(strcasestr(spQry->cpQuery, "WHEN MATCHED THEN UPDATE SET"))  spQry->cMrgWhenMatchYn = DEF_YES;
        else                                                            spQry->cMrgWhenMatchYn = DEF_NO;
 

        // key 찾기
        CALL(daGetKeyColFromMrgQry(spQry));

        // for insert column
        CALL(daGetInsColFromMrgQry(spQry));

        // for update statement 생성
        CALL(daGenUpsertQryFromMrgQry(spQry));
    } 
    CATCH 
    FINALLY 
    END 
}


int
daGetQry()
{
    int     iF0;
    qry_t   *spQry;

    TRY { 
        for(iF0=0; iF0<sQryInfo.iLstIdx; iF0++) {
            spQry = &sQryInfo.saQry[iF0];

            if (!strncasecmp(spQry->cpQuery, "MERGE", 5)) {
                // merge
                spQry->cRunMethod = RUN_METHOD_MERGE;
                CALL(daGetMrgQry(spQry));
            }
            else {
                // insert, select 를 구분하여 저장한다.
                spQry->cRunMethod = RUN_METHOD_INSERT;
                CALL(daGetInsQry(spQry));
    
            
                if(!spQry->iCycle || (spQry->cpInsQry && strlen(spQry->cpInsQry) <= 0))  {
                    spQry->cRunMethod = RUN_METHOD_SELECT;
                    continue;
                }

                CALL(daGetInsColFromInsQry(spQry));
            }
        }
    } 
    CATCH 
    FINALLY 
    END 
}

static void
daPrintQryInfo()
{
    int     iF0, iF1;
    qry_t   *spQry;
    char    caBuf[4096*2];

    LOGD("------------------------------------------------------------------------------------\n");
    LOGD("query count:%d\n", sQryInfo.iLstIdx);
    for (iF0=0; iF0<sQryInfo.iLstIdx; iF0++) {
        spQry = &sQryInfo.saQry[iF0];
    
        LOGD("%02d/%02d [%c-%-6s] title:[%s], cycle:%d\n", iF0+1, sQryInfo.iLstIdx
            , spQry->cRunMethod , daPrintRunMethod(spQry->cRunMethod), spQry->caTitle, spQry->iCycle);
        if (spQry->cRunMethod == RUN_METHOD_MERGE) {
            LOGD("merge when match yn:(%c) \n", spQry->cMrgWhenMatchYn);
            LOGD("upsert:[%s]\n", spQry->cpMrgQry);
        }
        if (gcDebugMode == DEF_YES) {
            LOGD("query:[%s] \n", spQry->cpQuery);
            if(spQry->cpInsQry) LOGD("insert state:[%s] \n", spQry->cpInsQry);
            if(spQry->cpSelQry) LOGD("select state:[%s] \n", spQry->cpSelQry);

            LOGD("insert table name:[%s] \n", spQry->caInsTblNm);
            LOGD("insert column count:(%d) \n", spQry->iInsColCnt);

            memset(caBuf, 0x00, sizeof(caBuf));
            for (iF1=0; iF1<spQry->iInsColCnt; iF1++) {
                strcat(caBuf, spQry->ca2InsColNm[iF1]);
                if (iF1 != (spQry->iInsColCnt -1))    strcat(caBuf, ",");
            }

            LOGD("insert key count:(%d) \n", spQry->iKeyColCnt);

            memset(caBuf, 0x00, sizeof(caBuf));
            for (iF1=0; iF1<spQry->iKeyColCnt; iF1++) {
                strcat(caBuf, spQry->ca2KeyColNm[iF1]);
                if (iF1 != (spQry->iKeyColCnt -1))    strcat(caBuf, ",");
            }
            LOGD("insert key columns:[%s]\n", caBuf);
            LOGD("copy commands:[%s]\n", spQry->cpCopyCmd);
        }
        
        #if 0
        for (iF1=0; iF1<spQry->iInsColCnt; iF1++) {
            LOGD("insert column name:%02d:[%s]) \n", iF1, spQry->ca2InsColNm[iF1]);
        }
        #endif
    }
    LOGD("------------------------------------------------------------------------------------\n");
    return;
}

static int
daUsage(char *cpMsg, char **argv) 
{
    printf("%s \n", cpMsg);
    printf("\n");
// C:one cycle, D:debug mode, S:stdout, 
    printf("db monitoring process!\n");
    printf("Usage] %s [-h] [-n query_index] [-r] [-T title_name]            \n", argv[0]);
    printf("          -h this Usage message                                                 \n");
    printf("          -n 실행할 query index 번호                                            \n");
    printf("             index는 [1~%d] 입니다.                                             \n", siQryCnt);
    printf("          -r 기중중인 프로세스 종료시키고 기동                                  \n");
    printf("             default는 같은 query file을 처리하는 프로세스가 기동중이면 종료    \n");
    printf("          -T 실행시킬 Title 이름                                                \n");
    printf("             cfg 중 -T로 지정한 title만 실행.                                   \n");
    printf("         단, 컬럼수는 %d개, query는 %d개, query 1개당 %dKbyte 까지만 지원됩니다.\n"
                        , DBD_COL_MAX_CNT, DBD_QUERY_MAX_CNT, (DBD_QUERY_MAX_LEN)/1024);
    printf(" \n");            
    printf(" %s version:%s \n", argv[0], DBD_VERSION);
    printf("\n");
    exit(1);
}



static int
daGetOpt(int argc, char **argv) 
{
    int     iOpt;
    char    *cpRet;

    TRY { 
        strcpy(scaPgNm, argv[0]);
        while((iOpt=getopt(argc, argv, "q:T:n:CDsrhv")) != -1) {
            switch(iOpt) {
                case    'q':    strcpy(scaArgQryFileNm, optarg);    break;  // query file
                case    'n':    siArgQryIdx = atoi(optarg);         break;  // index of query file
                case    'C':    gcOnlyOneCycle  = DEF_YES;          break;  // only check sql
                case    'D':    gcDebugMode = DEF_YES;              break;  // debug mode
                case    'T':    strcpy(scaTgtTitle, optarg);        
                                gcOnlyOneTitle = DEF_YES;           break;  // 실행할 title
                case    's':    scStdoutYn = DEF_YES;               break;  // no log, stdtout
                case    'r':    scRestartYn = DEF_YES;              break;  // 이전 기동프로세스 종료

                case    'h':    daUsage("", argv);                  break;
                case    'v':    daUsage("Version", argv);           break;
                default:        printf("not define, opt:%d\n", iOpt);
                                daUsage("Usage", argv);
            }
        }

        // 필수 인자 검사
        if (strlen(scaArgQryFileNm) <= 0 && (siArgQryIdx < 1 || siArgQryIdx > siQryCnt)) {
            daUsage("-n 실행할 query index는 필수입니다.", argv);
        }

        if (siArgQryIdx < 0 && strlen(scaArgQryFileNm) <= 0)  { 
            daUsage("-q 실행할 query file이름은 필수 입니다.", argv);
        }

        cpRet = strrchr(scaArgQryFileNm, '/');
        if (cpRet) {
            strcpy(scaQryFileNm, cpRet+1);
        }
        else {
            strcpy(scaQryFileNm, scaArgQryFileNm);
        }
    } 
    CATCH 
    FINALLY 
    END 
}

static int
daInitEnv()
{
    const char *cpHostIp= ENV_REQUIRED(INS_PG_HOST_IP);
    const char *cpPort  = ENV_REQUIRED(INS_PG_PORT);
    const char *cpDb    = ENV_REQUIRED(INS_PG_DATABASE_NAME);
    const char *cpUser  = ENV_REQUIRED(INS_PG_USER);
    const char *cpPass  = ENV_REQUIRED(INS_PG_PASS);

    // for postgre
    snprintf(gcaPgHostIp, sizeof(gcaPgHostIp), "%s", cpHostIp);
    snprintf(gcaPgPort  , sizeof(gcaPgPort)  , "%s", cpPort  );
    snprintf(gcaPgDbNm  , sizeof(gcaPgDbNm)  , "%s", cpDb    );
    snprintf(gcaPgUser  , sizeof(gcaPgUser)  , "%s", cpUser  );
    snprintf(gcaPgPass  , sizeof(gcaPgPass)  , "%s", cpPass  );


    daDBEnv();

    return(0);
}



// -r: scRestartYn가 DEF_YES 이면 기동중인것이 있으면 종료시키고 기동
// default:  기동중인것이 있으면 그냥 exit
//    
// 
static int
daChkDupProcess(char **argv) 
{
    char        caFileNm[1024];
    char        caLine[1024];
    FILE        *fpFile;
    pid_t       ptPid;

    TRY { 
        daGetDupChkFileNm(caFileNm, sizeof(caFileNm));

        fpFile = fopen(caFileNm, "r+");
        if(fpFile != NULL) {
            if(fgets(caLine, sizeof(caLine), fpFile)) {
                ptPid = atoi(caLine);
                if(!kill(ptPid, 0)) {    // 살아있다면
                    if (scRestartYn == DEF_YES) {    // 살이 있는데 restart=yes이면 돌던것 종료시킨다. 
                        kill(ptPid, SIGKILL);
                    }
                    else {
                        fprintf(stderr, "기동중인 프로세스가 있어 기동하지 못했습니다.\n");
                        fprintf(stderr, "기동중인 프로세스의 pid는 %d 입니다\n", ptPid);
                        fprintf(stderr, "만약, 종료시키고 기동하고 싶으시다면 기동시 -r 옵션을 사용하세요. \n");
                        daUsage("", argv);
                    }
                }
            }
        }
        if(fpFile)    fclose(fpFile);
    } 
    CATCH 
    FINALLY 
    END 
}

static int
daWriteMyPid()
{
    char        caFileNm[1024];
    char        caLine[1024];
    FILE        *fpFile;

    TRY { 
        daGetDupChkFileNm(caFileNm, sizeof(caFileNm));

        do {
            fpFile = fopen(caFileNm, "w+");
            if(fpFile == NULL) {
                if (errno == 2) {
                    const char  *cpDir = ENV_REQUIRED(DBD_DATDIR);
                    if(mkdir(cpDir, 0755)) {
                        LOGE("[%s] dir를 make하지 못했습니다.[%d,%s] \n", caFileNm, errno, strerror(errno));
                        THROW(1);
                    }
    
                }
                else {
                    LOGE("[%s] file을 open하지 못했습니다.[%d,%s] \n", caFileNm, errno, strerror(errno));
                    THROW(2);
                }
            }
            else break;
        } while(1);

        sprintf(caLine, "%8d", getpid());
        fseek(fpFile, 0L, SEEK_SET);
        fwrite(caLine, strlen(caLine), 1, fpFile);
    
        fclose(fpFile);
    } 
    CATCH 
    FINALLY 
    END 
}

int
daLogStart(char **argv)
{
    char    caLogFileNm[1024];

    TRY { 
        if (scStdoutYn == DEF_NO) {

            daGetLogFileNm(caLogFileNm, sizeof(caLogFileNm));
            //dcLoggerInit(caLogFileNm);
            dcLogStart(argv[0], caLogFileNm, 5, 1024, 1024*10);
        }
    
    } 
    CATCH 
    FINALLY 
    END 
}

int
main(int argc, char **argv)
{
    TRY {
        CALL(daGetOpt(argc, argv));

        CALL(daInitEnv());

        CALL(daChkDupProcess(argv));

        CALL(dcDaemonize(scStdoutYn));

        CALL(daLogStart(argv));

        CALL(daReadQueryFile());        // query from senario.txt

        CALL(daGetQry());               // parshing from query statement

        daPrintQryInfo();


        CALL(daWriteMyPid());

        CALL(daRunWorker());
    }
    CATCH
        if (scStdoutYn == DEF_NO) {
            char    caLogFileNm[1024], caBuf[2024];
            daGetLogFileNm(caLogFileNm, sizeof(caLogFileNm));
            snprintf(caBuf, sizeof(caBuf), "tail -n 6 %s | grep \"^E\"", caLogFileNm);
            systemPrint(caBuf);
        }

        sleep(1);
        dcLogKill();
        return(-1);
    FINALLY {
        LOGD("\n");
    }
    END
}
