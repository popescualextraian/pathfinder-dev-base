import { listItems } from '../service/backlog-service';
import { log } from '../../commons/log';

export function backlog(): string[] {
  log('backlog');
  return listItems();
}
