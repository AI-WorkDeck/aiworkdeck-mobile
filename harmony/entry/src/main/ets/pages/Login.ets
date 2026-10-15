import { common, Want } from '@kit.AbilityKit'
import { ContractCapabilities } from 'contract'
import { AppModel } from '../AppModel'
import { Pill, PrimaryButton, SegmentToggle } from '../design/Components'
import { LOCALE_ZH, trIn } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { AccountRegion, LoginMethod, defaultLoginMethodOf, loginMethodsOf } from '../model/AccountRegion'
import { LoginResult } from '../services/ApiTypes'
import { ServiceLocator } from '../services/ServiceLocator'
import { errorText, toast } from './Feedback'

export function looksLikeEmail(email: string): boolean {
  const at: number = email.indexOf('@')
  if (at <= 0) return false
  const domain: string = email.substring(at + 1)
  return domain.includes('.') && !domain.startsWith('.') && !domain.endsWith('.')
}

@Component
export struct Login {
  @StorageProp('awdLocale') locale: string = LOCALE_ZH
  @State region: AccountRegion = ServiceLocator.region
  @State method: LoginMethod = defaultLoginMethodOf(ServiceLocator.region)
  @State identity: string = ''
  @State password: string = ''
  @State busy: boolean = false
  @State reviewMode: boolean = false

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: Tk.Sp.s4 }) {
          if (ContractCapabilities.intlAccount) {
            SegmentToggle({
              leftLabel: this.t('login.region.cn'), rightLabel: this.t('login.region.intl'),
              rightOn: this.region === AccountRegion.intl, a11yLabel: this.t('login.region.a11y'),
              onToggle: (): void => this.switchRegion(),
            })
          }
          Text(this.t('login.title')).fontSize(Tk.Ty.display).fontColor(Tk.L.fg)
          Text(this.t('login.passwordHint')).fontSize(Tk.Ty.micro).fontColor(Tk.L.fgMuted)
          if (loginMethodsOf(this.region).length > 1) {
            Row({ space: Tk.Sp.s2 }) {
              Pill({ label: this.t('login.phone'), selected: this.method === LoginMethod.phone,
                onTap: (): void => this.pick(LoginMethod.phone) })
              Pill({ label: this.t('login.email'), selected: this.method === LoginMethod.email,
                onTap: (): void => this.pick(LoginMethod.email) })
            }
          }
          TextInput({ text: this.identity, placeholder: this.t(this.method === LoginMethod.phone ? 'login.phonePlaceholder' : 'login.emailPlaceholder') })
            .type(this.method === LoginMethod.phone ? InputType.PhoneNumber : InputType.Email)
            .fontColor(Tk.L.fg).backgroundColor(Tk.L.bg).caretColor(Tk.L.accent)
            .enabled(!this.busy).onChange((value: string): void => { this.identity = value.trim() })
          TextInput({ text: this.password, placeholder: this.t(this.reviewMode ? 'login.reviewCredential' : 'login.passwordPlaceholder') })
            .type(InputType.Password).fontColor(Tk.L.fg).backgroundColor(Tk.L.bg).caretColor(Tk.L.accent).enabled(!this.busy)
            .onChange((value: string): void => { this.password = value })
          PrimaryButton({ label: this.t(this.busy ? 'login.working' : 'login.title'),
            isEnabled: !this.busy && this.identity.trim().length > 0 && this.password.length > 0,
            onTap: (): void => this.signIn() })
          Text(this.t(this.reviewMode ? 'login.passwordMode' : 'login.review')).fontColor(Tk.L.fgMuted).height(Tk.touchMin)
            .onClick((): void => { if (!this.busy) { this.reviewMode = !this.reviewMode; this.password = '' } })
          Text(this.t('login.register')).fontColor(Tk.L.accent).height(Tk.touchMin)
            .onClick((): void => this.openFlow('register'))
          Text(this.t('login.forgotPassword')).fontColor(Tk.L.accent).height(Tk.touchMin)
            .onClick((): void => this.openFlow('reset'))
          Text(this.t('login.webHint')).fontSize(Tk.Ty.micro).fontColor(Tk.L.fgMuted)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(Tk.Sp.gutter)
      }.width('100%').height('100%')
    }.hideTitleBar(true).backgroundColor(Tk.L.bg)
  }

  private t(key: string): string { return trIn(this.locale, key) }
  private pick(method: LoginMethod): void {
    if (this.busy || this.method === method) return
    this.method = method; this.identity = ''; this.password = ''; this.reviewMode = false
  }
  private switchRegion(): void {
    if (this.busy) return
    this.region = this.region === AccountRegion.cn ? AccountRegion.intl : AccountRegion.cn
    this.method = defaultLoginMethodOf(this.region); this.identity = ''; this.password = ''; this.reviewMode = false
    ServiceLocator.setRegion(this.region).catch((e: Object): void => { toast(this.getUIContext(), errorText(e)) })
  }
  private openFlow(flow: string): void {
    if (this.busy) return
    this.password = ''; this.reviewMode = false
    const host: string = this.region === AccountRegion.intl ? 'https://workdeck.ai/en/account' : 'https://aiworkdeck.com/zh/account'
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: host + '?flow=' + flow }
    const ctx: common.UIAbilityContext = ServiceLocator.ctx as common.UIAbilityContext
    ctx.startAbility(want).catch((): void => { toast(this.getUIContext(), this.t('login.webError')) })
  }
  private signIn(): void {
    if (this.busy || this.identity.trim().length === 0 || this.password.length === 0) return
    this.busy = true
    const request: Promise<LoginResult> = !this.reviewMode
      ? ServiceLocator.backend.accountLogin(this.identity.trim(), this.password)
      : this.method === LoginMethod.phone
        ? ServiceLocator.backend.verifyLoginCode(this.identity.trim(), this.password)
        : ServiceLocator.backend.verifyMailLoginCode(this.identity.trim(), this.password)
    request.then(async (result: LoginResult): Promise<void> => {
      this.password = ''
      await AppModel.shared.didLogin(result.user)
    }).catch((e: Object): void => { toast(this.getUIContext(), errorText(e)) })
      .finally((): void => { this.busy = false })
  }
}
