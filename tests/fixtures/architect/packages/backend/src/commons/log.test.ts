// Test files are excluded from the rules: this import would break the layers.
import { start } from '../main';
import { log } from './log';

log(typeof start);
