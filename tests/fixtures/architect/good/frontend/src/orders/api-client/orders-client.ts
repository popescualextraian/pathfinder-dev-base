export interface Order { id: string; total: number }

export async function fetchOrders(): Promise<Order[]> {
  const res = await fetch('/api/orders');
  return (await res.json()) as Order[];
}
