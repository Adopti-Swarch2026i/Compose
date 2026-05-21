import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 200 },
        { duration: '2m', target: 200 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<300', 'p(99)<800'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const url = 'https://localhost/api/pets?page=1&page_size=20';
  const res = http.get(url, { tags: { name: 'list_pets' } });
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(0.5);
}
