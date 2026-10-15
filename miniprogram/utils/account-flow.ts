/** Public referral metadata only. Never include an account, code, password or setup ticket. */
export function accountReferral(value: unknown): string {
  return typeof value === 'string' && /^u-[a-z0-9][a-z0-9-]{2,29}$/.test(value) ? value : ''
}
export function accountFlowUrl(flow: unknown, ref?: unknown): string {
  const safeFlow = flow === 'reset' ? 'reset' : 'register'
  const safeRef = safeFlow === 'register' ? accountReferral(ref) : ''
  return `https://aiworkdeck.com/zh/account?flow=${safeFlow}${safeRef ? '&ref=' + encodeURIComponent(safeRef) : ''}`
}
