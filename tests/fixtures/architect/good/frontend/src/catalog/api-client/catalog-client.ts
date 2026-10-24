export interface Product { id: string; name: string }

export async function fetchProducts(): Promise<Product[]> {
  const res = await fetch('/api/products');
  return (await res.json()) as Product[];
}
