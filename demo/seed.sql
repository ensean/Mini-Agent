-- 直播业务演示库（合成数据，结构参考 BIGO 场景，数值随机）
CREATE DATABASE IF NOT EXISTS live COMMENT '直播业务演示库（合成数据）';

CREATE TABLE IF NOT EXISTS live.dim_user
(
    uid UInt64 COMMENT '用户 ID',
    country LowCardinality(String) COMMENT '注册国家，ISO 两位代码，如 JP/ID/PH/US',
    register_date Date COMMENT '注册日期',
    channel LowCardinality(String) COMMENT '获客渠道：organic/ads/referral',
    is_anchor UInt8 COMMENT '是否主播 1=是 0=否'
) ENGINE = MergeTree ORDER BY uid COMMENT '用户维表';

CREATE TABLE IF NOT EXISTS live.dim_gift
(
    gift_id UInt16 COMMENT '礼物 ID',
    gift_name String COMMENT '礼物名称',
    diamonds UInt32 COMMENT '单价，单位钻石'
) ENGINE = MergeTree ORDER BY gift_id COMMENT '礼物维表';

CREATE TABLE IF NOT EXISTS live.fact_gift_send
(
    event_time DateTime('Asia/Shanghai') COMMENT '送礼时间（北京时间）',
    sender_uid UInt64 COMMENT '送礼用户 ID，关联 dim_user.uid',
    anchor_uid UInt64 COMMENT '收礼主播 ID，关联 dim_user.uid',
    gift_id UInt16 COMMENT '礼物 ID，关联 dim_gift.gift_id',
    gift_cnt UInt16 COMMENT '本次送出数量',
    revenue_usd Decimal(12, 4) COMMENT '本次流水，美元（diamonds*gift_cnt*0.01）'
) ENGINE = MergeTree PARTITION BY toYYYYMM(event_time) ORDER BY (event_time, anchor_uid) COMMENT '送礼明细事实表';

TRUNCATE TABLE live.dim_user;
TRUNCATE TABLE live.dim_gift;
TRUNCATE TABLE live.fact_gift_send;

INSERT INTO live.dim_gift VALUES (1,'玫瑰',1),(2,'爱心',10),(3,'跑车',500),(4,'火箭',1000),(5,'城堡',5000),(6,'游艇',10000);

INSERT INTO live.dim_user
SELECT number + 1,
       ['JP','ID','PH','US','VN','SA','EG','BR'][1 + (cityHash64(number, 'country') % 8)],
       toDate('2025-01-01') + (cityHash64(number, 'regdate') % 640),
       ['organic','ads','referral'][1 + (cityHash64(number, 'channel') % 3)],
       if(number < 2000, 1, 0)
FROM numbers(50000);

INSERT INTO live.fact_gift_send
WITH 1 + (cityHash64(number, 'giftroll') % 100) AS r,
     multiIf(r <= 55, 1, r <= 85, 2, r <= 94, 3, r <= 98, 4, r <= 99, 5, 6) AS gid,
     1 + (cityHash64(number, 'cnt') % 5) AS cnt
SELECT toDateTime('2026-08-01 00:00:00', 'Asia/Shanghai') + (cityHash64(number, 'time') % (75 * 86400)),
       2001 + (cityHash64(number, 'sender') % 48000),
       1 + (cityHash64(number, 'anchor') % 2000),
       gid,
       cnt,
       toDecimal64([1,10,500,1000,5000,10000][gid] * cnt * 0.01, 4)
FROM numbers(600000);
