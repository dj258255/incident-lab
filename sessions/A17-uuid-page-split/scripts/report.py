#!/usr/bin/env python3
"""조건별 결과를 표로 내고 results/render.json을 만든다.

이 스크립트가 내는 '공간 효율'은 계산값이다. 정의는 이렇다.

  공간 효율 = 행 내용 바이트 / (DATA_LENGTH / 행 수) x 100
  행 내용 = PK + user_id(4) + amount(4) + pad(120)
  레코드 부가 = 5바이트 헤더 + DB_TRX_ID(6) + DB_ROLL_PTR(7) = 18바이트

주의: 이것은 페이지 충전율이 아니다. 분모가 DATA_LENGTH를 행 수로 나눈 값이라,
클러스터드 인덱스 전체가 들어간다. 리프 페이지의 빈자리뿐 아니라 페이지 헤더와 트레일러,
비리프 페이지, 익스텐트에 할당만 되고 아직 쓰지 않은 페이지가 모두 분모에 섞인다.
PlanetScale 등이 말하는 '페이지 충전율 94%'는 페이지 안에서 채워진 비율이므로 같은 축이
아니고, 이 값과 직접 비교하면 안 된다. 조건 간 상대 비교까지만 유효하다.

순차 PK가 100%가 아닌 것도 낭비가 아니다. InnoDB는 클러스터드 인덱스 페이지의 1/16을
나중의 행 증가분을 위해 비워 두므로 페이지 충전율 자체의 상한이 약 93.75%이고, 여기에
위의 분모 오염이 얹혀 91.9%가 된다.

표준 라이브러리만 쓴다.
"""
import glob
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(HERE, "results")

PK_BYTES = {"seq": 8, "uuid7_bin": 16, "uuid7_counter": 16,
            "uuid4_bin": 16, "uuid4_char": 36}
KO = {"seq": "BIGINT 순차", "uuid7_counter": "UUIDv7 (밀리초 카운터)",
      "uuid7_bin": "UUIDv7 (카운터 없음)", "uuid4_bin": "UUIDv4 BINARY(16)",
      "uuid4_char": "UUIDv4 CHAR(36)"}
ORDER = ["seq", "uuid7_counter", "uuid7_bin", "uuid4_bin", "uuid4_char"]
OVERHEAD = 18


def load():
    out = {}
    for p in glob.glob(os.path.join(RES, "bench-*.json")):
        with open(p) as f:
            d = json.load(f)
        out[d["arm"]] = d
    return out


rows = load()
arms = [a for a in ORDER if a in rows]
if not arms:
    raise SystemExit("results/bench-*.json 이 없습니다")

n = rows[arms[0]]["rows"]
print("=" * 84)
print(f"A17 PK 종류별 적재 결과   (각 {n:,}행, 버퍼 풀 {rows[arms[0]]['buffer_pool_mb']}MB, "
      f"페이로드 {rows[arms[0]]['pad_bytes']}바이트 고정)")
print("=" * 84)
print(f"\n{'조건':>22}{'테이블':>10}{'행당바이트':>11}{'공간효율':>9}"
      f"{'총 시간':>10}{'평균':>11}{'마지막구간':>11}")
print("-" * 84)

images, fill_bars, size_bars, rate_bars, read_bars = [], [], [], [], []
for a in arms:
    d = rows[a]
    ideal = PK_BYTES[a] + 4 + 4 + d["pad_bytes"] + OVERHEAD
    fill = ideal / d["bytes_per_row"] * 100
    last = d["chunks"][-1]["rate_per_s"] if d["chunks"] else 0
    print(f"{KO[a]:>22}{d['data_length_mb']:>9.1f}M{d['bytes_per_row']:>11.1f}"
          f"{fill:>8.1f}%{d['total_s']:>9.1f}초{d['rows_per_s']:>9,.0f}/s"
          f"{last:>9,.0f}/s")
    good = a in ("seq", "uuid7_counter")
    fill_bars.append({"label": KO[a].replace(" ", "\n") if False else KO[a],
                      "value": round(fill, 1), "color": "green" if fill > 85 else "red"})
    size_bars.append({"label": KO[a], "value": round(d["data_length_mb"]),
                      "color": "green" if good else "red"})
    rate_bars.append({"label": KO[a], "value": round(last),
                      "color": "green" if last > 12000 else "red"})
    read_bars.append({"label": KO[a], "value": d["disk_reads"],
                      "color": "green" if d["disk_reads"] < 1000 else "red"})

print(f"\n{'조건':>22}{'적재 중 디스크 읽기':>20}{'읽어들인 양':>13}{'쓴 페이지':>12}")
print("-" * 84)
for a in arms:
    d = rows[a]
    print(f"{KO[a]:>22}{d['disk_reads']:>18,}쪽{d['data_read_mb']:>11,.1f}MB"
          f"{d['pages_written']:>11,}")

print("\n두 가지 대가가 따로 논다.")
print("  공간: 페이지가 반만 차면 테이블이 커진다. 공간 효율 열을 볼 것.")
print("  시간: 삽입 지점이 인덱스 전체로 흩어지면 페이지를 디스크에서 읽어 와 고쳐야 한다.")
print("        디스크 읽기 열과 마지막 구간 속도를 볼 것.")
print("\n공간 효율은 페이지 충전율이 아니다. 분모가 DATA_LENGTH÷행 수라 비리프 페이지와")
print("미사용 할당분이 섞인다. 외부 문헌의 페이지 충전율 수치와 직접 비교하지 말 것.")
print("uuid7_bin이 uuid4_bin보다 낮은 것은 오차가 아니다. 시간 정렬 PK는 삽입 지점이")
print("앞으로만 가서 반만 찬 페이지로 되돌아가지 못하고, 랜덤 PK는 나중 값이 다시 채운다.")

short = {"seq": "BIGINT", "uuid7_counter": "v7+카운터", "uuid7_bin": "v7 카운터없음",
         "uuid4_bin": "v4 BINARY", "uuid4_char": "v4 CHAR(36)"}
for bars in (fill_bars, size_bars, rate_bars, read_bars):
    for b, a in zip(bars, arms):
        b["label"] = short[a]

images += [
    {"type": "bar", "out": "01-fill.png", "title": "PK 조건별 공간 효율 (페이지 충전율 아님)",
     "bars": fill_bars,
     "note": f"(행 내용 바이트 / 실제 행당 바이트) x 100. 각 조건 {n:,}행 적재 후"},
    {"type": "bar", "out": "02-size.png", "title": "같은 120만 행을 담은 테이블 크기 (MB)",
     "bars": size_bars,
     "note": f"페이로드는 다섯 조건 모두 {rows[arms[0]]['pad_bytes']}바이트로 같다. "
             f"차이는 PK 폭과 공간 효율에서 온다"},
    {"type": "bar", "out": "03-rate.png", "title": "마지막 10만 행 구간의 초당 삽입",
     "bars": rate_bars,
     "note": "적재가 진행될수록 인덱스가 커진다. 끝 구간 속도가 그 부담을 가장 잘 보여준다"},
    {"type": "bar", "out": "04-reads.png", "title": "적재 중 버퍼 풀이 디스크에서 읽은 페이지",
     "bars": read_bars,
     "note": "INSERT인데도 읽는다. 고칠 페이지가 버퍼 풀에 없으면 먼저 읽어 와야 하기 때문이다"},
]

# 적재 속도 곡선은 막대로 표현할 수 없어 구간별 수치를 csv로 남긴다.
with open(os.path.join(RES, "rate-curve.csv"), "w") as f:
    f.write("arm,rows,elapsed_s,rate_per_s\n")
    for a in arms:
        for c in rows[a]["chunks"]:
            f.write(f"{a},{c['rows']},{c['elapsed_s']},{c['rate_per_s']}\n")

with open(os.path.join(RES, "render.json"), "w") as f:
    json.dump({"images": images}, f, ensure_ascii=False, indent=2)
print(f"\nrender.json 작성: 이미지 {len(images)}장, rate-curve.csv 작성")
