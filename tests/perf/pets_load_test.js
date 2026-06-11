import http from 'k6/http';
import { check, sleep } from 'k6';

const profile = (__ENV.PERF_PROFILE || 'cache').toLowerCase();
const targetVUs = Number(__ENV.PERF_VUS || (profile === 'p1' ? 300 : 200));
const p1Iterations = Number(__ENV.PERF_ITERATIONS || 1200);
const p1MaxDuration = __ENV.PERF_MAX_DURATION || '30s';
const p1Duration = __ENV.PERF_DURATION || p1MaxDuration;
const rampUp = __ENV.PERF_RAMP_UP || '30s';
const steady = __ENV.PERF_STEADY || '2m';
const rampDown = __ENV.PERF_RAMP_DOWN || '30s';
const thinkTime = Number(__ENV.PERF_SLEEP_SECONDS || (profile === 'p1' ? 0 : 0.5));
const baseUrl = (__ENV.BASE_URL || 'https://localhost').replace(/\/$/, '');
const petsPath = __ENV.PETS_PATH || '/api/pets?page=1&page_size=20';

function durationToSeconds(duration) {
  const match = String(duration).trim().match(/^(\d+(?:\.\d+)?)(ms|s|m|h)$/);
  if (!match) {
    return 30;
  }

  const value = Number(match[1]);
  const unit = match[2];
  if (unit === 'ms') return value / 1000;
  if (unit === 'm') return value * 60;
  if (unit === 'h') return value * 3600;
  return value;
}

const p1Rate = Number(__ENV.PERF_RATE || Math.ceil(p1Iterations / durationToSeconds(p1Duration)));

const thresholdProfiles = {
  p1: {
    http_reqs: [`count>=${p1Iterations}`],
    http_req_duration: ['p(95)<2000'],
    http_req_failed: ['rate==0'],
    checks: ['rate==1'],
  },
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
  scenarios: profile === 'p1'
    ? {
        p1_constant_arrival: {
          executor: 'constant-arrival-rate',
          rate: p1Rate,
          timeUnit: '1s',
          duration: p1Duration,
          preAllocatedVUs: targetVUs,
          maxVUs: targetVUs,
        },
      }
    : {
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
  const res = http.get(`${baseUrl}${petsPath}`, {
    tags: { name: 'list_pets', profile },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  if (thinkTime > 0) {
    sleep(thinkTime);
  }
}
