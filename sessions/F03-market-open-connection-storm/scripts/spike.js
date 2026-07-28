import http from 'k6/http';
import { check } from 'k6';

// 09:00 정각 스파이크를 연다. 도착률 모델(open model)이라 응답 지연과 무관하게 초당 400건이 쏟아진다.
// 풀 용량(약 200건/초)의 2배라, 버그 경로는 커넥션 획득이 밀려 무너진다.
// 닫힌 모델(고정 VU)을 쓰면 빠른 503이 즉시 재시도를 유발해 accept 큐 고갈이라는 다른 병목을 재현하게 된다.
export const options = {
  scenarios: {
    market_open: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 900,
      stages: [
        { duration: '5s', target: 400 },
        { duration: '20s', target: 400 },
        { duration: '5s', target: 0 },
      ],
    },
  },
};

const TARGET = __ENV.TARGET || 'http://app:8080/quote/buggy';

export default function () {
  const res = http.get(TARGET);
  check(res, {
    '200 정상 응답': (r) => r.status === 200,
    '503 부하 차단(의도된 흘려보냄)': (r) => r.status === 503,
    '500 서버오류(커넥션 타임아웃)': (r) => r.status === 500,
  });
}
