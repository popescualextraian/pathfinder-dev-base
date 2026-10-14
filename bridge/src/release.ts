// parseHoldPid: the pid in hold.pid when it is an integer greater than 1; otherwise null. The file is
// writable by the agent: an empty or planted value must never reach kill() as 0 (the process group),
// -1 (everything) or 1.
export function parseHoldPid(text: string): number | null {
  const t = text.trim();
  if (!/^[0-9]+$/.test(t)) return null;
  const n = Number(t);
  return Number.isSafeInteger(n) && n > 1 ? n : null;
}
