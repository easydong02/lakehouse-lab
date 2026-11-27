"""Lab 8: Kafka 토픽 events → Iceberg 테이블 lake.events 스트리밍 적재.

오프셋은 Kafka 컨슈머 그룹이 아니라 체크포인트 디렉터리(CHECKPOINT_DIR)에 저장된다.
체크포인트를 잃으면 startingOffsets 부터 다시 읽는다.
"""
import os

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql import types as T

BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "lake-kafka-bootstrap.kafka.svc:9092")
TOPIC = os.environ.get("KAFKA_TOPIC", "events")
TABLE = os.environ.get("TARGET_TABLE", "lake.events")
CHECKPOINT = os.environ.get("CHECKPOINT_DIR", "/checkpoint/events")
TRIGGER = os.environ.get("TRIGGER_INTERVAL", "30 seconds")
MAX_OFFSETS = os.environ.get("MAX_OFFSETS_PER_TRIGGER", "5000")

EVENT_SCHEMA = T.StructType([
    T.StructField("event_id", T.StringType()),
    T.StructField("user_id", T.StringType()),
    T.StructField("event_type", T.StringType()),
    T.StructField("amount", T.IntegerType()),
    T.StructField("ts", T.StringType()),
])


def main():
    builder = SparkSession.builder.appName("events-stream")
    credential = os.environ.get("POLARIS_CREDENTIAL")
    if credential:
        builder = builder.config("spark.sql.catalog.polaris.credential", credential)
    spark = builder.getOrCreate()

    spark.sql("CREATE NAMESPACE IF NOT EXISTS lake")
    spark.sql(f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
          event_id        STRING,
          user_id         STRING,
          event_type      STRING,
          amount          INT,
          event_ts        TIMESTAMP,
          kafka_partition INT,
          kafka_offset    BIGINT,
          ingested_at     TIMESTAMP)
        USING iceberg
        PARTITIONED BY (hours(event_ts))
    """)

    raw = (
        spark.readStream.format("kafka")
        .option("kafka.bootstrap.servers", BOOTSTRAP)
        .option("subscribe", TOPIC)
        .option("startingOffsets", "earliest")
        .option("maxOffsetsPerTrigger", MAX_OFFSETS)
        .option("failOnDataLoss", "false")
        .load()
    )

    events = (
        raw.select(
            F.from_json(F.col("value").cast("string"), EVENT_SCHEMA).alias("e"),
            F.col("partition").alias("kafka_partition"),
            F.col("offset").alias("kafka_offset"),
        )
        .select(
            "e.event_id",
            "e.user_id",
            "e.event_type",
            "e.amount",
            # ANSI 모드(Spark 4 기본)에서도 잘못된 값이 잡을 죽이지 않도록 try_ 함수 사용
            F.try_to_timestamp(F.col("e.ts")).alias("event_ts"),
            "kafka_partition",
            "kafka_offset",
            F.current_timestamp().alias("ingested_at"),
        )
        # JSON이 깨진 메시지는 버린다 (실무라면 별도 테이블로 격리)
        .where(F.col("event_id").isNotNull())
    )

    query = (
        events.writeStream.format("iceberg")
        .outputMode("append")
        # 메트릭 이름과 Spark UI에 쓰이는 쿼리 이름
        .queryName("events_ingest")
        .trigger(processingTime=TRIGGER)
        .option("checkpointLocation", CHECKPOINT)
        # 파티션 테이블에 정렬 없이 쓰기
        .option("fanout-enabled", "true")
        .toTable(TABLE)
    )
    print(f"streaming {TOPIC} -> {TABLE}, trigger={TRIGGER}, checkpoint={CHECKPOINT}", flush=True)
    query.awaitTermination()


if __name__ == "__main__":
    main()
