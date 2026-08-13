import { HttpResponse, http } from "msw";
import { makeAccessToken, TEST_TENANT_ID, TEST_USER_ID } from "./jwt";
import type { OrderStatus } from "../../src/types/order";

/**
 * Default happy-path handlers for every endpoint the package calls. Individual tests
 * override what they care about with `server.use(...)`.
 *
 * The response bodies below are the ACTUAL wire shapes confirmed in the backend source,
 * including the awkward ones — an error whose machine code hides in `message`, a
 * security-filter 401 with no message at all, and Spring's direct `PageImpl`
 * serialization. Mocking a tidier API than the real one would defeat the purpose.
 */

export const API_BASE_URL = "http://localhost:8083";
export const ORDERS_BASE_URL = "http://localhost:8082";

export const VALID_USERNAME = "test-user";
export const VALID_PASSWORD = "correct-horse";

export interface MockOrder {
  id: string;
  tenantId: string;
  orderNumber: string;
  totalAmount: number;
  status: OrderStatus;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
}

export function makeOrder(overrides: Partial<MockOrder> = {}): MockOrder {
  return {
    id: "1f0a1b2c-3d4e-5f60-7182-93a4b5c6d7e8",
    tenantId: TEST_TENANT_ID,
    orderNumber: "ORD-1001",
    totalAmount: 129.99,
    status: "PENDING",
    createdBy: TEST_USER_ID,
    // LocalDateTime: ISO-8601 with no offset, which is what Jackson emits for the
    // backend's `LocalDateTime` fields.
    createdAt: "2026-08-13T09:15:00",
    updatedAt: "2026-08-13T09:15:00",
    ...overrides,
  };
}

/**
 * Spring Data's DIRECT `PageImpl` serialization — page metadata sits at the TOP LEVEL
 * alongside `content`, not nested under a `page` key. Confirmed against
 * spring-data-commons 4.1.0: order-service supplies its own `JsonMapper` bean, so Boot's
 * `PageModule` (which would emit the nested `PagedModel` shape) is not applied.
 */
export function pageOf(content: MockOrder[], pageNumber = 0, size = 20) {
  return {
    content,
    pageable: {
      pageNumber,
      pageSize: size,
      sort: { sorted: true, unsorted: false, empty: false },
      offset: pageNumber * size,
      paged: true,
      unpaged: false,
    },
    last: true,
    totalElements: content.length,
    totalPages: 1,
    size,
    number: pageNumber,
    sort: { sorted: true, unsorted: false, empty: false },
    first: pageNumber === 0,
    numberOfElements: content.length,
    empty: content.length === 0,
  };
}

/** Wire shape A — `ErrorResponse`; note the code lives in `message`. */
export function errorShapeA(status: number, reason: string, message: string, path: string) {
  return HttpResponse.json(
    { status, error: reason, message, path, timestamp: "2026-08-13T09:15:00Z" },
    { status },
  );
}

/** Wire shape B — rate limiter; the code lives in `error`, plus a `Retry-After` header. */
export function errorShapeB(path: string, retryAfterSeconds: number) {
  return HttpResponse.json(
    {
      status: 429,
      error: "rate_limit_exceeded",
      message: "Too many requests, please slow down",
      path,
      timestamp: "2026-08-13T09:15:00Z",
    },
    { status: 429, headers: { "Retry-After": String(retryAfterSeconds) } },
  );
}

/** Wire shape C — Boot's default `/error` attributes: NO `message` field at all. */
export function errorShapeC(status: number, reason: string, path: string) {
  return HttpResponse.json(
    { timestamp: "2026-08-13T09:15:00Z", status, error: reason, path },
    { status },
  );
}

/** Wire shape D — cookieless refresh: a bare `{message}` and nothing else. */
export function errorShapeD() {
  return HttpResponse.json({ message: "invalid_refresh_token" }, { status: 401 });
}

export const handlers = [
  http.post(`${API_BASE_URL}/api/v1/auth/login`, async ({ request }) => {
    if (request.headers.get("X-Tenant-ID") === null) {
      return errorShapeA(400, "Bad Request", "Missing header: X-Tenant-ID", "/api/v1/auth/login");
    }
    const body = (await request.json()) as { username?: string; password?: string };
    if (body.username !== VALID_USERNAME || body.password !== VALID_PASSWORD) {
      return errorShapeA(401, "Unauthorized", "Invalid credentials", "/api/v1/auth/login");
    }
    return HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() });
  }),

  http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () =>
    HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() }),
  ),

  http.post(`${API_BASE_URL}/api/v1/auth/logout`, () => new HttpResponse(null, { status: 204 })),

  http.post(`${API_BASE_URL}/api/v1/admin/register-user`, () =>
    // Registration returns an AuthResponse with a null token, so @JsonInclude(NON_NULL)
    // leaves exactly these two fields on the wire.
    HttpResponse.json({ userId: TEST_USER_ID, message: "USER_CREATED" }, { status: 201 }),
  ),

  http.post(`${API_BASE_URL}/api/v1/admin/:tenantId/register-admin`, () =>
    HttpResponse.json({ userId: TEST_USER_ID, message: "TENANT_ADMIN_CREATED" }, { status: 201 }),
  ),

  http.get(`${ORDERS_BASE_URL}/api/orders`, ({ request }) => {
    const status = new URL(request.url).searchParams.get("status");
    const orders = [
      makeOrder(),
      makeOrder({ id: "2f0a1b2c-3d4e-5f60-7182-93a4b5c6d7e8", orderNumber: "ORD-1002", status: "SHIPPED" }),
    ];
    const filtered = status === null ? orders : orders.filter((order) => order.status === status);
    return HttpResponse.json(pageOf(filtered));
  }),

  http.get(`${ORDERS_BASE_URL}/api/orders/:id`, ({ params }) =>
    HttpResponse.json(makeOrder({ id: String(params["id"]) })),
  ),

  http.post(`${ORDERS_BASE_URL}/api/orders`, async ({ request }) => {
    const body = (await request.json()) as { orderNumber: string; totalAmount: string };
    return HttpResponse.json(
      makeOrder({ orderNumber: body.orderNumber, totalAmount: Number(body.totalAmount) }),
      { status: 201 },
    );
  }),

  http.patch(`${ORDERS_BASE_URL}/api/orders/:id/status`, async ({ params, request }) => {
    const body = (await request.json()) as { status: OrderStatus };
    return HttpResponse.json(makeOrder({ id: String(params["id"]), status: body.status }));
  }),

  http.delete(`${ORDERS_BASE_URL}/api/orders/:id`, () => new HttpResponse(null, { status: 204 })),
];
