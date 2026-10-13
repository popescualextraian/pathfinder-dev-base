// Token masking for everything the bridge writes or sends (spec §11).
const PATTERNS: Array<[RegExp, string]> = [
  [/sk-ant-[A-Za-z0-9_-]{8,}/g, "[redacted]"],
  [/\bgh[opsu]_[A-Za-z0-9]{16,}/g, "[redacted]"],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "[redacted]"],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer [redacted]"],
  [/\bAKIA[0-9A-Z]{16}\b/g, "[redacted]"],
];

export function makeRedactor(secrets: string[]): (s: string) => string {
  // Longest first, so a secret containing another one is masked whole.
  const own = [...new Set(secrets.filter((s) => s.length >= 8))].sort((a, b) => b.length - a.length);
  return (s: string) => {
    let out = s;
    for (const t of own) out = out.split(t).join("[redacted]");
    for (const [re, rep] of PATTERNS) out = out.replace(re, rep);
    return out;
  };
}

// JSON-shaped values only: plain objects, arrays, strings.
export function redactDeep<T>(value: T, redact: (s: string) => string): T {
  if (typeof value === "string") return redact(value) as T;
  if (Array.isArray(value)) return value.map((v) => redactDeep(v, redact)) as T;
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, redactDeep(v, redact)]),
    ) as T;
  }
  return value;
}
