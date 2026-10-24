import { log } from '../../commons/log';

export function loadItems(): string[] {
  log('load');
  return ['write tests', 'ship'];
}
