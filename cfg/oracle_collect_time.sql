## 전체 파티션 : itstone.maintain_all_partitions()
## 단일 파티션 : SELECT itstone.maintain_range_partitions('itstone.s_active_session', 7, 3, 'day');
[partition_manage, Y, 01:10:00]
CALL itstone.maintain_all_partitions();
