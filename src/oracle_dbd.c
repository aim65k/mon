#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <oci.h>
#include <sqlda.h>
#define SQLCA_STORAGE_CLASS
#include <sqlca.h>
#include <sqlcpr.h>
#define ORACA_STORAGE_CLASS
#include <oraca.h>                                                                                            

#include <libpq-fe.h>
#include "string_db.h"
#include "oracle_dbd.h"
#include "insert_dbd.h"
#include "common_dbd.h"

extern char gcOnlyOneCycle;
extern char  gcDebugMode;


static void 
daOracleDie(qry_t *spQry, OCIError *errhp, char cExitYn, const char *msg)
{
    text errbuf[1024];
    sb4 errcode = 0;

    spQry->cRslt = DEF_NO;
    if (errhp) {
        OCIErrorGet(errhp, 1, NULL, &errcode, errbuf, sizeof(errbuf), OCI_HTYPE_ERROR);
        LOGE("OCI ERROR [%s] code=%d msg=%s\n", msg, errcode, errbuf);
        spQry->sErr.iErrCd = errcode;
        snprintf(spQry->sErr.caPart, sizeof(spQry->sErr.caPart), "%s", msg);
        snprintf(spQry->sErr.caErrMsg, sizeof(spQry->sErr.caErrMsg), "%s", errbuf);
    } else {
        spQry->sErr.iErrCd = 0;
        snprintf(spQry->sErr.caPart, sizeof(spQry->sErr.caPart), "%s", msg);
        snprintf(spQry->sErr.caErrMsg, sizeof(spQry->sErr.caErrMsg), "%s", "");
        LOGE("OCI ERROR [%s]\n", msg);
    }
    
    if(cExitYn == EXIT_YES) exit(1);
}

static void 
daOralceInit(qry_t *spQry)
{
    memset(spQry->sDb.ora_defhp, 0x00, sizeof(spQry->sDb.ora_defhp));
    memset(spQry->sDb.colbuf,    0x00, sizeof(spQry->sDb.colbuf));
    memset(spQry->sDb.ind,       0x00, sizeof(spQry->sDb.ind));
    memset(spQry->sDb.rlen,      0x00, sizeof(spQry->sDb.rlen));
    
    spQry->sDb.ora_stmt= NULL;
    spQry->iSelColCnt     = 0;
    spQry->cpSelResult = NULL;
}

const char *cpUser;
const char *cpPass;
const char *cpDb;

void
daDBEnv()
{
    cpUser = ENV_REQUIRED(ORACLE_USER);
    cpPass = ENV_REQUIRED(ORACLE_PASS);
    cpDb   = ENV_REQUIRED(ORACLE_SERVICE_NAME);
    return;
}
int 
daDBOpen(qry_t *spQry)
{
    OCIEnv    *envhp = NULL;
    OCIError  *errhp = NULL;
    OCISvcCtx *svchp = NULL;



    daOralceInit(spQry);

    if (OCIEnvCreate(&envhp, OCI_THREADED | OCI_OBJECT, NULL, NULL, NULL, NULL, 0, NULL) != OCI_SUCCESS) {
        daOracleDie(spQry, NULL, EXIT_YES, "OCIEnvCreate failed");
    }

    if (OCIHandleAlloc(envhp, (void **)&errhp, OCI_HTYPE_ERROR, 0, NULL) != OCI_SUCCESS)
        daOracleDie(spQry, NULL, EXIT_YES, "OCIHandleAlloc ERROR failed");

    if (OCILogon(envhp, errhp, &svchp, (OraText *)cpUser, (ub4)strlen(cpUser)
            , (OraText *)cpPass, (ub4)strlen(cpPass), (OraText *)cpDb, (ub4)strlen(cpDb)) != OCI_SUCCESS) {
        daOracleDie(spQry, errhp, EXIT_YES, "OCILogon failed");
    }

    spQry->sDb.ora_env = envhp;
    spQry->sDb.ora_err = errhp;
    spQry->sDb.ora_svc = svchp;

    signal(SIGINT, SIG_DFL);

    return 0;
}

static void
daMallocMgrRow(qry_t *spQry)
{
    int     iF0;

    spQry->cppMrgRow = (char **)dcMalloc(sizeof(char *) * spQry->iSelColCnt);
    ASSERT(spQry->cppMrgRow);

    for (iF0 = 0; iF0 < spQry->iSelColCnt; iF0++) {
        spQry->cppMrgRow[iF0] = (char *)dcMalloc(spQry->sDb.col_buf_size[iF0]);
        ASSERT(spQry->cppMrgRow[iF0]);

        spQry->cppMrgRow[iF0][0] = 0x00;
    }

    return;
}

static ub4 
daGetOciOutBufSize(text *cpColNm, ub2 dtype, ub2 dsize)
{
    switch (dtype) {
        case SQLT_NUM:
        case SQLT_INT:
        case SQLT_UIN:
        case SQLT_FLT:
        case SQLT_BDOUBLE:
        case SQLT_BFLOAT:
                return 128;

        case SQLT_DAT:
                return 64;

        case SQLT_TIMESTAMP:
        case SQLT_TIMESTAMP_TZ:
        case SQLT_TIMESTAMP_LTZ:
                return 128;

        case SQLT_CHR:
        case SQLT_AFC:
        case SQLT_AVC:
        case SQLT_VCS:
                if (dsize > 0 && dsize < 32767)
                    return (ub4)dsize + 4;
                return 8192;

        case SQLT_CLOB: // 내가 옮긴거임
                // CLOB은 dsize(Locator 크기=4or8)를 사용하면 버퍼가 부족해집니다.
                // Fetch 시 SQLT_CHR로 바인딩하여 텍스트를 받아올 최대 버퍼 크기를 지정합니다.
                return 65536; // 64KB (검증 데이터 스펙에 맞춰 조절)


        case SQLT_BLOB:
        case SQLT_BFILE:
        case SQLT_LNG:
                EXIT("[%s] unsupported type:%d", cpColNm, dtype);
                break;
        default:
            return 8192;
    }
}

static const char *
daGetMariaFieldTypeString(ub2 dtype) {
    switch (dtype) {
        case SQLT_CHR:  return "VARCHAR2 / VARCHAR";
        case SQLT_NUM:  return "NUMBER";
        case SQLT_INT:  return "INTEGER";
        case SQLT_FLT:  return "FLOAT";
        case SQLT_STR:  return "STRING";
        case SQLT_VNU:  return "VARNUM";
        case SQLT_LNG:  return "LONG";
        case SQLT_VCS:  return "VARCHAR";
        case SQLT_DAT:  return "DATE";
        case SQLT_BIN:  return "RAW";
        case SQLT_LBI:  return "LONG RAW";
        case SQLT_UIN:  return "UNSIGNED INT";
        case SQLT_AFC:  return "CHAR";
        case SQLT_AVC:  return "CHARZ";
        case SQLT_RID:  return "ROWID";
        case SQLT_NTY:  return "NAMED TYPE (Object/Named Collection)";
        case SQLT_REF:  return "REF";
        case SQLT_CLOB: return "CLOB";
        case SQLT_BLOB: return "BLOB";
        case SQLT_BFILE:return "BFILE";
        case SQLT_TIMESTAMP:     return "TIMESTAMP";
        case SQLT_TIMESTAMP_TZ:  return "TIMESTAMP WITH TIME ZONE";
        case SQLT_TIMESTAMP_LTZ: return "TIMESTAMP WITH LOCAL TIME ZONE";
        case SQLT_INTERVAL_YM:   return "INTERVAL YEAR TO MONTH";
        case SQLT_INTERVAL_DS:   return "INTERVAL DAY TO SECOND";
        default:        return "UNKNOWN OCI TYPE";
    }
}

int 
daDBPrepare(qry_t *spQry)
{
    OCIEnv      *envhp  = (OCIEnv *)spQry->sDb.ora_env;
    OCIError    *errhp  = (OCIError *)spQry->sDb.ora_err;
    OCISvcCtx   *svchp  = (OCISvcCtx *)spQry->sDb.ora_svc;
    OCIStmt     *stmthp = NULL;
    OCIDefine   *defhp  = NULL;
    OCIParam    *param  = NULL;

    text *col_name = NULL;
    ub4   col_name_len = 0;

    ub2   dtype = 0;
    ub2   dsize = 0;
    ub2   char_size = 0;
    ub1   char_used = 0;
    ub1   precision = 0;
    sb1   scale = 0;


    const char  *sql_text = spQry->cpSelQry;
    ub4          col_cnt = 0;
    ub4          i;
    sword        rc;

    // 1. Statement 핸들 할당
    if (OCIHandleAlloc(envhp, (void **)&stmthp, OCI_HTYPE_STMT, 0, NULL) != OCI_SUCCESS) {
        daOracleDie(spQry, errhp, EXIT_YES, "OCIHandleAlloc STMT failed");
        return -1;
    }
    
    spQry->sDb.ora_stmt = stmthp;

    // 2. SQL Prepare
    rc = OCIStmtPrepare(stmthp, errhp, (const OraText *)sql_text, (ub4)strlen(sql_text), OCI_NTV_SYNTAX, OCI_DEFAULT);
    if (rc != OCI_SUCCESS) {
        daOracleDie(spQry, errhp, EXIT_YES, "OCIStmtPrepare failed");
        return -1;
    }

    if (gcDebugMode == DEF_YES) {
        LOGD("[%s] sql_text:[%s]\n", spQry->caTitle, sql_text); 
    }

    // 3. DESCRIBE로 컬럼 정보 획득
    rc = OCIStmtExecute(svchp, stmthp, errhp, 0, 0, NULL, NULL, OCI_DESCRIBE_ONLY);
    if (rc != OCI_SUCCESS) {
        LOGE("[%s] OCIStmtExecute DESCRIBE_ONLY failed, sql_text:[%s]\n", spQry->caTitle, sql_text);
        daOracleDie(spQry, errhp, EXIT_YES, "OCIStmtExecute DESCRIBE_ONLY failed");
        return -1;
    }

    // 4. 컬럼 개수 확인
    rc = OCIAttrGet(stmthp, OCI_HTYPE_STMT, &col_cnt, NULL, OCI_ATTR_PARAM_COUNT, errhp);
    if (rc != OCI_SUCCESS) {
        daOracleDie(spQry, errhp, EXIT_YES, "OCIAttrGet PARAM_COUNT failed");
        return -1;
    }

    if (col_cnt > MAX_COLS)
        col_cnt = MAX_COLS;

    if ((int)col_cnt != spQry->iInsColCnt) {
        LOGE("[%s] insert(%d) 와  select(%d) 의 컬럼숫자가 다릅니다.,exit\n"
            , spQry->caTitle, spQry->iInsColCnt, col_cnt);
        exit(1);
    }
    spQry->iSelColCnt = col_cnt;

    spQry->sDb.col_buf_size =  (ub4 *)dcMalloc(sizeof(ub4 *)*col_cnt);

    // 5. 컬럼별 버퍼 할당 및 Define
    for (i = 0; i < col_cnt; i++) {
        param = NULL;
        rc = OCIParamGet(stmthp, OCI_HTYPE_STMT, errhp, (void **)&param, i+1);
        
        // 컬럼명
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &col_name, &col_name_len, OCI_ATTR_NAME, errhp);
        // Oracle 내부 타입
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &dtype, NULL, OCI_ATTR_DATA_TYPE, errhp); 
        // 최대 byte길이
        rc = OCIAttrGet(param , OCI_DTYPE_PARAM, &dsize, NULL, OCI_ATTR_DATA_SIZE, errhp);
        // Number precision
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &precision, NULL, OCI_ATTR_PRECISION, errhp);
        // Number scale
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &scale, NULL, OCI_ATTR_SCALE, errhp);
        // BYTE(0)/CHAR(1)
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &char_used, NULL, OCI_ATTR_CHAR_USED, errhp);
        // 문자길이(CHAR semantics
        rc = OCIAttrGet(param, OCI_DTYPE_PARAM, &char_size, NULL, OCI_ATTR_CHAR_SIZE, errhp);

        
        if (gcDebugMode == DEF_YES) {
            LOGD("%d [%-30.*s] type=[%-3d.%s] data_size=%-5u char_size=%-5u prec=%-3u scale=%-3d char_used=%-d\n"
                ,i ,(int)col_name_len, (char *)col_name
                , dtype, daGetMariaFieldTypeString(dtype), dsize, char_size, precision, scale, char_used);
        }

        spQry->sDb.col_buf_size[i] = daGetOciOutBufSize(col_name, dtype, dsize);
        spQry->sDb.colbuf[i] = (char *)dcMalloc(spQry->sDb.col_buf_size[i] + 1);
        memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i] + 1);

        defhp = NULL;
        rc = OCIDefineByPos(stmthp, &defhp, errhp, i + 1, spQry->sDb.colbuf[i]
                        , spQry->sDb.col_buf_size[i], SQLT_STR, &spQry->sDb.ind[i]
                        , &spQry->sDb.rlen[i], NULL, OCI_DEFAULT);
        if (rc != OCI_SUCCESS) {
            daOracleDie(spQry, errhp, EXIT_YES, "OCIDefineByPos failed");
            return -1;
        }

        spQry->sDb.ora_defhp[i] = defhp;
        if(param)    OCIHandleFree(param, OCI_DTYPE_PARAM); 
    }

    if (spQry->cRunMethod == RUN_METHOD_MERGE) {
        daMallocMgrRow(spQry);
    }
    
    if (gcDebugMode == DEF_YES) LOGD("Oracle prepared, title:%s, cols:%d\n", spQry->caTitle, col_cnt);
    
    return 0;
}

int
daDBSelect(qry_t *spQry)
{
    OCIError    *errhp;
    OCISvcCtx   *svchp;
    OCIStmt     *stmthp;

    int          i;
    sword        rc;
    size_t       cap, len;
    char        *rowbuf = NULL;

    errhp  = (OCIError *)spQry->sDb.ora_err;
    svchp  = (OCISvcCtx *)spQry->sDb.ora_svc;
    stmthp = (OCIStmt *)spQry->sDb.ora_stmt;

    spQry->iSelCnt = 0;

    rc = OCIStmtExecute(svchp, stmthp, errhp, 0, 0, NULL, NULL, OCI_DEFAULT);
    if (rc != OCI_SUCCESS && rc != OCI_SUCCESS_WITH_INFO) {
        daOracleDie(spQry, errhp, EXIT_YES, "OCIStmtExecute failed");
        return -1;
    }

    while (1) {
        for (i = 0; i < spQry->iSelColCnt; i++) {
            memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i]);
            spQry->sDb.ind[i] = 0;
            spQry->sDb.rlen[i] = 0;
        }

        rc = OCIStmtFetch2(stmthp, errhp, 1, OCI_FETCH_NEXT, 0, OCI_DEFAULT);

        if (rc == OCI_NO_DATA)
            break;

        if (rc != OCI_SUCCESS && rc != OCI_SUCCESS_WITH_INFO) {
            daOracleDie(spQry, errhp, EXIT_NO, "OCIStmtFetch2 failed");
            extern int daStopQry(qry_t *spQry);
            daStopQry(spQry); 
            FREE(rowbuf);
            return -1;
        }

        cap = LINE_BUF_INIT;
        len = 0;
        rowbuf = (char *)dcMalloc(cap);
        rowbuf[0] = 0x00;

        for (i = 0; i < spQry->iSelColCnt; i++) {
            if (spQry->cRunMethod == RUN_METHOD_INSERT) {
                if (i > 0)
                    daAppendString(&rowbuf, &cap, &len, "\t");
    
                if (spQry->sDb.ind[i] < 0) {
                    daAppendString(&rowbuf, &cap, &len, "\\N");
                }
                else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = 0x00;
                    dcAllTrimLen(spQry->sDb.colbuf[i], (int)strlen(spQry->sDb.colbuf[i]));

                    char *esc = daEscapePgCopyField(spQry->sDb.colbuf[i]);
                    daAppendString(&rowbuf, &cap, &len, esc);
                    FREE(esc);
                }
            }
            else {
                if (spQry->sDb.ind[i] < 0) {
                    spQry->cppMrgRow[i][0] = 0x00;
                } else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = 0x00;
                    dcAllTrimLen(spQry->sDb.colbuf[i], (int)strlen(spQry->sDb.colbuf[i]));

                    snprintf(spQry->cppMrgRow[i], spQry->sDb.col_buf_size[i], "%s", spQry->sDb.colbuf[i]);
                }
            }
        }

        daAppendString(&rowbuf, &cap, &len, "\n");

        if (spQry->cRunMethod == RUN_METHOD_INSERT) {
            if (daPgCopyPutRow(spQry, rowbuf) != 0) {
                FREE(rowbuf);
                return -1;
            }
        }
        else {
            daMrgRowToPostgre(spQry);
        }

        FREE(rowbuf);
        spQry->iSelCnt++;
    }

    daPrintInsReslt(spQry);

    return 0;
}
