import { backlog } from './backlog/index';
import { schedule } from './schedule/index';
import { log } from './commons/log';

export function start(): void {
  log(`${backlog().length} items, ${schedule().length} slots`);
}
