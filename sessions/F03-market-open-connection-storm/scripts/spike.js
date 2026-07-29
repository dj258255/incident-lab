import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Trend, Counter } from 'k6/metrics';

// 09:00 정각 스파이크를 연다. 도착률 모델(open model)이라 응답 지연과 무관하게 초당 400건을 쏜다.
// 풀 용량(모형상 약 200건/초)의 2배라, 버그 경로는 커넥션 획득이 밀려 무너진다.
// 닫힌 모델(고정 VU)을 쓰면 빠른 503이 즉시 재시도를 유발해 accept 큐 고갈이라는 다른 병목을 재현하게 된다.
//
// VU 수 산정(리틀의 법칙). 필요한 VU = 도착률 x 요청 하나가 시스템에 머무는 시간이다.
// 앱이 동시에 붙들 수 있는 요청은 Tomcat 스레드(max-threads)와 accept 큐(accept-count)의 합인
// 200 + 1000 = 1,200건이고, 모형상 처리율이 초당 약 200건이므로 머무는 시간의 상한은 1200/200 = 6초다.
// 따라서 400 x 6 = 2,400 VU면 열린 모델이 유지된다. 여유를 두어 기본값을 2,600으로 잡았다.
// 1차 측정은 preAllocatedVUs 200 / maxVUs 900이어서 버그 경로에서 3,401회가 발사되지 못했다.
const TARGET = __ENV.TARGET || 'http://app:8080/quote/buggy';
const RATE = Number(__ENV.RATE || 400);
const VUS = Number(__ENV.VUS || 2600);
const RAMP = __ENV.RAMP || '5s';
const HOLD = __ENV.HOLD || '20s';
const DOWN = __ENV.DOWN || '5s';

export const options = {
  scenarios: {
    market_open: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: VUS,
      maxVUs: VUS,
      stages: [
        { duration: RAMP, target: RATE },
        { duration: HOLD, target: RATE },
        { duration: DOWN, target: 0 },
      ],
    },
  },
};

// 상태코드별 지연. 503이 실제로 몇 ms에 돌아왔는지는 이렇게 갈라야 나온다.
// http_req_duration 하나만 보면 200과 503과 0ms 실패가 한 분포에 섞인다.
const dur200 = new Trend('dur_200_ok', true);
const dur503 = new Trend('dur_503_shed', true);
const dur500 = new Trend('dur_500_error', true);
const durNoResp = new Trend('dur_noresp', true);

const cnt200 = new Counter('cnt_200');
const cnt503 = new Counter('cnt_503');
const cnt500 = new Counter('cnt_500');
const cntNoResp = new Counter('cnt_noresp');
const cntOther = new Counter('cnt_other');

export default function () {
  const res = http.get(TARGET);
  const d = res.timings.duration;
  if (res.status === 200) {
    dur200.add(d);
    cnt200.add(1);
  } else if (res.status === 503) {
    dur503.add(d);
    cnt503.add(1);
  } else if (res.status === 500) {
    dur500.add(d);
    cnt500.add(1);
  } else if (res.status === 0) {
    // 응답을 아예 받지 못한 요청. connection refused 등 error_code가 붙는다.
    // 언제 몇 번 코드로 실패했는지를 한 줄씩 남긴다. 램프업 구간에 몰렸는지는
    // 이 t 값을 세어 보면 갈린다(1차 측정에서 1,324건이 나왔던 자리다).
    durNoResp.add(d);
    cntNoResp.add(1);
    console.log(
      `NORESP t=${(exec.instance.currentTestRunDuration / 1000).toFixed(1)} code=${res.error_code} ${res.error}`);
  } else {
    cntOther.add(1);
  }
  check(res, {
    '200 정상 응답': (r) => r.status === 200,
    '503 부하 차단(의도된 흘려보냄)': (r) => r.status === 503,
    '500 서버오류(커넥션 타임아웃)': (r) => r.status === 500,
    '응답 못 받음(status 0)': (r) => r.status === 0,
  });
}
