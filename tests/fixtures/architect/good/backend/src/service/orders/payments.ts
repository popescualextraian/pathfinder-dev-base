export interface Payments {
  charge(orderId: string, amount: number): boolean;
}
