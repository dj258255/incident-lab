// 라이브 후원 부하 스크립트
//
// 후원이 방송에 균등하게 뿌려지면 이 문제는 재현되지 않는다. 실제 라이브 플랫폼의 후원은
// 소수 방송에 극단적으로 쏠리고, 그 쏠림이 곧 핫 로우다. 그래서 방송 선택을 Zipf 분포로 뽑는다.
//
// 시나리오
//   zipf   : 방송 1,000개, Zipf(s=1.2). 평상시 피크를 가정한 기본 실험
//   hotspot: 전량을 방송 1개로. 인기 방송 하나에 후원이 몰리는 순간의 상한 측정
import http from "k6/http";
import { check } from "k6";
import { Trend, Counter } from "k6/metrics";

// 인스턴스를 두 대 이상 띄워 비교할 때 쓴다. JVM 안에서만 도는 자물쇠가
// 인스턴스가 늘면 왜 무력해지는지 보려면 부하가 양쪽에 고루 가야 한다.
const TARGETS = (__ENV.BASE_URLS || __ENV.BASE_URL || "http://127.0.0.1:8080").split(",");
const LIVES = Number(__ENV.LIVES || 1000);
const ZIPF_S = Number(__ENV.ZIPF_S || 1.2);
const SCENARIO = __ENV.SCENARIO || "zipf";
const VUS = Number(__ENV.VUS || 100);
const DURATION = __ENV.DURATION || "60s";

// Zipf 누적분포를 init 컨텍스트에서 한 번만 만든다. VU마다 만들면 메모리와 시작 시간이 낭비된다.
const cdf = (() => {
  const w = new Float64Array(LIVES);
  let sum = 0;
  for (let i = 0; i < LIVES; i++) {
    w[i] = 1 / Math.pow(i + 1, ZIPF_S);
    sum += w[i];
  }
  let acc = 0;
  for (let i = 0; i < LIVES; i++) {
    acc += w[i] / sum;
    w[i] = acc;
  }
  return w;
})();

function pickLive() {
  if (SCENARIO === "hotspot") return 1;
  const r = Math.random();
  let lo = 0, hi = LIVES - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (cdf[mid] < r) lo = mid + 1; else hi = mid;
  }
  return lo + 1;
}

const sponsorLatency = new Trend("sponsor_latency", true);
const failures = new Counter("sponsor_failures");

export const options = {
  scenarios: {
    sponsor: {
      executor: "constant-vus",
      vus: VUS,
      duration: DURATION,
      gracefulStop: "10s",
    },
  },
  thresholds: {
    // 임계를 걸어두되 abortOnFail은 쓰지 않는다. 실패하는 모습 자체가 관측 대상이다.
    "http_req_failed": ["rate<1"],
  },
  summaryTrendStats: ["avg", "min", "med", "p(95)", "p(99)", "max"],
};

export function setup() {
  // 상위 방송에 얼마나 쏠리는지 실제 수치로 남긴다. 분포를 말로만 적으면 검증이 안 된다.
  const top1 = cdf[0];
  const top10 = cdf[9];
  const top1pct = cdf[Math.floor(LIVES * 0.01) - 1];
  console.log(
    `[분포] 시나리오=${SCENARIO} 방송=${LIVES} s=${ZIPF_S} | ` +
    `1위 방송 ${(top1 * 100).toFixed(1)}% · 상위10 ${(top10 * 100).toFixed(1)}% · 상위1% ${(top1pct * 100).toFixed(1)}%`
  );
  return {};
}

export default function () {
  const liveId = pickLive();
  const payload = JSON.stringify({
    liveId: liveId,
    userId: Math.floor(Math.random() * 500000) + 1,
    // 후원 금액도 한 값으로 고정하지 않는다. 실제로는 소액이 대다수고 고액이 가끔 섞인다.
    amount: Math.random() < 0.95
      ? (Math.floor(Math.random() * 10) + 1) * 100
      : (Math.floor(Math.random() * 50) + 10) * 1000,
  });

  const base = TARGETS.length === 1 ? TARGETS[0] : TARGETS[Math.floor(Math.random() * TARGETS.length)];
  const res = http.post(`${base}/sponsor`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { name: "sponsor" },
  });

  sponsorLatency.add(res.timings.duration);
  const ok = check(res, { "status 200": (r) => r.status === 200 });
  if (!ok) failures.add(1);
}
