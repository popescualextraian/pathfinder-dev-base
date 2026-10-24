import { fetchProducts, type Product } from '../api-client/catalog-client';

export function useProducts(): { list(): Product[] } {
  let cache: Product[] = [];
  void fetchProducts().then((p) => { cache = p; });
  return { list: () => cache };
}
