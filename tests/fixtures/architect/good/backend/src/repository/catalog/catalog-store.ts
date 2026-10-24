import { loadConfig } from '../../commons/config';

let cache: string[] | undefined;

export function allProducts(): string[] {
  cache ??= ['mug', 'poster', 'sticker'].slice(0, loadConfig().pageSize);
  return cache;
}
