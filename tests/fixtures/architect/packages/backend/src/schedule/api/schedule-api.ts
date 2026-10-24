import { plan } from '../service/planner';
import { backlog } from '../../backlog/index';

export function schedule(): string[] {
  return plan(backlog());
}
