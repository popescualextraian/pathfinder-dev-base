import { fetchOrders, type Order } from '../api-client/orders-client';

export function useOrders(): { list(): Order[] } {
  let cache: Order[] = [];
  void fetchOrders().then((o) => { cache = o; });
  return { list: () => cache };
}
