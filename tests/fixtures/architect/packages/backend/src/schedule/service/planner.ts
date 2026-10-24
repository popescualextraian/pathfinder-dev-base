import { log } from '../../commons/log';

export function plan(items: string[]): string[] {
  log('plan');
  return items.map((item, i) => `${i + 1}. ${item}`);
}
