import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Trend, Counter } from 'k6/metrics';

// 09:00 정각 스파이크를 연다. 도착률 모델(open model)이라 응답 지연과 무관하게 초당 400건을 쏜다.
// 풀 용량(모형상 약 200건/초)의 2배라, 버그 경로는 커넥션 획득이 밀려 무너진다.
// 닫힌 모델(고정 VU)을 쓰면 빠른 503이 즉시 재시도를 유발해 accept 큐 고갈이라는 다른 병목을 재현하게 된다.
//
// VU 수 산정. VU 하나는 응답을 받을 때까지 묶여 있으므로, 어느 순간에도 처리 중인 요청 수만큼
// VU가 있어야 목표 도착률을 그대로 발사할 수 있다(모자라면 dropped_iterations로 빠진다).
//
// 처음에는 "앱이 동시에 붙들 수 있는 요청 = max-threads 200 + accept-count 1000 = 1,200"으로 보고
// 2,600을 잡았는데, 실측에서 2,075회가 발사되지 못했다. accept-count는 커널 listen 백로그일 뿐이고
// 실제로 소켓을 붙들고 있는 것은 Tomcat의 max-connections(기본 8192)라, 앱은 그보다 훨씬 많이 받는다.
// 계측에서 열린 소켓이 4,995개, 스레드를 기다리는 요청이 4,335건까지 올라갔다.
//
// 그래서 산정 근거를 바꿨다. 이 실험은 도착 400건/초에 처리 약 200건/초이므로 과부하 25초 동안
// 밀린 요청이 초당 약 200건씩 쌓여 최대 약 4,000건이 된다. 총 발사량은 400 x 25 + 램프 구간 = 10,000회다.
// 실측 최대 동시 VU는 4,531~4,573이었고, 5,000으로 잡으니 두 경로 모두 dropped_iterations 0이 됐다.
// 1차 측정은 preAllocatedVUs 200 / maxVUs 900이어서 버그 경로에서 3,401회가 발사되지 못했다.
const TARGET = __ENV.TARGET || 'http://app:8080/quote/buggy';
const RATE = Number(__ENV.RATE || 400);
const VUS = Number(__ENV.VUS || 5000);
// 미리 잡아 두는 VU 수. 기본은 maxVUs와 같게 두어 부하 중 VU를 새로 만들지 않는다.
// 1차 측정처럼 이 값을 작게 두면 부하 중에 VU가 새로 초기화된다.
const PREVUS = Number(__ENV.PREVUS || VUS);
const RAMP = __ENV.RAMP || '5s';
const HOLD = __ENV.HOLD || '20s';
const DOWN = __ENV.DOWN || '5s';

export const options = {
  scenarios: {
    market_open: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: PREVUS,
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
