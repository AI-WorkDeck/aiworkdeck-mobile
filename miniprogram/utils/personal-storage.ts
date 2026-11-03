// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { personalAccountScope } from './api'
import type { PersonalQuestion, PersonalDesktopCopy } from './personal'
export interface SavedPersonalConversation { conversationId?: string; pending?: PersonalQuestion; desktopCopy?: PersonalDesktopCopy }
const KEY = 'awd.personalConversation'
export function readPersonalConversation(): SavedPersonalConversation | undefined {
  const scope = personalAccountScope()
  const saved = wx.getStorageSync(KEY) as (SavedPersonalConversation & { scope: string }) | undefined
  return scope && saved?.scope === scope ? saved : undefined
}
export function savePersonalConversation(value: SavedPersonalConversation): void {
  const scope = personalAccountScope()
  if (scope) wx.setStorageSync(KEY, { scope, conversationId: value.conversationId, pending: value.pending, desktopCopy: value.desktopCopy })
}
export function clearPersonalConversation(): void { wx.removeStorageSync(KEY) }
