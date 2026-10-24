import { listOrders } from '../../service/orders/order-service';
import { loadConfig } from '../../commons/config';
// Accepted exception: the CSV export streams rows straight from the store.
import { streamOrders } from '../../repository/orders/order-store';

export function getOrders(): string[] {
  return listOrders(loadConfig().pageSize);
}

export function exportOrdersCsv(): string {
  return [...streamOrders()].join('\n');
}
