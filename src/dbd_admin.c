#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <time.h>
#include "common_db.h"
#include "string_db.h"
#include "daemon_db.h"
#include "main_dbd.h"

#define MAX_PROCS 100
#define MAX_LINE 512
#define MAX_ARGS 32

char scaPgNm[128];

// 프로그램 정보를 담을 구조체
typedef struct {
    char caTitle[64];
    char cUseYn;        // 'Y' 또는 'N'
    int delay_sec;       // 재기동 지연 시간
    char cmd_path[128];  // 실행 파일 경로
    char caCmd[256];// execvp에 넘겨줄 인자 리스트
    pid_t ptPid;         // 현재 실행 중인 자식 프로세스 ID (실행 안 되면 0)
} ProcessInfo;

static ProcessInfo proc_list[MAX_PROCS];
static int siProcCnt = 0;

// 설정 파일 로드 및 파싱
int 
loadCfg(char **argv) 
{
    const char *cpCfgDir=ENV_REQUIRED(DBD_CFGDIR);
    const char *cpBinDir=ENV_REQUIRED(DBD_BINDIR);
    const char *cpFileNm=ENV_REQUIRED(DBD_ADMIN_FILE);
    char    caFullFileNm[1024];
    char    caLineBuf[MAX_LINE];
    char    *cpStartP;
    char    *cpToken;
    char    caTmp[128];
    int     iCpLen;

    strcpy(scaPgNm, basename(argv[0]));
    sprintf(caFullFileNm, "%s/%s", cpCfgDir, cpFileNm);

    FILE *fp = fopen(caFullFileNm, "r");
    if (!fp) {
        perror("설정 파일을 열 수 없습니다");
        return(-1);
    }

    while (fgets(caLineBuf, sizeof(caLineBuf), fp) && siProcCnt < MAX_PROCS) {
        // 주석(#)이나 빈 줄은 건너뜀
        if (caLineBuf[0] == '#' || caLineBuf[0] == '\n' || caLineBuf[0] == '\r') continue;

        // 개행 문자 제거
        caLineBuf[strcspn(caLineBuf, "\r\n")] = 0;


        ProcessInfo *p = &proc_list[siProcCnt];
        
        // 1. 타이틀 파싱
        cpStartP = caLineBuf;
        cpToken = strchr(cpStartP, ',');
        if (!cpToken) continue;
        if(cpStartP == (cpToken - 1)) iCpLen = 1;
        else                          iCpLen = cpStartP - (cpToken - 1);
        strncpy(p->caTitle, cpStartP, iCpLen);
        dcAllTrimLen(p->caTitle, iCpLen);


        // 2. 사용 유무 파싱
        cpStartP = cpToken+1;
        cpToken = strchr(cpStartP, ',');
        if (!cpToken) continue;
        if(cpStartP == (cpToken - 1)) iCpLen = 1;
        else                          iCpLen = cpStartP - (cpToken - 1);
        strncpy(caTmp, cpStartP, iCpLen);
        dcAllTrimLen(caTmp, iCpLen);
        p->cUseYn = caTmp[0];

        if (p->cUseYn == 'y' || p->cUseYn == 'Y')   p->cUseYn = DEF_YES;
        else if (p->cUseYn == 'n' || p->cUseYn == 'N')   p->cUseYn = DEF_NO;
        else {
            LOGE("사용유무는  Y/N 만 가능 합니다.[%s](%c) \n", caLineBuf, p->cUseYn);
            return(-2);
        }

        
        // 3. 재기동 지연시간 파싱
        cpStartP = cpToken+1;
        cpToken = strchr(cpStartP, ',');
        if (!cpToken) continue;
        if(cpStartP == (cpToken - 1)) iCpLen = 1;
        else                          iCpLen = cpStartP - (cpToken - 1);
        strncpy(caTmp, cpStartP, iCpLen);
        dcAllTrimLen(caTmp, iCpLen);
        p->delay_sec = atoi(caTmp);


        // 4. 실행 파일 경로 및 인자 파싱
        strcpy(p->cmd_path, cpBinDir);

        // execvp용 인자 배열 구성 (첫 번째 인자는 실행 파일명이어야 함)
        cpStartP = cpToken+1;
        strcpy(caTmp, cpStartP);
        dcAllTrimLen(caTmp, iCpLen);

        sprintf(p->caCmd, "%s/%s", cpBinDir, caTmp);
        p->ptPid = 0;
        siProcCnt++;
    }
    fclose(fp);
    //LOGD("설정 파일을 로드했습니다.\n");
    return(0);
}

// 자식 프로세스 실행 함수
int
startProcess(ProcessInfo *p) 
{
    pid_t ptPid = fork();
    char *args[32];
    char cmd_copy[512];

    if (ptPid < 0) {
        LOGE("fork 생성 실패! \n");
    } else if (ptPid == 0) {
        int idx = 0;
        strcpy(cmd_copy, p->caCmd);
        char *token = strtok(cmd_copy, " ");
        while (token != NULL && idx < 31) {
            args[idx++] = token;
            token = strtok(NULL, " ");
        }
        args[idx] = NULL;

        execv(args[0], args);
        
        perror("execvp 실패");
        exit(EXIT_FAILURE);
    } else {
        // 부모 프로세스 영역: 자식의 PID를 기록
        p->ptPid = ptPid;
        LOGD("프로세스가 시작되었습니다. (PID: %d) - [%s] \n", ptPid, p->caCmd);
    }
    return(0);
}

int
runProcess()
{
    // 1. 설정 로드

    if (siProcCnt == 0) {
        LOGD("기동 할 프로세스가 없습니다 \n" );
        return(-1);
    }


    // 2. 'Y'로 설정된 프로세스 최초 기동
    for (int i = 0; i < siProcCnt; i++) {
        if (proc_list[i].cUseYn == DEF_YES) {
            startProcess(&proc_list[i]);
        } else {
            LOGD("[%s] 사용 안 함(N) 설정으로 인해 기동을 건너뜁니다. \n", proc_list[i].caTitle);
        }
    }

    // 3. 무한 루프를 돌며 자식 프로세스 상태 감시
    while (1) {
        int status;
        // WNOHANG 옵션으로 non-blocking 검사 진행
        // 종료된 자식이 있다면 해당 자식의 PID를 반환함
        pid_t dead_pid = waitpid(-1, &status, WNOHANG);

        if (dead_pid > 0) {
            // 어떤 프로세스가 죽었는지 찾기
            for (int i = 0; i < siProcCnt; i++) {
                if (proc_list[i].ptPid == dead_pid) {
                    LOGI("프로세스 종료 감지 (PID: %d). %d초 후 재기동합니다.\n", dead_pid, proc_list[i].delay_sec);

                    // 설정된 지연 시간만큼 대기 (이 동안은 다른 프로세스 감시가 잠깐 밀릴 수 있음)
                    // 완벽한 비동기를 원하면 이 부분도 fork나 쓰레드로 처리해야 하지만, 
                    // 일반적인 DB 재기동 레벨에서는 간단히 sleep으로 처리해도 무방합니다.
                    if (proc_list[i].delay_sec > 0) {
                        sleep(proc_list[i].delay_sec);
                    }

                    // 재기동
                    startProcess(&proc_list[i]);
                    break;
                }
            }
        } else if (dead_pid == -1) {
            // 살아있는 자식 프로세스가 아예 없는 경우 루프 과열 방지를 위해 휴식
            sleep(1);
        }

        // CPU 점유율 과열 방지를 위한 미세한 대기 (0.5초)
        usleep(500000);
    }

    return 0;
}

void
sigIntFunc(int iSigNo)
{
    int i;
    (void)iSigNo;
    fprintf(stdout, "종료 요청으로 프로그램을 종료합니다. \n");
    for(i=0; i<siProcCnt; i++) {
        kill(proc_list[i].ptPid, SIGINT);
    }
    exit(0);
}

int
signalFunc()
{
    signal(SIGINT, sigIntFunc);
    return(0);
}

static void
daGetDupChkFileNm(char *cpFileNm, int iFileNmLen)
{
    const char  *cpDir = ENV_REQUIRED(DBD_DATDIR);
    snprintf(cpFileNm, iFileNmLen, "%s/%s.dat", cpDir, scaPgNm);
    return;
}

static int
daChkDupProcess(char **argv) 
{
    char        caFileNm[1024];
    char        caLine[1024];
    FILE        *fpFile;
    pid_t       ptPid;
    (void)argv;

    TRY { 
        daGetDupChkFileNm(caFileNm, sizeof(caFileNm));

        fpFile = fopen(caFileNm, "r+");
        if(fpFile != NULL) {
            if(fgets(caLine, sizeof(caLine), fpFile)) {
                ptPid = atoi(caLine);
                if(!kill(ptPid, 0)) {    // 살아있다면
                    fprintf(stderr, "기동중인 프로세스가 있어 기동하지 못했습니다.\n");
                    fprintf(stderr, "기동중인 프로세스의 pid는 %d 입니다\n", ptPid);
                }
            }
        }
        if(fpFile)    fclose(fpFile);
    } 
    CATCH 
    FINALLY 
    END 
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

    snprintf(cpFileNm, iFileNmLen, "%s/%s_%s.log", cpDir, scaPgNm, caDt);
    return;
}
int
daLogStart(char **argv)
{
    char    caLogFileNm[1024];

    TRY { 
        daGetLogFileNm(caLogFileNm, sizeof(caLogFileNm));
        dcLogStart(argv[0], caLogFileNm, 5, 1024, 1024*10);
    } 
    CATCH 
    FINALLY 
    END 
}

int 
main(int argc, char **argv) 
{
    (void)argc;
    TRY { 
        CALL(loadCfg(argv));

        CALL(daChkDupProcess(argv));

        CALL(dcDaemonize(DEF_NO));

        CALL(signalFunc());

        CALL(daLogStart(argv));

        CALL(runProcess());
    } 
    CATCH 
    FINALLY 
    END 
}
