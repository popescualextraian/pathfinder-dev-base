export interface Config { pageSize: number; paymentUrl: string }

export function loadConfig(): Config {
  return { pageSize: Number(process.env.PAGE_SIZE ?? '50'), paymentUrl: process.env.PAYMENT_URL ?? 'https://pay.example.com' };
}
