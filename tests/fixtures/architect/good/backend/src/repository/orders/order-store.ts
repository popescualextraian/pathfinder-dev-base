import { loadConfig } from '../../commons/config';

const rows: string[] = ['order-1', 'order-2'];

export function findOrders(limit: number): string[] {
  return rows.slice(0, Math.min(limit, loadConfig().pageSize));
}

export function* streamOrders(): Iterable<string> {
  yield* rows;
}
