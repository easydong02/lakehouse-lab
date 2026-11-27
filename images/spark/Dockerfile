# syntax=docker/dockerfile:1
# Spark 4.1.4 + Iceberg 1.12.0 + Kafka 커넥터를 미리 넣은 실습용 이미지
# --packages로 실행 중에 jar를 받으면 폐쇄망에서 깨지고, Ivy 캐시 권한 문제도 생긴다.
ARG SPARK_IMAGE=apache/spark:4.1.4
FROM ${SPARK_IMAGE}

ARG ICEBERG_VERSION=1.12.0
ARG SPARK_VERSION=4.1.4
# Spark 4.1.4 pom.xml 기준 버전
ARG KAFKA_CLIENTS_VERSION=3.9.1
ARG COMMONS_POOL2_VERSION=2.12.1
ARG MAVEN=https://repo1.maven.org/maven2

USER root
# Iceberg 런타임(Spark 4.1용) + S3FileIO가 쓰는 AWS SDK 번들
ADD --chmod=644 ${MAVEN}/org/apache/iceberg/iceberg-spark-runtime-4.1_2.13/${ICEBERG_VERSION}/iceberg-spark-runtime-4.1_2.13-${ICEBERG_VERSION}.jar /opt/spark/jars/
ADD --chmod=644 ${MAVEN}/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar /opt/spark/jars/
# Structured Streaming Kafka 소스와 의존성
ADD --chmod=644 ${MAVEN}/org/apache/spark/spark-sql-kafka-0-10_2.13/${SPARK_VERSION}/spark-sql-kafka-0-10_2.13-${SPARK_VERSION}.jar /opt/spark/jars/
ADD --chmod=644 ${MAVEN}/org/apache/spark/spark-token-provider-kafka-0-10_2.13/${SPARK_VERSION}/spark-token-provider-kafka-0-10_2.13-${SPARK_VERSION}.jar /opt/spark/jars/
ADD --chmod=644 ${MAVEN}/org/apache/kafka/kafka-clients/${KAFKA_CLIENTS_VERSION}/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar /opt/spark/jars/
ADD --chmod=644 ${MAVEN}/org/apache/commons/commons-pool2/${COMMONS_POOL2_VERSION}/commons-pool2-${COMMONS_POOL2_VERSION}.jar /opt/spark/jars/

# 실습 스크립트
COPY --chmod=755 bin/ /opt/lab/bin/
COPY --chmod=u=rwX,go=rX conf/ /opt/lab/conf/
COPY --chmod=u=rwX,go=rX jobs/ /opt/lab/jobs/
# COPY --chmod=644 conf/ /opt/lab/conf/
# COPY --chmod=644 jobs/ /opt/lab/jobs/
ENV PATH="/opt/lab/bin:${PATH}"

USER spark
