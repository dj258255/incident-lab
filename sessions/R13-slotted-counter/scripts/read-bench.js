// 읽기 비용 측정용 부하 스크립트
//
// 슬롯 카운터가 쓰기에서 얻는 이득에는 대가가 있다. 총액을 알려면 슬롯 N행을 훑어 합쳐야 한다.
// 그 비용을 재지 않으면 슬롯이 공짜처럼 보인다.
//
// 기본은 방송 1번만 읽는다. 가장 인기 있는 방송이라 슬롯이 전부 채워져 있어,
// "슬롯 N개를 훑는 비용"을 다른 요인 없이 비교할 수 있다.
import http from "k6/http";
import { check } from "k6";

const SCENARIO = __ENV.SCENARIO || "hotspot";
const LIVES = Number(__ENV.LIVES || 1000);
const VUS = Number(__ENV.VUS || 50);
const DURATION = __ENV.DURATION || "30s";
const BASE = __ENV.BASE_URL || "http://127.0.0.1:8080";

export const options = {
  scenarios: {
    read: { executor: "constant-vus", vus: VUS, duration: DURATION, gracefulStop: "10s" },
  },
  thresholds: { http_req_failed: ["rate<1"] },
  summaryTrendStats: ["avg", "min", "med", "p(95)", "p(99)", "max"],
};

export default function () {
  const liveId = SCENARIO === "hotspot" ? 1 : Math.floor(Math.random() * LIVES) + 1;
  const res = http.get(`${BASE}/total/${liveId}`, { tags: { name: "total" } });
  check(res, { "status 200": (r) => r.status === 200 });
}
