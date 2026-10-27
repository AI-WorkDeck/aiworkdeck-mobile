// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { preferences } from '@kit.ArkData'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util, JSON as ArkJson } from '@kit.ArkTS'
import { ServiceLocator } from './ServiceLocator'
import { PersonalConversation, stringField } from '../model/PersonalWorkspace'

export class PersonalConversationStore {
  private static generation: number = 0
  private scope: string
  private generation: number
  constructor(scope: string) { this.scope = scope; this.generation = PersonalConversationStore.generation }
  private static store(): preferences.Preferences { return preferences.getPreferencesSync(ServiceLocator.ctx, { name: 'personal-conversation' }) }
  private static async scope(): Promise<string> {
    const session: string | null = await ServiceLocator.session.current()
    if (session === null) return ''
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256')
    md.updateSync({ data: new util.TextEncoder().encodeInto(ServiceLocator.baseUrl() + ':' + session) })
    return Array.from(md.digestSync().data).map((v: number): string => v.toString(16).padStart(2, '0')).join('')
  }
  static async open(): Promise<PersonalConversationStore> {
    const scope: string = await PersonalConversationStore.scope()
    return new PersonalConversationStore(scope)
  }
  async isCurrent(): Promise<boolean> {
    const scope: string = await PersonalConversationStore.scope()
    return scope.length > 0 && scope === this.scope && this.generation === PersonalConversationStore.generation
  }
  async load(): Promise<PersonalConversation> {
    if (!await this.isCurrent() || this.generation !== PersonalConversationStore.generation) return new PersonalConversation()
    const text: preferences.ValueType = PersonalConversationStore.store().getSync('latest', '')
    try {
      const raw: Record<string, Object> = ArkJson.parse(text as string) as Record<string, Object>
      if (stringField(raw, 'scope') === this.scope) return PersonalConversation.from(raw)
    } catch (_) {}
    PersonalConversationStore.store().deleteSync('latest')
    await PersonalConversationStore.store().flush()
    return new PersonalConversation()
  }
  async save(value: PersonalConversation): Promise<boolean> {
    if (!await this.isCurrent() || this.generation !== PersonalConversationStore.generation) return false
    const raw: Record<string, Object> = { 'scope': this.scope, 'conversationId': value.conversationId, 'pendingId': value.pendingId,
      'pendingText': value.pendingText, 'pendingConversationId': value.pendingConversationId }
    PersonalConversationStore.store().putSync('latest', ArkJson.stringify(raw))
    await PersonalConversationStore.store().flush()
    return true
  }
  static async clear(): Promise<void> {
    PersonalConversationStore.generation++
    PersonalConversationStore.store().deleteSync('latest')
    await PersonalConversationStore.store().flush()
  }
}
