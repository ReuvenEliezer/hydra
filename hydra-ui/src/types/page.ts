/**
 * The paginated shape `GET /api/orders` actually returns.
 *
 * Determined from source rather than guessed (T037c): `OrderController.getOrders`
 * returns `Page<OrderResponse>` directly, and order-service registers its own
 * `JsonMapper` bean in `GeneralConfig`. That bean is built by hand with
 * `findAndAddModules()`, so Spring Data's `PageModule` — the thing that would rewrite a
 * `Page` into the nested `PagedModel` layout — is never applied to it. The response is
 * therefore Spring Data's DIRECT `PageImpl` serialization, with the page metadata at the
 * TOP LEVEL:
 *
 * ```json
 * { "content": [...], "pageable": {...}, "totalElements": 2, "totalPages": 1,
 *   "size": 20, "number": 0, "first": true, "last": true,
 *   "numberOfElements": 2, "empty": false, "sort": {...} }
 * ```
 *
 * `normalizePage` ALSO accepts the nested `{ content, page: {...} }` layout, because
 * that is exactly what appears the day someone sets
 * `@EnableSpringDataWebSupport(pageSerializationMode = VIA_DTO)` — which Spring Data
 * actively nudges you toward with a startup warning. Accepting both costs four lines
 * and turns a silent "every list is empty" bug into a non-event.
 */
export interface PageMeta {
  number: number;
  size: number;
  totalElements: number;
  totalPages: number;
}

export interface Page<T> {
  content: T[];
  page: PageMeta;
}

export const EMPTY_PAGE_META: PageMeta = {
  number: 0,
  size: 0,
  totalElements: 0,
  totalPages: 0,
};

function toNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export function normalizePage<T>(raw: unknown, mapItem: (item: unknown) => T): Page<T> {
  const body = (raw ?? {}) as Record<string, unknown>;
  const content = Array.isArray(body["content"]) ? body["content"] : [];

  // VIA_DTO puts metadata under `page`; DIRECT puts it at the top level.
  const nested = body["page"];
  const meta = (nested !== null && typeof nested === "object" ? nested : body) as Record<
    string,
    unknown
  >;

  return {
    content: content.map(mapItem),
    page: {
      number: toNumber(meta["number"], 0),
      size: toNumber(meta["size"], content.length),
      totalElements: toNumber(meta["totalElements"], content.length),
      totalPages: toNumber(meta["totalPages"], content.length === 0 ? 0 : 1),
    },
  };
}
