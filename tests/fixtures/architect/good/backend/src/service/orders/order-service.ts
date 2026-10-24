import type { Payments } from './payments';
import { createPayments } from '../../integration/orders/payment-gateway';
import { findOrders } from '../../repository/orders/order-store';
import { priceOf } from '../catalog/catalog-service';

const payments: Payments = createPayments();

export function listOrders(limit: number): string[] {
  return findOrders(limit);
}

export function checkout(orderId: string, sku: string): boolean {
  return payments.charge(orderId, priceOf(sku));
}
