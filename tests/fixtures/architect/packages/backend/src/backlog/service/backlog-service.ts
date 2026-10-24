import { loadItems } from '../repository/backlog-store';

export function listItems(): string[] {
  return loadItems().filter((item) => item.length > 0);
}
