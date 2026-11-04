// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
/** Capability responses are authoritative; legacy fallback is only for older servers. */
export interface CloudAccess { canUse: boolean; canWrite: boolean; canRead: boolean; reason: string; epoch?: number; includedStorageBytes?: number; caseId?: string | null; cleanupEligible?: boolean; notificationStatus?: string; frozen?: boolean; cleanupState?: string }
export interface CloudState { cloudAccess?: CloudAccess; subscriptionActive: boolean }
export function cloudCanRead(state: CloudState): boolean { return state.cloudAccess ? state.cloudAccess.canRead === true : state.subscriptionActive }
export function cloudCanWrite(state: CloudState): boolean { return state.cloudAccess ? state.cloudAccess.canWrite === true : state.subscriptionActive }
export function cloudCanUse(state: CloudState): boolean { return state.cloudAccess ? state.cloudAccess.canUse === true : state.subscriptionActive }

export interface PostpaidBilling {
  policyVersion: string; accepted: boolean; acceptEnabled: boolean; unit: string; cashCurrency: 'CNY' | 'USD';
  creditLimitCents: number; debtCents: number; reservedCreditCents: number; availableCreditCents: number;
  overLimitAt: string | null; remindAt: string | null; cleanupAt: string | null;
  storagePrice: { cashCentsPerGiBMonth: number; cashCurrency: 'CNY' | 'USD'; periodSeconds: number; gibBytes: number };
  egressPrice?: { cashCentsPerGiB: number; cashCurrency: 'CNY' | 'USD'; gibBytes: number };
}
export interface PostpaidState { billing: PostpaidBilling; cloudAccess: CloudAccess }
