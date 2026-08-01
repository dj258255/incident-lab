// 킬스위치가 걸리기까지 몇 건이 통과하는가. 동시성을 바꿔 가며 잰다.
//
// 노리는 자리는 컨트롤러의 검사 후 행동 틈이다.
//
//   if (killswitch.tripped()) return 503;   // (A) 읽기
//   ...
//   killswitch.recordDeviation();           // (B) 증가 + 문턱 판정
//
// 순차 호출이면 문턱 T 건째에 (B) 가 켜지고 그다음 요청이 (A) 에서 막힌다.
// 동시 요청이면 여러 요청이 (A) 를 이미 지나간 뒤에 (B) 가 켜지므로, 그 사이의 요청이
// 전부 통과한다. 통과한 건수가 동시성에 비례해 늘어나는지가 질문이다.
//
// 이 세션에는 시간축이 없다는 것도 함께 잡는다. 상태코드를 시각과 함께 남긴다.
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';

// k6 는 자기 컨테이너 안에서 돈다. localhost 로 쏘면 k6 자신을 가리켜 요청이 아예 안
// 나간다. 실제로 15초에 18만 회를 돌면서 data_received 가 0 B 였다. compose 네트워크의
// 서비스 이름으로 쏜다.
const TARGET = __ENV.TARGET || 'http://app:8080';
const VUS = Number(__ENV.VUS || 1);
const DURATION = __ENV.DURATION || '10s';
const PATH = __ENV.EP || '/orders/leaky-independent';
const NAN_PCT = Number(__ENV.NAN_PCT || 0.1);

const cnt201 = new Counter('cnt_201');       // 접수
const cnt422 = new Counter('cnt_422');       // 가드나 이탈 판정으로 거부
const cnt503 = new Counter('cnt_503');       // 킬스위치가 막음
const cntOther = new Counter('cnt_other');
const passedBeforeTrip = new Counter('passed_before_trip');  // 첫 503 이전에 통과한 요청
const dur = new Trend('dur_ms', true);

export const options = {
  scenarios: {
    load: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
      gracefulStop: '5s',
    },
  },
  // 503 이 정상 동작이므로 실패로 세지 않는다.
  thresholds: {},
};

// 첫 503 을 본 시점. VU 마다 지역 변수라 합산은 아래 Counter 로 한다.
let sawTrip = false;

export default function () {
  // NAN_PCT 비율로 days=0 인 주문을 섞는다. days 가 0 이면 numerator/days 가
  // Infinity 또는 NaN 이 되고, numerator 도 0 이면 NaN 이다.
  //
  // 정상 주문은 반드시 접수(201)되는 값이어야 한다. 처음에 numerator=1, days=30 을
  // 썼더니 px = base * (1 + 1/30) 이 상한을 넘어 네 조건 다 접수가 0건이었다.
  // numerator 를 0 으로 두면 px = base 그대로라 확실히 대역 안이다.
  const isNan = Math.random() < NAN_PCT;
  const body = isNan
    ? { base: 100000, numerator: 0, days: 0 }      // 0/0 = NaN
    : { base: 100000, numerator: 0, days: 30 };    // px = base, 확실히 접수

  const res = http.post(`${TARGET}${PATH}`, JSON.stringify(body), {
    headers: { 'Content-Type': 'application/json' },
  });
  dur.add(res.timings.duration);

  if (res.status === 201) cnt201.add(1);
  else if (res.status === 422) cnt422.add(1);
  else if (res.status === 503) cnt503.add(1);
  else cntOther.add(1);

  // 킬스위치가 켜지기 전에 통과한(503 이 아닌) 요청을 센다. 이 값이 동시성에 따라
  // 얼마나 부푸는지가 이 실험의 요지다.
  if (res.status !== 503 && !sawTrip) passedBeforeTrip.add(1);
  if (res.status === 503) sawTrip = true;
}
