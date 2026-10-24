export function validate(input: string): string {
  if (input.length > 200) throw new Error('input too long');
  return input.trim();
}
