monitoring시 정의필요

clob의 정의: 현재 64k(사이트에 문의)

Oracle OCI에서 OCILobLocator와 OCILobRead2()를 이용해 CLOB의 실제 데이터 크기만큼 메모리를 동적으로 할당하고 읽어오는 2-Step 표준 구현 방식입니다.

이 방식을 사용하면 데이터 잘림(Truncation)이나 메모리 낭비 없이 100% 안전하게 대용량 CLOB 데이터를 처리할 수 있습니다.

1. 처리 흐름 (Workflow)
OCIDefineByPos: 쿼리 결과 바인딩 시 데이터 타입으로 SQLT_CLOB을 지정하고, 버퍼 위치에 OCILobLocator * 포인터 변수의 주소를 넘깁니다.

OCIStmtFetch2: 행(Row)을 페치합니다. 이때 OCI는 실제 텍스트가 아닌 LOB Locator(포인터)를 받아옵니다.

OCILobGetLength2: Locator를 이용해 해당 행의 실제 CLOB 길이(문자 수/바이트 수)를 구합니다.

malloc: 구한 실제 길이(+ NUL 종단문자 1바이트)만큼 메모리를 동적으로 할당합니다.

OCILobRead2: 동적 버퍼로 실제 CLOB 데이터를 읽어옵니다.

free & OCIDescriptorFree: 메모리 및 Locator 자원을 해제합니다.


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <oci.h>

// 에러 처리 함수 예시
void check_oci_error(sword status, OCIError *errhp, const char *msg) {
    if (status != OCI_SUCCESS && status != OCI_SUCCESS_WITH_INFO) {
        text errbuf[512];
        sb4 errcode = 0;
        OCIErrorGet((dvoid *)errhp, (ub4)1, (text *)NULL, &errcode,
                    errbuf, (ub4)sizeof(errbuf), OCI_HTYPE_ERROR);
        printf("[OCI ERROR] %s: %s\n", msg, errbuf);
        exit(1);
    }
}

// CLOB 동적 읽기 함수
char* fetch_clob_dynamic(OCIEnv *envhp, OCISvcCtx *svchp, OCIError *errhp, OCIStmt *stmthp, ub4 col_pos) 
{
    sword rc;
    OCILobLocator *clob_loc = NULL;
    OCIDefine *defnp = NULL;

    // 1. LOB Descriptor(Locator) 메모리 할당
    rc = OCIDescriptorAlloc((dvoid *)envhp, (dvoid **)&clob_loc, 
                            OCI_DTYPE_LOB, 0, (dvoid **)NULL);
    check_oci_error(rc, errhp, "OCIDescriptorAlloc (LOB)");

    // 2. 바인딩 (SQLT_CLOB으로 지정하여 Locator 받기)
    rc = OCIDefineByPos(stmthp, &defnp, errhp, col_pos, 
                        (dvoid *)&clob_loc, -1, SQLT_CLOB, 
                        NULL, NULL, NULL, OCI_DEFAULT);
    check_oci_error(rc, errhp, "OCIDefineByPos");

    // 3. Fetch 실행 (LOB Locator 로딩)
    rc = OCIStmtFetch2(stmthp, errhp, 1, OCI_FETCH_NEXT, 0, OCI_DEFAULT);
    if (rc == OCI_NO_DATA) {
        OCIDescriptorFree((dvoid *)clob_loc, OCI_DTYPE_LOB);
        return NULL; // 데이터 없음
    }
    check_oci_error(rc, errhp, "OCIStmtFetch2");

    // 4. 실제 CLOB 데이터의 길이(문자/바이트 단위) 구하기
    oraub8 char_len = 0;
    rc = OCILobGetLength2(svchp, errhp, clob_loc, &char_len);
    check_oci_error(rc, errhp, "OCILobGetLength2");

    // CLOB이 빈 값(EMPTY_CLOB)이거나 0바이트인 경우
    if (char_len == 0) {
        OCIDescriptorFree((dvoid *)clob_loc, OCI_DTYPE_LOB);
        char *empty_str = (char *)malloc(1);
        empty_str[0] = '\0';
        return empty_str;
    }

    // 5. UTF-8 기준 안전을 위한 버퍼 메모리 할당
    // AL32UTF8 환경에서는 한 글자당 최대 4바이트까지 늘어날 수 있으므로 넉넉히 계산
    oraub8 byte_len = char_len * 4; 
    char *buffer = (char *)malloc(byte_len + 1);
    if (!buffer) {
        printf("Memory allocation failed!\n");
        OCIDescriptorFree((dvoid *)clob_loc, OCI_DTYPE_LOB);
        return NULL;
    }

    // 6. OCILobRead2로 실제 데이터 읽기
    oraub8 byte_cnt = byte_len;   // In/Out: 버퍼 크기 -> 실제 읽어온 바이트 수
    oraub8 char_cnt = 0;          // 0으로 설정하면 byte_cnt 기준 동작

    rc = OCILobRead2(
        svchp,                  // Service Context Handle
        errhp,                  // Error Handle
        clob_loc,               // LOB Locator
        &byte_cnt,              // [In/Out] 읽을 바이트 수 / 읽어온 바이트 수
        &char_cnt,              // [In/Out] 읽을 문자가 있으면 설정 (0이면 byte 기준)
        (oraub8)1,              // Offset (1부터 시작)
        (dvoid *)buffer,        // 읽어온 데이터를 담을 동적 버퍼 주소
        byte_len,               // 버퍼 전체 용량 (Max Buffer Size)
        OCI_ONE_PIECE,          // 한 번에 전체 읽기
        NULL,                   // Context (Callback 미사용 시 NULL)
        NULL,                   // Callback 함수 (미사용 시 NULL)
        (ub2)0,                 // CSID (0 = DB/Client default character set)
        (ub1)OCI_ONE_PIECE      // CSForm
    );
    check_oci_error(rc, errhp, "OCILobRead2");

    // 7. 문자열 종료 처리 (NUL termination)
    buffer[byte_cnt] = '\0';

    // 8. LOB Descriptor 해제
    OCIDescriptorFree((dvoid *)clob_loc, OCI_DTYPE_LOB);

    // 읽어온 동적 버퍼 리턴 (호출한 쪽에서 사용 후 free() 필수)
    return buffer; 
}

Oracle OCI에서 OCILobLocator와 OCILobRead2()를 이용해 CLOB의 실제 데이터 크기만큼 메모리를 동적으로 할당하고 읽어오는 2-Step 표준 구현 방식입니다.

이 방식을 사용하면 데이터 잘림(Truncation)이나 메모리 낭비 없이 100% 안전하게 대용량 CLOB 데이터를 처리할 수 있습니다.

1. 처리 흐름 (Workflow)
OCIDefineByPos: 쿼리 결과 바인딩 시 데이터 타입으로 SQLT_CLOB을 지정하고, 버퍼 위치에 OCILobLocator * 포인터 변수의 주소를 넘깁니다.

OCIStmtFetch2: 행(Row)을 페치합니다. 이때 OCI는 실제 텍스트가 아닌 LOB Locator(포인터)를 받아옵니다.

OCILobGetLength2: Locator를 이용해 해당 행의 실제 CLOB 길이(문자 수/바이트 수)를 구합니다.

malloc: 구한 실제 길이(+ NUL 종단문자 1바이트)만큼 메모리를 동적으로 할당합니다.

OCILobRead2: 동적 버퍼로 실제 CLOB 데이터를 읽어옵니다.

free & OCIDescriptorFree: 메모리 및 Locator 자원을 해제합니다.
