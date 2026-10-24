import { search } from '../../service/catalog/catalog-service';
import { validate } from '../../commons/validation';

export function getProducts(query: string): string[] {
  return search(validate(query));
}
