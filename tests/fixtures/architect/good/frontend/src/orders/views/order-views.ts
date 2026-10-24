import { useOrders } from '../state/order-state';

export function renderOrderHistory(): string {
  return useOrders().list().map((o) => o.id).join('\n');
}
