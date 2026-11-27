"""SparkApplication에서 SQL 문을 차례로 실행하고 결과를 로그에 찍는다.

arguments 로 받은 문자열을 ';' 기준으로 나눠 실행한다.
'@/경로/파일.sql' 형태로 주면 파일을 읽는다.
${NOW}, ${NOW-6h}, ${NOW-2d} 는 실행 시각(UTC) 기준 'YYYY-MM-DD HH:MM:SS' 문자열로 바뀐다.
Polaris 자격 증명은 환경 변수 POLARIS_CREDENTIAL(clientId:clientSecret)에서 읽는다.
"""
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

from pyspark.sql import SparkSession

NOW_PATTERN = re.compile(r"\$\{NOW(?:-(\d+)([hd]))?\}")


def load(args):
    parts = []
    for a in args:
        if a.startswith("@"):
            with open(a[1:], encoding="utf-8") as f:
                parts.append(f.read())
        else:
            parts.append(a)
    return "\n".join(parts)


def expand_time(text):
    now = datetime.now(timezone.utc)

    def repl(m):
        t = now
        if m.group(1):
            n = int(m.group(1))
            t = now - (timedelta(hours=n) if m.group(2) == "h" else timedelta(days=n))
        return t.strftime("%Y-%m-%d %H:%M:%S")

    return NOW_PATTERN.sub(repl, text)


def split_statements(text):
    stmts, buf = [], []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        buf.append(line)
        if stripped.endswith(";"):
            stmts.append("\n".join(buf).strip().rstrip(";").strip())
            buf = []
    tail = "\n".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def main():
    statements = split_statements(expand_time(load(sys.argv[1:])))
    if not statements:
        print("실행할 SQL이 없습니다. arguments를 확인하세요.")
        sys.exit(2)

    # TIMESTAMP 리터럴을 UTC로 해석하도록 세션 시간대를 고정한다
    builder = (SparkSession.builder.appName(os.environ.get("APP_NAME", "run-sql"))
               .config("spark.sql.session.timeZone", "UTC"))
    credential = os.environ.get("POLARIS_CREDENTIAL")
    if credential:
        builder = builder.config("spark.sql.catalog.polaris.credential", credential)
    spark = builder.getOrCreate()

    show_rows = int(os.environ.get("SHOW_ROWS", "50"))
    for i, stmt in enumerate(statements, 1):
        print(f"\n=== [{i}/{len(statements)}] {stmt}", flush=True)
        started = time.time()
        df = spark.sql(stmt)
        if df.columns:
            df.show(show_rows, truncate=False)
        print(f"--- {time.time() - started:.1f}s", flush=True)

    spark.stop()


if __name__ == "__main__":
    main()
