import type { Payments } from '../../service/orders/payments';
import { loadConfig } from '../../commons/config';

export function createPayments(): Payments {
  const url = loadConfig().paymentUrl;
  return { charge: (orderId, amount) => url.length > 0 && orderId.length > 0 && amount > 0 };
}
