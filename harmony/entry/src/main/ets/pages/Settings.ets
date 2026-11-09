import { invalidateCloudEpoch } from '../services/CloudEpoch'
import { common, Want } from '@kit.AbilityKit'
import { Prefs } from '../services/Prefs'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { ContractCapabilities, ContractLocale } from 'contract'
import { BackupConsentService } from '../services/BackupConsentService'
import { BackupConsent } from '../model/ProjectFiles'
import { AppModel } from '../AppModel'
import { L10n, LOCALE_SYSTEM, LOCALE_ZH, trIn } from '../design/L10n'
import { Tk } from '../design/Tokens'
import { formatBytes } from '../model/Format'
import { RelayProject } from '../model/Capture'
import { Unauthorized } from '../model/Envelope'
import { AccountUser, BillingSnapshot, MediaUsage, SubscriptionBalance, asRecord } from '../services/ApiTypes'
import { ServiceLocator } from '../services/ServiceLocator'
import { billingAvailableIn, regionLabelKey } from '../model/AccountRegion'
import { errorText, toast } from './Feedback'
import { PrimaryButton } from '../design/Components'

const DOMAIN: number = 0x0000
const TAG: string = 'Settings'

/** 用量读不到时的占位。一条「—」比一行报错更符合这行信息的分量。 */
const DASH: string = '—'

/**
 * 本端的充值通道，唯一来源是 contract/capabilities.json。当前是 'external'：鸿蒙没有支付通道，
 * 入口照放、点开只说明去哪儿充。**不能什么都不渲染**——让用户在界面上找不到充值口正是
 * 2026-09-09 那起事故（docs/MOBILE_DEV_DISCIPLINE.md §1）。
 */
const RECHARGE_CHANNEL: string = ContractCapabilities.recharge

/** 服务器地址只显示主机名——协议与路径对用户没有意义。 */
function hostOf(url: string): string {
  const scheme: number = url.indexOf('://')
  const rest: string = scheme < 0 ? url : url.substring(scheme + 3)
  const slash: number = rest.indexOf('/')
  return slash < 0 ? rest : rest.substring(0, slash)
}

/** 帮助邮箱（与 iOS 设置页同一个地址）。 */
const HELP_EMAIL: string = 'hi@aiworkdeck.com'

/**
 * 设置。顶部账号名；分组：费用、云端存储（用量与备份）、归档目标、影像、通用（语言、区域）、关于；
 * 最底下退出登录与注销。对位 iOS #91 的信息结构。
 * 镜像安卓 `SettingsScreen.kt` 与 iOS `SettingsView`。
 */
@Component
export struct Settings {
  stack: NavPathStack = new NavPathStack()
  @StorageProp('awdLocale') locale: string = LOCALE_ZH
  private organizationScope: string = ''
  @State organizeCaptures: boolean = false
  @State saveToAlbum: boolean = false
  @State showLanguagePicker: boolean = false
  @State projectName: string = DASH
  @State usage: MediaUsage | null = null
  @State subscription: SubscriptionBalance | null = null
  /** 包晴天律师（billingLine = bqt）只在包晴天 App 充值 */
  @State bqt: boolean = false
  @State backup: BackupConsent | null = null
  @State postpaid: Record<string, Object> | null = null
  @State postpaidBusy: boolean = false
  @State postpaidError: string = ''
  @State postpaidOpen: boolean = false
  private postpaidSession: string = ''
  private token: number = -1
  /** 这一屏还在不在。异步回调回来时组件可能已经销毁，往里写 @State 是错误日志甚至崩溃。 */
  private alive: boolean = false

  private t(key: string, vars?: Record<string, string | number>): string {
    return trIn(this.locale, key, vars)
  }

  aboutToAppear(): void {
    this.alive = true
    ServiceLocator.session.current().then((sid: string | null): void => {
      if (!this.alive) return
      this.organizationScope = Prefs.organizationScope(ServiceLocator.baseUrl(), sid)
      this.organizeCaptures = ServiceLocator.prefs.organizeCaptures(this.organizationScope)
    }).catch((): void => {})
    this.token = AppModel.shared.subscribe((): void => this.syncProject())
    this.syncProject()
    ServiceLocator.backend.backupConsent().then((v: BackupConsent): void => { if (this.alive) this.backup = v }).catch((): void => {})
    ServiceLocator.prefs.saveToAlbum().then((v: boolean): void => {
      if (!this.alive) return
      this.saveToAlbum = v
    }).catch((): void => {})
    this.loadPostpaid().catch((): void => {})
    if (billingAvailableIn(ServiceLocator.region)) {
      ServiceLocator.backend.billingSnapshot().then((b: BillingSnapshot): void => {
        if (!this.alive) return
        this.subscription = b.subscription
        this.bqt = b.billingLine === 'bqt'
      }).catch((): void => { if (this.alive) this.subscription = null })
    }
    // 进页面拉一次用量。读不到就留占位「—」，比一条报错更符合这行信息的分量；
    // 但会话失效是另一回事——和选项目页同口径，回登录页，别让人对着一屏死数据点
    AppModel.shared.mediaUsage().then((u: MediaUsage): void => {
      if (!this.alive) return
      this.usage = u
    }).catch((e: Object): void => {
      if (e instanceof Unauthorized) {
        AppModel.shared.signOut().catch((): void => {})
        return
      }
      // 走查发现「—」常驻却查不出原因：其他失败也得留一行日志，不然无从定性
      hilog.warn(DOMAIN, TAG, 'mediaUsage failed: %{public}s', `${e}`)
    })
  }

  aboutToDisappear(): void {
    this.alive = false
    if (this.token >= 0) AppModel.shared.unsubscribe(this.token)
  }

  build() {
    NavDestination() {
      Column() {
        this.topBar()
        Scroll() {
          Column() {
            this.accountHeader()
            if (billingAvailableIn(ServiceLocator.region)) {
              this.billingGroup()
            }
            this.cloudGroup()
            this.archiveGroup()
            this.mediaGroup()
            this.generalGroup()
            this.aboutGroup()
            this.signOutRows()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, bottom: Tk.Sp.s16 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .direction(L10n.isRtl(this.locale) ? Direction.Rtl : Direction.Ltr)
    }
    .hideTitleBar(true)
    .backgroundColor(Tk.L.bg)
  }

  @Builder
  topBar() {
    Column() {
      Row({ space: Tk.Sp.s2 }) {
        Text('✕')
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.L.fg)
          .width(Tk.touchMin)
          .height(Tk.touchMin)
          .textAlign(TextAlign.Center)
          .accessibilityText(this.t('common.close'))
          .onClick((): void => {
            this.stack.pop()
          })
        Text(this.t('home.settings'))
          .fontSize(Tk.Ty.heading)
          .fontColor(Tk.L.fg)
      }
      .width('100%')
      .padding({ left: Tk.Sp.s2, right: Tk.Sp.gutter, bottom: Tk.Sp.s2 })

      Divider().color(Tk.L.rule)
    }
  }

  @Builder
  mediaGroup() {
    this.eyebrow(this.t('settings.media'))
    Row({ space: Tk.Sp.s3 }) {
      Column({ space: Tk.Sp.s1 }) {
        Text(this.t('organize.title')).fontSize(Tk.Ty.body).fontColor(Tk.L.fg)
        Text(this.t('organize.hint')).fontSize(Tk.Ty.nano).fontColor(Tk.L.fgFaint)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.organizeCaptures })
        .enabled(this.organizationScope.length > 0)
        .selectedColor(Tk.L.accent)
        .onChange((value: boolean): void => {
          const expected: string = this.organizationScope
          ServiceLocator.session.current().then(async (sid: string | null): Promise<void> => {
            if (!this.alive || expected !== Prefs.organizationScope(ServiceLocator.baseUrl(), sid)) return
            await ServiceLocator.prefs.setOrganizeCaptures(expected, value)
            if (this.alive) this.organizeCaptures = value
          }).catch((): void => { toast(this.getUIContext(), this.t('error.network')) })
        })
    }.width('100%').alignItems(VerticalAlign.Center)
    this.rule()
    Row({ space: Tk.Sp.s3 }) {
      Column({ space: Tk.Sp.s1 }) {
        Text(this.t('settings.saveToAlbum'))
          .fontSize(Tk.Ty.body)
          .fontColor(Tk.L.fg)
        // 把权衡摆在这儿，让每次选择都是知情的
        Text(this.t('settings.saveToAlbum.hint'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.L.fgFaint)
        // 鸿蒙没有静默写相册的路（spec H8）：开了之后每件都会弹系统确认，说在前面
        Text(this.t('settings.saveToAlbum.dialogHint'))
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.L.fgFaint)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.saveToAlbum })
        .selectedColor(Tk.L.accent)
        .onChange((v: boolean): void => {
          this.saveToAlbum = v
          ServiceLocator.prefs.setSaveToAlbum(v).catch((): void => {})
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)

    this.rule()
  }

  @Builder
  archiveGroup() {
    this.eyebrow(this.t('settings.archiveTarget'))
    if (ServiceLocator.region === 'cn') {
      Text(this.t('dd.title')).fontSize(Tk.Ty.small).fontColor(Tk.L.accent).height(Tk.touchMin)
        .onClick((): void => { this.stack.pushPath(new NavPathInfo('DdClient', '')) })
    }
    this.infoRow(this.t('home.eyebrow'), this.projectName)
    Text(this.t('settings.switchProject'))
      .fontSize(Tk.Ty.small)
      .fontColor(Tk.L.accent)
      .height(Tk.touchMin)
      .onClick((): void => {
        this.stack.pushPath(new NavPathInfo('ProjectPickerSwitch', ''))
      })
    this.rule()
  }

  /** 账号：名字放在最上面，一眼知道登的是谁。 */
  @Builder
  accountHeader() {
    Column({ space: Tk.Sp.s1 }) {
      Text(this.accountName())
        .fontSize(Tk.Ty.heading)
        .fontColor(Tk.L.fg)
      if (this.accountUsername().length > 0) {
        Text(this.accountUsername())
          .fontSize(Tk.Ty.nano)
          .fontColor(Tk.L.fgFaint)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: Tk.Sp.s4 })
    .accessibilityText(this.accountName() === this.t('settings.signedIn') ? this.accountName() : this.t('settings.signedIn') + ' ' + this.accountName())
  }

  /** 费用：余额、充值、后付费放一起；国际区不计费时整组不出现。 */
  @Builder
  billingGroup() {
    this.eyebrow(this.t('settings.billing'))
    if (this.subscription?.active === true) {
      this.infoRow(this.t('subscription.available'), this.credits(this.subscription.availableCents))
      this.infoRow(this.t('subscription.weekly'), `${this.credits(this.subscription.weeklyUsedCents)} / ${this.credits(this.subscription.weeklyLimitCents)}`)
      this.infoRow(this.t('subscription.monthly'), `${this.credits(this.subscription.monthlyUsedCents)} / ${this.credits(this.subscription.monthlyLimitCents)}`)
    }
    // 包晴天律师只在包晴天 App 充值（本站充值会被服务端以 bqt_recharge_via_bqt 拒绝）：
    // 收起充值与后付费段，只留一句去哪里充
    if (this.bqt) {
      Text(this.t('bqt.rechargeInBqt'))
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fgMuted)
        .width('100%')
        .margin({ top: Tk.Sp.s2, bottom: Tk.Sp.s2 })
    } else {
      if (RECHARGE_CHANNEL !== 'false') {
        this.navRow(this.t('recharge.entry'), '', (): void => this.showRechargeNotice())
      }
      this.postpaidSection()
    }
    this.rule()
  }

  /** 云端：用量与备份，都是「我的东西在云上占多少、有没有备份」。 */
  @Builder
  cloudGroup() {
    this.eyebrow(this.t('settings.cloud'))
    this.infoRow(this.t('settings.relay'), this.usageCaption())
    Progress({ value: this.usageFraction(), total: 100, type: ProgressType.Linear })
      .color(Tk.L.accent)
      .backgroundColor(Tk.L.sunken)
      .width('100%')
      .margin({ bottom: Tk.Sp.s2 })
    if (this.usage?.persistentUsedBytes !== undefined) {
      this.infoRow(this.t('settings.persistent'), this.persistentCaption())
    }
    this.navRow(this.t('backup.title'), this.backup === null ? DASH : this.t(this.backup.enabled ? 'backup.enabled' : 'backup.disabled'), (): void => {
      this.changeBackup().catch((): void => toast(this.getUIContext(), this.t('backup.error')))
    })
    // 不计费区域照旧渲染后付费段（它自己显示「通道不可用」），只是不给还款入口
    if (!billingAvailableIn(ServiceLocator.region)) {
      this.postpaidSection()
    }
    this.rule()
  }

  // 国际站计费未开通（dev-board#664）：国际区不放充值 / 还款入口
  /** 设置页里只占一行：名称 + 一个词的状态，点开才是授信、费率与条款。 */
  @Builder
  postpaidSection() {
    Row({ space: Tk.Sp.s3 }) {
      Text(this.t('postpaid.title'))
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fg)
      Text(this.postpaidStatus())
        .fontSize(Tk.Ty.small)
        .fontColor(this.postpaidStatusAlert() ? Tk.S.failed : Tk.L.fgMuted)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
      Text('›')
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.L.fgFaint)
    }
    .width('100%')
    .height(Tk.touchMin)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { this.postpaidOpen = true })
    .bindSheet(this.postpaidOpen, this.postpaidDetail(), {
      height: SheetSize.LARGE,
      backgroundColor: Tk.L.bg,
      title: { title: this.t('postpaid.title') },
      onDisappear: (): void => {
        this.postpaidOpen = false
        this.loadPostpaid().catch((): void => {})
      },
    })
  }

  /** 后付费详情：数字一行一项（名称左、值右），条款放最后当脚注，动作按钮只在能做时出现。 */
  @Builder
  postpaidDetail() {
    Scroll() {
      Column({ space: Tk.Sp.s3 }) {
        if (this.postpaidBilling() !== null && this.postpaidAccess() !== null) {
          if (this.postpaidAccess()!['cleanupState'] === 'complete') {
            Text(this.t('postpaid.cleared')).fontSize(Tk.Ty.small).fontColor(Tk.S.failed).margin({ top: Tk.Sp.s4 })
          } else if (this.postpaidBilling()!['accepted'] === true && this.postpaidAccess()!['canUse'] !== true) {
            Text(this.t('postpaid.restricted')).fontSize(Tk.Ty.small).fontColor(Tk.S.failed).margin({ top: Tk.Sp.s4 })
          }
          Column() {
            this.infoRow(this.t('postpaid.limit'), this.postpaidMoney('creditLimitCents'))
            this.infoRow(this.t('postpaid.available'), this.postpaidMoney('availableCreditCents'))
            this.debtRow()
            if (typeof this.postpaidBilling()!['remindAt'] === 'string') {
              this.infoRow(this.t('postpaid.remind'), this.postpaidBilling()!['remindAt'] as string)
            }
            if (typeof this.postpaidBilling()!['cleanupAt'] === 'string') {
              this.infoRow(this.t('postpaid.cleanup'), this.postpaidBilling()!['cleanupAt'] as string)
            }
          }
          .width('100%')
          .margin({ top: Tk.Sp.s2 })
          Divider().color(Tk.L.rule).margin({ top: Tk.Sp.s2, bottom: Tk.Sp.s2 })
          if (this.postpaidRate('storagePrice', 'cashCentsPerGiBMonth').length > 0) {
            Text(this.t('postpaid.storageRate', { 'amount': this.postpaidRate('storagePrice', 'cashCentsPerGiBMonth') }))
              .fontSize(Tk.Ty.small).fontColor(Tk.L.fg)
          }
          if (this.postpaidRate('egressPrice', 'cashCentsPerGiB').length > 0) {
            Text(this.t('postpaid.egressRate', { 'amount': this.postpaidRate('egressPrice', 'cashCentsPerGiB') }))
              .fontSize(Tk.Ty.small).fontColor(Tk.L.fg)
          }
          Text(this.t('postpaid.notice'))
            .fontSize(Tk.Ty.nano)
            .fontColor(Tk.L.fgFaint)
            .margin({ top: Tk.Sp.s2 })
          if (!billingAvailableIn(ServiceLocator.region)) {
            Text(this.t('postpaid.channelUnavailable')).fontSize(Tk.Ty.nano).fontColor(Tk.L.fgFaint)
          }
          Column({ space: Tk.Sp.s3 }) {
            if (billingAvailableIn(ServiceLocator.region) && this.postpaidDebt() > 0) {
              PrimaryButton({ label: this.t('postpaid.repay'), isEnabled: !this.postpaidBusy,
                onTap: (): void => this.openRepayment() })
            }
            if (this.canAcceptPostpaid()) {
              PrimaryButton({ label: this.t('postpaid.accept'), isEnabled: !this.postpaidBusy,
                onTap: (): void => this.confirmPostpaid() })
            }
            if (this.canResumeCloud()) {
              Text(this.t('postpaid.resume'))
                .fontSize(Tk.Ty.small)
                .fontColor(Tk.L.accent)
                .height(Tk.touchMin)
                .enabled(!this.postpaidBusy)
                .onClick((): void => this.confirmResumeCloud())
            }
          }
          .width('100%')
          .margin({ top: Tk.Sp.s4 })
        } else if (this.postpaidBusy) {
          LoadingProgress()
            .width(Tk.touchMin)
            .height(Tk.touchMin)
            .color(Tk.L.fgMuted)
            .margin({ top: Tk.Sp.s10 })
        }
        if (this.postpaidError.length > 0) {
          Text(this.postpaidError).fontSize(Tk.Ty.small).fontColor(Tk.S.failed).margin({ top: Tk.Sp.s4 })
          Text(this.t('project.retry'))
            .fontSize(Tk.Ty.small)
            .fontColor(Tk.L.accent)
            .height(Tk.touchMin)
            .enabled(!this.postpaidBusy)
            .onClick((): void => { this.loadPostpaid().catch((): void => {}) })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Tk.Sp.gutter, right: Tk.Sp.gutter, bottom: Tk.Sp.s10 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  /** 欠费那一行：有欠款时值用失败色。 */
  @Builder
  debtRow() {
    Row({ space: Tk.Sp.s3 }) {
      Text(this.t('postpaid.debt'))
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fg)
      Text(this.postpaidMoney('debtCents'))
        .fontSize(Tk.Ty.small)
        .fontColor(this.postpaidDebt() > 0 ? Tk.S.failed : Tk.L.fgMuted)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 32 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  generalGroup() {
    this.eyebrow(this.t('settings.general'))
    this.navRow(this.t('settings.language'), L10n.displayName(L10n.preference, this.locale), (): void => {
      this.showLanguagePicker = !this.showLanguagePicker
    })
    if (this.showLanguagePicker) {
      Column({ space: Tk.Sp.s1 }) {
        Text(this.t('settings.languageFollowSystem'))
          .fontSize(Tk.Ty.small)
          .fontColor(L10n.preference === LOCALE_SYSTEM ? Tk.L.accent : Tk.L.fg)
          .height(Tk.touchMin)
          .onClick((): void => {
            this.pickLanguage(LOCALE_SYSTEM)
          })
        ForEach(L10n.supportedLocales(), (loc: ContractLocale): void => {
          Text(loc.nativeName)
            .fontSize(Tk.Ty.small)
            .fontColor(L10n.preference === loc.code ? Tk.L.accent : Tk.L.fg)
            .height(Tk.touchMin)
            .onClick((): void => {
              this.pickLanguage(loc.code)
            })
        }, (loc: ContractLocale): string => loc.code)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: Tk.Sp.s3, bottom: Tk.Sp.s3 })
    }
    // 区域登录后固定（换区 = 退出登录后在登录页重选），这里只读显示；服务器行跟着区域走
    if (ContractCapabilities.intlAccount) {
      this.infoRow(this.t('settings.region'), this.t(regionLabelKey(ServiceLocator.region)))
    }
    this.rule()
  }

  @Builder
  signOutRows() {
    Text(this.t('common.signOut'))
      .fontSize(Tk.Ty.small)
      .fontColor(Tk.S.failed)
      .height(Tk.touchMin)
      .margin({ top: Tk.Sp.s4 })
      .onClick((): void => {
        AppModel.shared.signOut().catch((): void => {})
      })
    // 放在退出登录下面、字号更小：它比退出重得多，不该长得一样容易误点
    Text(this.t('settings.deleteAccount'))
      .fontSize(Tk.Ty.micro)
      .fontColor(Tk.L.fgMuted)
      .height(Tk.touchMin)
      .onClick((): void => this.confirmDelete())
  }

  @Builder
  aboutGroup() {
    this.eyebrow(this.t('settings.about'))
    this.infoRow(this.t('settings.version'), ServiceLocator.facts.appVersion)
    this.infoRow(this.t('settings.package'), ServiceLocator.ctx.applicationInfo.name)
    this.infoRow(this.t('settings.help'), HELP_EMAIL)
    this.infoRow(this.t('settings.server'), hostOf(ServiceLocator.baseUrl()))
    this.rule()
  }

  @Builder
  eyebrow(title: string) {
    Text(title)
      .fontSize(Tk.Ty.nano)
      .fontColor(Tk.L.fgMuted)
      .margin({ top: Tk.Sp.s6, bottom: Tk.Sp.s3 })
  }

  /** 一行一项：名称在左，值在右。 */
  @Builder
  infoRow(key: string, value: string) {
    Row({ space: Tk.Sp.s3 }) {
      Text(key)
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fg)
      Text(value)
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fgMuted)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .constraintSize({ minHeight: 32 })
    .alignItems(VerticalAlign.Center)
  }

  /** 可点的一行：名称、可选状态、右箭头。 */
  @Builder
  navRow(title: string, value: string, action: () => void) {
    Row({ space: Tk.Sp.s3 }) {
      Text(title)
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fg)
      Text(value)
        .fontSize(Tk.Ty.small)
        .fontColor(Tk.L.fgMuted)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
      Text('›')
        .fontSize(Tk.Ty.body)
        .fontColor(Tk.L.fgFaint)
    }
    .width('100%')
    .height(Tk.touchMin)
    .alignItems(VerticalAlign.Center)
    .onClick(action)
  }

  @Builder
  rule() {
    Divider().color(Tk.L.rule).margin({ top: Tk.Sp.s2 })
  }

  // ---- 行为 ----

  /** 冷启动没有账号信息（会话里只有 sessionId），那就照实显示占位，不去多打一次网络。 */
  private accountName(): string {
    const a: AccountUser | null = AppModel.shared.account
    if (a === null) return DASH
    // 手机号注册的账号可能两个都空：名字位不能空着，至少告诉用户「已登录」
    const name: string = a.displayName.trim().length > 0 ? a.displayName.trim() : a.username.trim()
    return name.length > 0 ? name : this.t('settings.signedIn')
  }

  /** 用户名与显示名不同时才多写一行。 */
  private accountUsername(): string {
    const a: AccountUser | null = AppModel.shared.account
    if (a === null || a.username.trim() === this.accountName()) return ''
    return a.username.trim()
  }

  private syncProject(): void {
    const p: RelayProject | null = AppModel.shared.selectedProject
    this.projectName = p === null ? DASH : p.name
  }

  /** 「已用 / 配额」。满了之后上传会被拒并提示去桌面端收件，这行让用户提前有数。 */
  private async changeBackup(): Promise<void> {
    const session: string | null = await ServiceLocator.session.current()
    if (session === null) return
    const current: BackupConsent = await ServiceLocator.backend.backupConsent()
    if (!this.alive || session !== await ServiceLocator.session.current()) return
    this.backup = await BackupConsentService.choose(this.getUIContext(), current, session, (): boolean => this.alive)
  }

  private pickLanguage(pref: string): void {
    this.showLanguagePicker = false
    ServiceLocator.setLocalePreference(pref).catch((): void => {})
  }

  private credits(cents: number): string {
    return this.t('subscription.credits', { 'amount': (cents / 100).toFixed(2) })
  }

  private persistentCaption(): string {
    const u: MediaUsage | null = this.usage
    if (u === null || u.persistentUsedBytes === undefined) return DASH
    const used: string = formatBytes(u.persistentUsedBytes)
    if (u.persistentQuotaBytes === undefined || u.persistentQuotaAvailable === false) {
      return this.t('settings.quotaUnavailable', { 'used': used })
    }
    return `${used} / ${formatBytes(u.persistentQuotaBytes)}`
  }

  private usageCaption(): string {
    const u: MediaUsage | null = this.usage
    if (u === null) return DASH
    return this.t('settings.usage', { 'used': formatBytes(u.usedBytes), 'quota': formatBytes(u.quotaBytes) })
  }

  private usageFraction(): number {
    const u: MediaUsage | null = this.usage
    if (u === null || u.quotaBytes <= 0) return 0
    const pct: number = (u.usedBytes / u.quotaBytes) * 100
    if (pct < 0) return 0
    return pct > 100 ? 100 : pct
  }

  /** 本端还不能充值时的说明。只有一个「关闭」：这不是待办，是一句去哪儿充的指路。 */
  private async loadPostpaid(accept: boolean = false, resume: boolean = false): Promise<void> {
    if (this.postpaidBusy) return
    this.postpaidBusy = true; this.postpaidError = ''
    const session: string | null = await ServiceLocator.session.current()
    if (session === null) { this.postpaidBusy = false; return }
    try {
      if ((accept || resume) && session !== this.postpaidSession) throw new Error(this.t('files.error.closed'))
      const billing: Record<string, Object> | null = this.postpaid === null ? null : asRecord(this.postpaid['billing'])
      const frozenAccess: Record<string, Object> | null = this.postpaid === null ? null : asRecord(this.postpaid['cloudAccess'])
      const version: string | undefined = (accept || (resume && frozenAccess !== null && frozenAccess['frozen'] === true)) && billing !== null ? billing['policyVersion'] as string : undefined
      if (resume) { invalidateCloudEpoch(); await ServiceLocator.queue.pauseCloudUploads() }
      const value: Record<string, Object> = await ServiceLocator.backend.cloudBillingState(session, version, resume)
      if (this.alive && session === await ServiceLocator.session.current()) { this.postpaid = value; this.postpaidSession = session; if (accept || resume) { await ServiceLocator.backend.reconnectCloud(session) } }
    } catch (_) { if (this.alive) this.postpaidError = this.t('balance.unavailable') }
    finally { if (this.alive) this.postpaidBusy = false }
  }
  private postpaidBilling(): Record<string, Object> | null {
    return this.postpaid === null ? null : asRecord(this.postpaid['billing'])
  }
  private postpaidAccess(): Record<string, Object> | null {
    return this.postpaid === null ? null : asRecord(this.postpaid['cloudAccess'])
  }
  private postpaidDebt(): number {
    const b: Record<string, Object> | null = this.postpaidBilling()
    return b !== null && typeof b['debtCents'] === 'number' ? b['debtCents'] as number : 0
  }
  private formatCash(cents: number, currency: string): string {
    return currency + ' ' + (cents / 100).toFixed(2)
  }
  private postpaidMoney(field: string): string {
    const b: Record<string, Object> | null = this.postpaidBilling()
    if (b === null || typeof b[field] !== 'number') return DASH
    return this.formatCash(b[field] as number, b['cashCurrency'] as string)
  }
  /** 费率单价；没有这一档（如出口价未定）返回空串，调用方不渲染。 */
  private postpaidRate(priceField: string, centsField: string): string {
    const b: Record<string, Object> | null = this.postpaidBilling()
    const price: Record<string, Object> | null = b === null ? null : asRecord(b[priceField])
    if (b === null || price === null || typeof price[centsField] !== 'number') return ''
    return this.formatCash(price[centsField] as number, b['cashCurrency'] as string)
  }
  /** 设置首屏那一行的状态词。读失败给「—」，还在读给空。 */
  private postpaidStatus(): string {
    if (this.postpaidError.length > 0) return DASH
    const b: Record<string, Object> | null = this.postpaidBilling()
    const a: Record<string, Object> | null = this.postpaidAccess()
    if (b === null || a === null) return ''
    if (this.postpaidDebt() > 0) return this.postpaidMoney('debtCents')
    if (b['accepted'] !== true) return this.t('postpaid.status.off')
    return a['canUse'] === true ? this.t('postpaid.status.on') : this.t('postpaid.status.restricted')
  }
  private postpaidStatusAlert(): boolean {
    const b: Record<string, Object> | null = this.postpaidBilling()
    const a: Record<string, Object> | null = this.postpaidAccess()
    if (this.postpaidError.length > 0 || b === null || a === null) return false
    return this.postpaidDebt() > 0 || (b['accepted'] === true && a['canUse'] !== true)
  }
  private canResumeCloud(): boolean {
    const b: Record<string, Object> | null = this.postpaid === null ? null : asRecord(this.postpaid['billing'])
    const a: Record<string, Object> | null = this.postpaid === null ? null : asRecord(this.postpaid['cloudAccess'])
    return b !== null && a !== null && b['accepted'] === true && (a['frozen'] !== true || b['debtCents'] === 0)
  }
  private confirmResumeCloud(): void {
    if (!this.canResumeCloud() || this.postpaidBusy) return
    this.getUIContext().showAlertDialog({title: this.t('postpaid.resume'), message: this.t('postpaid.resumeNotice'),
      primaryButton: {value: this.t('common.cancel'), action: (): void => {}},
      secondaryButton: {value: this.t('postpaid.resume'), action: (): void => { this.loadPostpaid(false, true).catch((): void => {}) }} })
  }
  private canAcceptPostpaid(): boolean {
    const b: Record<string, Object> | null = this.postpaid === null ? null : asRecord(this.postpaid['billing'])
    return billingAvailableIn(ServiceLocator.region) && b !== null && b['accepted'] === false && b['acceptEnabled'] === true && asRecord(b['egressPrice']) !== null
  }
  private confirmPostpaid(): void {
    if (!this.canAcceptPostpaid() || this.postpaidBusy) return
    this.getUIContext().showAlertDialog({title: this.t('postpaid.accept'), message: this.t('postpaid.notice'),
      primaryButton: {value: this.t('common.cancel'), action: (): void => {}},
      secondaryButton: {value: this.t('postpaid.accept'), action: (): void => { this.loadPostpaid(true).catch((): void => {}) }} })
  }

  private openRepayment(): void {
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: 'https://aiworkdeck.com/zh/account#wallet' }
    const ctx: common.UIAbilityContext = ServiceLocator.ctx as common.UIAbilityContext
    ctx.startAbility(want).catch((): void => { toast(this.getUIContext(), this.t('login.webError')) })
  }

  private showRechargeNotice(): void {
    this.getUIContext().showAlertDialog({
      title: this.t('recharge.external.title'),
      message: this.t('recharge.external.body'),
      autoCancel: true,
      confirm: {
        value: this.t('common.close'),
        action: (): void => {},
      },
    })
  }

  /**
   * 不可逆，所以走二次确认；文案把「删什么、不删什么」都说全——
   * 只写「无法恢复」等于没说清代价。
   */
  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({
      title: this.t('settings.deleteAccount.title'),
      message: this.t('settings.deleteAccount.confirm'),
      autoCancel: true,
      primaryButton: {
        value: this.t('common.cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: this.t('settings.deleteAccount'),
        fontColor: Tk.S.failed,
        action: (): void => {
          AppModel.shared.deleteAccount().catch((e: Object): void => {
            toast(this.getUIContext(), errorText(e))
          })
        },
      },
    })
  }
}
