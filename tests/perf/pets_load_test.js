import http from 'k6/http';
import { check, sleep } from 'k6';

const profile = (__ENV.PERF_PROFILE || 'cache').toLowerCase();
const targetVUs = Number(__ENV.PERF_VUS || 200);
const rampUp = __ENV.PERF_RAMP_UP || '30s';
const steady = __ENV.PERF_STEADY || '2m';
const rampDown = __ENV.PERF_RAMP_DOWN || '30s';
const thinkTime = Number(__ENV.PERF_SLEEP_SECONDS || 0.5);

const thresholdProfiles = {
  nocache: {
    http_req_duration: ['p(95)<900', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
  },
  cache: {
    http_req_duration: ['p(95)<600', 'p(99)<800'],
    http_req_failed: ['rate<0.01'],
  },
  chaos: {
    http_req_duration: ['p(95)<800', 'p(99)<60000'],
    http_req_failed: ['rate<0.05'],
  },
};

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: targetVUs },
        { duration: steady, target: targetVUs },
        { duration: rampDown, target: 0 },
      ],
    },
  },
  thresholds: thresholdProfiles[profile] || thresholdProfiles.cache,
};

export default function () {
  const baseUrl = __ENV.GATEWAY_BASE_URL || 'https://localhost';
  const url = `${baseUrl}/api/pets?page=1&page_size=20`;
  const res = http.get(url, { tags: { name: 'list_pets' } });
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(thinkTime);
}
