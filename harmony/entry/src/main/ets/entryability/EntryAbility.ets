import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import BuildProfile from 'BuildProfile';
import { AppModel } from '../AppModel';
import { RelayProject } from '../model/Capture';
import { ServiceLocator } from '../services/ServiceLocator';
import { ScreenshotMode } from '../ScreenshotMode';

const DOMAIN: number = 0x0000;

/** 走查种子的启动参数名与值：`aa start ... --ps awdSeed 1`。 */
const SEED_PARAM: string = 'awdSeed';
const SEED_ON: string = '1';

export default class EntryAbility extends UIAbility {
  /** 走查种子的落盘过程；不种子时为 null，正常启动一步不多走。 */
  private seeding: Promise<void> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 装配在这里而不是页面里：后台上传任务与录音服务（Task 5）都要拿同一批实例，
    // 装配两遍就等于两条互不知情的队列。
    ServiceLocator.init(this.context);
    this.calendarNotification(want);
    // 上架截图模式（debug-only，见 ScreenshotMode）。必须在上界面之前定下来。
    ScreenshotMode.configure(want);
    this.seeding = ScreenshotMode.enabled
      ? ScreenshotMode.seed(this.context)
      : this.seedDebugProject(want);
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility onCreate');
  }

  /**
   * 走查用的本地项目种子——**只在 debug 构建里存在**，release 的 `BuildProfile.DEBUG`
   * 为 false，整段直接返回。
   *
   * 为什么要它：审核账号没有配套桌面端，项目列表是空态，走查走不进取景器。
   * iOS 用启动参数 `-AWDScreenshotMode`、安卓用 `run-as` 往 prefs 里灌一条同值的假项目；
   * 鸿蒙的 `hdc shell` 是 uid 2000，写不进应用沙盒，所以这一端改从启动参数进来：
   *
   *   hdc shell aa start -a EntryAbility -b com.aiworkdeck.mobile.huawei --ps awdSeed 1
   *
   * 只写「当前项目」这一个偏好，不碰会话——登录仍然是真实的服务端会话。
   */
  private seedDebugProject(want: Want): Promise<void> | null {
    if (!BuildProfile.DEBUG) return null;
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) return null;
    const raw: Object | undefined = params[SEED_PARAM];
    if (typeof raw !== 'string' || (raw as string) !== SEED_ON) return null;
    // 与安卓 README 的灌数据同值，跨端走查看到的是同一条假项目
    const seed: RelayProject = {
      deviceId: 'dev-emulator',
      deviceName: 'MacBook Pro',
      key: '1',
      name: '走查项目'
    };
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility seeding debug project');
    return ServiceLocator.prefs.setSelectedProject(seed);
  }

  private calendarNotification(want: Want): void {
    const eventId: Object | undefined = want.parameters?.['calendarEventId'];
    if (typeof eventId === 'string') AppStorage.setOrCreate<string>('personalCalendarEventId', eventId as string);
  }
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void { this.calendarNotification(want); }

  onDestroy(): void {
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 种子必须先落盘再上界面：`AppModel.bootstrap()` 在 Root 的 aboutToAppear 里读偏好，
    // 不等就是一场看谁先跑完的赛跑，赢面还在 bootstrap 那边。
    const seeding: Promise<void> | null = this.seeding;
    if (seeding === null) {
      this.loadRoot(windowStage);
      return;
    }
    this.seeding = null;
    seeding
      .then((): void => this.loadRoot(windowStage))
      .catch((e: Object): void => {
        hilog.error(DOMAIN, 'workdeck', 'seed failed: %{public}s', `${e}`);
        this.loadRoot(windowStage);
      });
  }

  private loadRoot(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Root', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'workdeck', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility onWindowStageDestroy');
  }

  /** 回到前台：磁盘可能被后台上传任务改过，队列也可能停在半路（AppModel 自己判断有没有启动过）。 */
  onForeground(): void {
    AppModel.shared.onForeground();
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility onForeground');
  }

  /**
   * 退到后台。**不停录音**——录音靠 AUDIO_RECORDING 长时任务在后台继续，这正是 #407 要的。
   * 相机与录像要停：摄像头在后台留不住，AppModel 把这件事广播给取景页去做。
   */
  onBackground(): void {
    AppModel.shared.onBackground();
    hilog.info(DOMAIN, 'workdeck', '%{public}s', 'EntryAbility onBackground');
  }
}
