#!/bin/bash

valgrind \
    --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=all \
    --track-origins=yes \
    --num-callers=30 \
    --max-threads=1024 --workaround-gcc296-bugs=yes \
    dbd_maria -q ./maria_test.sql -r -S

#--leak-check=full        누수 위치 출력
#--show-leak-kinds=all    모든 누수 표시
#--track-origins=yes      초기화 안된 메모리 원인 추적
#--num-callers=30         Stack 30단계까지 출력
