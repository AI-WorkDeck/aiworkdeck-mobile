import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  AccountRegion, DEFAULT_REGION, LoginMethod,
  accountFlowUrl, appLanguageOf, baseUrlOf, billingAvailableIn, defaultLoginMethodOf, localeOf, loginMethodsOf,
  regionFromStored, regionLabelKey, switchRegion,
} from '../../harmony/entry/src/main/ets/model/AccountRegion.ets'
import { L10n, LOCALE_EN, LOCALE_ZH, tr, trIn } from '../../harmony/entry/src/main/ets/design/L10n.ets'
import { ContractStrings } from '../../harmony/contract/src/main/ets/Strings.ets'

test('缺省是大陆：没存过（存量已登录用户）走 cn', () => {
  assert.equal(DEFAULT_REGION, AccountRegion.cn)
  assert.equal(regionFromStored(null), AccountRegion.cn)
  assert.equal(regionFromStored(''), AccountRegion.cn)
})

test('已存的值原样读回', () => {
  assert.equal(regionFromStored('cn'), AccountRegion.cn)
  assert.equal(regionFromStored('intl'), AccountRegion.intl)
})

test('坏值回缺省，不把人锁在登录页外', () => {
  assert.equal(regionFromStored('INTL'), AccountRegion.cn)
  assert.equal(regionFromStored('global'), AccountRegion.cn)
})

test('主机映射：cn → aiworkdeck.com，intl → workdeck.ai', () => {
  assert.equal(baseUrlOf(AccountRegion.cn), 'https://addin.aiworkdeck.com')
  assert.equal(baseUrlOf(AccountRegion.intl), 'https://addin.workdeck.ai')
})

test('按区域可用的登录方式：大陆手机号+邮箱，国际只有邮箱', () => {
  assert.deepEqual(loginMethodsOf(AccountRegion.cn), [LoginMethod.phone, LoginMethod.email])
  assert.deepEqual(loginMethodsOf(AccountRegion.intl), [LoginMethod.email])
  assert.equal(defaultLoginMethodOf(AccountRegion.cn), LoginMethod.phone)
  assert.equal(defaultLoginMethodOf(AccountRegion.intl), LoginMethod.email)
})

test('计费入口只在大陆区', () => {
  assert.equal(billingAvailableIn(AccountRegion.cn), true)
  assert.equal(billingAvailableIn(AccountRegion.intl), false)
})

test('区域名称走契约键且键存在', () => {
  assert.equal(regionLabelKey(AccountRegion.cn), 'login.region.cn')
  assert.equal(regionLabelKey(AccountRegion.intl), 'login.region.intl')
  for (const k of ['login.region.cn', 'login.region.intl', 'login.region.intlHint', 'settings.region']) {
    assert.ok(ContractStrings[k] !== undefined, k)
  }
})

test('语言跟随区域：大陆 zh-Hans / zh-CN，海外 en / en-US', () => {
  assert.equal(localeOf(AccountRegion.cn), LOCALE_ZH)
  assert.equal(localeOf(AccountRegion.intl), LOCALE_EN)
  assert.equal(appLanguageOf(AccountRegion.cn), 'zh-CN')
  assert.equal(appLanguageOf(AccountRegion.intl), 'en-US')
  // 缺省区域（存量用户）仍是中文界面
  assert.equal(localeOf(regionFromStored(null)), LOCALE_ZH)
})

test('tr 跟随 L10n.locale：切到海外版当场出英文，切回中文', () => {
  const saved = L10n.locale
  try {
    L10n.locale = localeOf(AccountRegion.intl)
    assert.equal(tr('login.region.intl'), 'Global')
    assert.equal(tr(regionLabelKey(AccountRegion.cn)), 'China')
    L10n.locale = localeOf(AccountRegion.cn)
    assert.equal(tr('login.region.intl'), '海外版')
    assert.equal(tr('login.region.cn'), '大陆版')
  } finally {
    L10n.locale = saved
  }
})

test('trIn：指定语言取值、占位替换、缺译文回落中文、缺键回显', () => {
  assert.equal(trIn(LOCALE_EN, 'delete.title', { n: 3 }).includes('3'), true)
  assert.notEqual(trIn(LOCALE_EN, 'delete.title', { n: 3 }), trIn(LOCALE_ZH, 'delete.title', { n: 3 }))
  assert.equal(trIn('fr', 'login.region.cn'), '大陆版')
  assert.equal(trIn(LOCALE_EN, 'no.such.key'), 'no.such.key')
})

class FakeSink {
  region: string = 'cn'
  stored: string | null = null
  project: string | null = 'dev-1:p-1'
  calls: string[] = []
  applyRegion(r: AccountRegion): void { this.region = r; this.calls.push('apply') }
  async clearSelectedProject(): Promise<void> { this.project = null; this.calls.push('clearProject') }
  async persistRegion(r: AccountRegion): Promise<void> { this.stored = r; this.calls.push('persist') }
}

test('换区清掉本机记着的当前项目：登录另一区不会落到上一区的项目', async () => {
  const sink = new FakeSink()
  assert.equal(await switchRegion(AccountRegion.cn, AccountRegion.intl, sink), true)
  assert.equal(sink.project, null)
  assert.equal(sink.region, AccountRegion.intl)
  assert.equal(sink.stored, AccountRegion.intl)
  // 内存先换：紧接着的发码请求必须已经打新主机
  assert.equal(sink.calls[0], 'apply')
})

test('同区重复点不动任何存储（不误清当前项目）', async () => {
  const sink = new FakeSink()
  assert.equal(await switchRegion(AccountRegion.cn, AccountRegion.cn, sink), false)
  assert.equal(sink.project, 'dev-1:p-1')
  assert.deepEqual(sink.calls, [])
})

test('website flow carries legacy email intent only for CN email and no entered identity', () => {
  for (const flow of ['register', 'reset']) {
    assert.equal(accountFlowUrl(AccountRegion.cn, LoginMethod.email, flow), `https://aiworkdeck.com/zh/account?flow=${flow}&legacyEmail=1`)
    assert.equal(accountFlowUrl(AccountRegion.cn, LoginMethod.phone, flow), `https://aiworkdeck.com/zh/account?flow=${flow}`)
    assert.equal(accountFlowUrl(AccountRegion.intl, LoginMethod.email, flow), `https://workdeck.ai/en/account?flow=${flow}`)
  }
  assert.equal(accountFlowUrl(AccountRegion.cn, LoginMethod.email, 'reset&email=private@example.invalid'),
    'https://aiworkdeck.com/zh/account?flow=register&legacyEmail=1')
  assert.match(trIn(LOCALE_ZH, 'login.legacyEmailHint'), /验证手机号.*验证原邮箱.*保留原手机端数据/)
  assert.match(trIn(LOCALE_EN, 'login.legacyEmailHint'), /verify a phone number.*verify your original email.*keep your mobile data/)
})
