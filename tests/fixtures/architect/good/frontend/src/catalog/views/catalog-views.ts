import { useProducts } from '../state/catalog-state';

export function renderProductList(): string {
  return useProducts().list().map((p) => p.name).join('\n');
}
