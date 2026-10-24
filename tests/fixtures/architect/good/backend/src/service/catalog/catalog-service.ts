import { allProducts } from '../../repository/catalog/catalog-store';

export function search(query: string): string[] {
  return allProducts().filter((p) => p.includes(query));
}

export function priceOf(sku: string): number {
  return sku.length * 100;
}
