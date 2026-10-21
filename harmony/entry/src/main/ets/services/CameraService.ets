import { display } from '@kit.ArkUI'
import { camera } from '@kit.CameraKit'
import { image } from '@kit.ImageKit'
import { media } from '@kit.MediaKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { hasPermission, PERM_MICROPHONE } from './Permissions'
import { ServiceLocator } from './ServiceLocator'

const DOMAIN: number = 0x0000
const TAG: string = 'CameraService'

/** 允许的画幅：4:3 与 16:9。别的比例（1:1、全画幅裁切）在取景器上会与预览对不上。 */
const RATIO_4_3: number = 4 / 3
const RATIO_16_9: number = 16 / 9
const RATIO_TOLERANCE: number = 0.02

/** 竖屏应用：设备自然方向就是 0 度，旋转角由相机自己按传感器安装角算。 */
function deviceDegrees(): number {
  return display.getDefaultDisplaySync().rotation * 90
}

/**
 * 在途拍照被相机拆掉时的失败信息。调用方（取景页）据此把这一次静默处理——
 * 是用户自己退了后台 / 切了档位，不是出错，不该弹吐司。
 */
export const CAMERA_CLOSED: string = 'camera closed'

/** 这次失败是不是「相机被拆」。 */
export function isCameraClosed(e: Object): boolean {
  return e instanceof Error && (e as Error).message === CAMERA_CLOSED
}

/**
 * 相机会话。镜像安卓 `CameraService.kt` 与 iOS `CameraService`：照片 JPEG 直出、录像 MP4，
 * 两者都落到 cacheDir 的临时文件，由 `AppModel.store` 接手搬进证据库。
 *
 * **不做二次编码、不改 EXIF**：照片的 SHA-256 要证明的是「相机吐出来的那一份」没被动过，
 * 中间任何一次重新压缩都会让哈希与「原始采集」这四个字脱钩（决策 D3，与 iOS / 安卓同）。
 *
 * 会话结构（d.ts 依据都写在调用处）：常态是 `PhotoSession`（`SceneMode.NORMAL_PHOTO`），
 * 预览 + 拍照两路输出；只有真的按下录像键时才拆掉它、按 `VideoSession`
 * （`SceneMode.NORMAL_VIDEO`）重建预览 + 录像两路，停录后再换回来。
 * 这样切档位（照片 ⇄ 录像的 Pill）根本不动会话——画面不黑、按下快门就能拍；
 * 只有「开始录像」这一次要等重建，而开录本来就不是瞬时动作。
 *
 * 录像的写文件不归相机管：`VideoOutput` 只是把帧灌进 `AVRecorder` 的输入 surface
 * （`AVRecorder.getInputSurface()`，`@ohos.multimedia.media.d.ts:5315`），编码与封装是录制器的事。
 */
export class CameraService {
  /** 录像进行中。界面据此把快门画成红方块。 */
  isRecordingVideo: boolean = false
  /** 开录的墙钟时刻。落库的采集时刻取它——「什么时候开始录」比「什么时候按停」重要。 */
  videoStartedAt: number = 0

  private manager: camera.CameraManager | null = null
  private device: camera.CameraDevice | null = null
  private input: camera.CameraInput | null = null
  private session: camera.Session | null = null
  private preview: camera.PreviewOutput | null = null
  private photo: camera.PhotoOutput | null = null
  private videoOut: camera.VideoOutput | null = null
  private recorder: media.AVRecorder | null = null
  private videoFile: fs.File | null = null
  private videoPath: string = ''

  private surfaceId: string = ''

  /** 一次拍照的等待者。相机把照片经 `photoAvailable` 事件送回来，不是 `capture()` 的返回值。 */
  private pendingPhoto: ((path: string) => void) | null = null
  private pendingPhotoFail: ((e: Object) => void) | null = null
  /** 串行锁：open / close / 开录 / 停录 不能交叉，交叉就是「会话建到一半又被拆」。 */
  private chain: Promise<void> = Promise.resolve()

  // MARK: - 会话

  /**
   * 打开相机并把预览接到 XComponent 的 surface 上。可重入：同一个 surface 再调一次直接返回
   * （页面重画、权限回调都会再调一次）。
   */
  async open(surfaceId: string): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      if (this.session !== null && this.surfaceId === surfaceId) return
      if (this.session !== null) await this.teardown()
      this.surfaceId = surfaceId
      try { await this.openPhotoSession() } catch (e) {
        await this.teardown()
        throw e as Error
      }
      this.updatePreviewRotation()
    })
  }

  /**
   * 放开相机。幂等。`surfaceId` 在排队之前就清掉：还排在前面的 `stopVideo` 看到它是空的
   * 就不会再把拍照会话开回来——那一次开完马上又要被这里拆掉，纯属白费。
   */
  async close(): Promise<void> {
    this.surfaceId = ''
    // 在排队之前就把在途的那一张回收掉：这条链上还排着别的活时，等着拿照片的人
    // 不该被吊到链走完，而回前台后也不能留一个非空的 pendingPhoto 把快门锁死
    this.abortPendingPhoto()
    await this.run<void>(async (): Promise<void> => {
      await this.teardown()
    })
  }

  updatePreviewRotation(): void {
    const preview: camera.PreviewOutput | null = this.preview
    if (preview === null) return
    try { preview.setPreviewRotation(preview.getPreviewRotation(deviceDegrees()), true) } catch (e) {
      hilog.warn(DOMAIN, TAG, 'preview rotation failed: %{public}s', messageOf(e))
    }
  }

  // MARK: - 拍照

  /**
   * 拍一张，返回 cacheDir 里的 JPEG 原件路径。
   *
   * `PhotoOutput.capture(setting)`（`@ohos.multimedia.camera.d.ts:5739`）只负责触发，
   * 照片从 `on('photoAvailable')`（同上 :5776）回来：`Photo.main` 是 `image.Image`（:5600），
   * `getComponent(ComponentType.JPEG)`（`@ohos.multimedia.image.d.ts:13266`）出
   * `Component.byteBuffer`（同上 :3401）这段 JPEG 字节，直接写盘，不解码不重编。
   */
  async takePhoto(): Promise<string> {
    const out: camera.PhotoOutput | null = this.photo
    if (out === null) throw new Error('camera is not open')
    if (this.pendingPhoto !== null) throw new Error('a capture is already in flight')
    const waiter: Promise<string> = new Promise<string>((resolve: (p: string) => void,
      reject: (e: Object) => void): void => {
      this.pendingPhoto = resolve
      this.pendingPhotoFail = reject
    })
    // 竖屏应用固定按设备 0 度算旋转；传感器装配角由系统补（d.ts:6197）
    const setting: camera.PhotoCaptureSetting = { rotation: out.getPhotoRotation(deviceDegrees()) }
    try {
      await out.capture(setting)
    } catch (e) {
      this.pendingPhoto = null
      this.pendingPhotoFail = null
      throw e as Error
    }
    return await waiter
  }

  // MARK: - 录像

  /**
   * 开始录像。拆掉拍照会话，按 `VideoSession` 重建：录制器先 `prepare` 才拿得到输入 surface，
   * 而 `VideoOutput` 又要拿这个 surface 才建得出来，所以顺序是
   * 录制器 → surface → VideoOutput → 会话 → 两边 start。
   */
  async startVideo(): Promise<void> {
    await this.run<void>(async (): Promise<void> => {
      if (this.isRecordingVideo) return
      if (this.surfaceId.length === 0) throw new Error('camera is not open')
      await this.teardownSession()
      try {
        await this.openVideoSession()
      } catch (e) {
        // 建不起来就把拍照会话还回去，别让用户对着一块黑屏
        hilog.error(DOMAIN, TAG, 'startVideo failed: %{public}s', messageOf(e))
        await this.teardownSession()
        // 建到一半的那个 mp4 里什么都没有，留着只会在 cacheDir 里当孤儿
        // （`EvidenceStore.sweepOrphans` 只扫证据目录，扫不到这里）
        this.removeVideoFile()
        await this.openPhotoSession()
        throw e as Error
      }
      this.isRecordingVideo = true
      this.videoStartedAt = Date.now()
      hilog.info(DOMAIN, TAG, '%{public}s', 'video recording started')
    })
  }

  /**
   * 停止录像，返回 cacheDir 里的 MP4。停完把拍照会话换回来。
   *
   * 出错也先看文件：退后台收尾会报错，但已录的部分是完好的，现场不可复现，能留多少留多少。
   */
  async stopVideo(): Promise<string> {
    // 标志同步落下再排队：退后台与页面销毁会前后脚各喊一次停，让第二次当场返回，
    // 而不是排到队里去撞一条「已经没有录像了」的错
    if (!this.isRecordingVideo) throw new Error('no recording in progress')
    this.isRecordingVideo = false
    this.videoStartedAt = 0
    return await this.run<string>(async (): Promise<string> => {
      const path: string = this.videoPath
      // 交出去之后这条路径就不再归相机管了：留着它，下一次开录半途失败时
      // `removeVideoFile()` 会照着这个陈旧路径去删上一段录像
      this.videoPath = ''
      await this.teardownSession()
      if (this.surfaceId.length > 0) {
        try {
          await this.openPhotoSession()
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'reopen photo session failed: %{public}s', messageOf(e))
        }
      }
      if (path.length === 0) throw new Error('video file missing')
      return path
    })
  }

  // MARK: - 内部：会话装配

  private async openPhotoSession(): Promise<void> {
    const mgr: camera.CameraManager = this.ensureManager()
    const device: camera.CameraDevice = this.ensureDevice(mgr)
    // getSupportedOutputCapability(camera, mode)：d.ts:451（不带 mode 的那条已废弃）
    const caps: camera.CameraOutputCapability =
      mgr.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO)
    const previewProfile: camera.Profile = pickPreview(caps.previewProfiles)
    const photoProfile: camera.Profile = pickByRatio(caps.photoProfiles, ratioOf(previewProfile.size))

    const input: camera.CameraInput = mgr.createCameraInput(device)   // d.ts:498
    await input.open()                                               // d.ts:1407
    const preview: camera.PreviewOutput = mgr.createPreviewOutput(previewProfile, this.surfaceId)  // d.ts:537
    const photo: camera.PhotoOutput = mgr.createPhotoOutput(photoProfile)                          // d.ts:588
    photo.on('photoAvailable', (err: BusinessError, p: camera.Photo): void => {
      this.onPhotoAvailable(err, p)
    })

    const session: camera.PhotoSession = mgr.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO)  // d.ts:666
    this.input = input
    this.preview = preview
    this.photo = photo
    this.session = session
    session.beginConfig()          // d.ts:3272
    session.addInput(input)        // d.ts:3324
    session.addOutput(preview)     // d.ts:3365
    session.addOutput(photo)
    await session.commitConfig()   // d.ts:3298
    await session.start()          // d.ts:3404
    hilog.info(DOMAIN, TAG, '%{public}s', 'photo session started')
  }

  private async openVideoSession(): Promise<void> {
    const mgr: camera.CameraManager = this.ensureManager()
    const device: camera.CameraDevice = this.ensureDevice(mgr)
    const caps: camera.CameraOutputCapability =
      mgr.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_VIDEO)
    const previewProfile: camera.Profile = pickPreview(caps.previewProfiles)
    const videoProfile: camera.VideoProfile = pickVideo(caps.videoProfiles, ratioOf(previewProfile.size))

    // 1. 录制器先备好，它的输入 surface 是 VideoOutput 的落点
    const dir: string = ServiceLocator.ctx.cacheDir
    const path: string = `${dir}/video-${util.generateRandomUUID(false).toLowerCase()}.mp4`
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
    this.videoFile = file
    this.videoPath = path
    const recorder: media.AVRecorder = await media.createAVRecorder()
    this.recorder = recorder

    const input: camera.CameraInput = mgr.createCameraInput(device)
    await input.open()
    const preview: camera.PreviewOutput = mgr.createPreviewOutput(previewProfile, this.surfaceId)
    this.input = input
    this.preview = preview

    const withAudio: boolean = this.hasMic()
    const profile: media.AVRecorderProfile = videoRecorderProfile(videoProfile, withAudio)
    const config: media.AVRecorderConfig = withAudio ? {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
      videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,   // d.ts:7224
      profile: profile,
      url: `fd://${file.fd}`,
    } : {
      // 没有麦克风权限也照录（只是没声）：现场画面本身就是证据，不因为少一项权限把画面也拒了
      videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,
      profile: profile,
      url: `fd://${file.fd}`,
    }
    await recorder.prepare(config)
    const videoSurfaceId: string = await recorder.getInputSurface()            // d.ts:5315
    const videoOut: camera.VideoOutput = mgr.createVideoOutput(videoProfile, videoSurfaceId)  // d.ts:610
    this.videoOut = videoOut
    await recorder.updateRotation(videoOut.getVideoRotation(deviceDegrees()))

    const session: camera.VideoSession = mgr.createSession<camera.VideoSession>(camera.SceneMode.NORMAL_VIDEO)
    this.session = session
    session.beginConfig()
    session.addInput(input)
    session.addOutput(preview)
    session.addOutput(videoOut)
    await session.commitConfig()
    await session.start()
    await videoOut.start()      // d.ts:6347
    await recorder.start()
  }

  /**
   * 拆会话与输出。每一步都单独兜错：拆到一半抛出去会把引用留在半死状态，
   * 下一次 open 就会撞上一个「还占着相机」的旧会话。
   */
  private async teardownSession(): Promise<void> {
    // 输出一旦释放，photoAvailable 就再也不会回来了；在途的等待者必须当场了结，
    // 否则这张照片静默丢失，而 pendingPhoto 留着非空会让之后每一次快门直接抛错
    this.abortPendingPhoto()
    const recorder: media.AVRecorder | null = this.recorder
    const videoOut: camera.VideoOutput | null = this.videoOut
    const session: camera.Session | null = this.session
    const preview: camera.PreviewOutput | null = this.preview
    const photo: camera.PhotoOutput | null = this.photo
    const input: camera.CameraInput | null = this.input
    const file: fs.File | null = this.videoFile
    this.recorder = null
    this.videoOut = null
    this.session = null
    this.preview = null
    this.photo = null
    this.input = null
    this.videoFile = null

    if (recorder !== null) {
      await quiet('recorder.stop', async (): Promise<void> => {
        await recorder.stop()
      })
      await quiet('recorder.release', async (): Promise<void> => {
        await recorder.release()
      })
    }
    if (videoOut !== null) {
      await quiet('videoOutput.stop', async (): Promise<void> => {
        await videoOut.stop()
      })
      await quiet('videoOutput.release', async (): Promise<void> => {
        await videoOut.release()
      })
    }
    if (session !== null) {
      await quiet('session.stop', async (): Promise<void> => {
        await session.stop()
      })
      await quiet('session.release', async (): Promise<void> => {
        await session.release()
      })
    }
    if (photo !== null) {
      photo.off('photoAvailable')
      await quiet('photoOutput.release', async (): Promise<void> => {
        await photo.release()
      })
    }
    if (preview !== null) {
      await quiet('previewOutput.release', async (): Promise<void> => {
        await preview.release()
      })
    }
    if (input !== null) {
      await quiet('cameraInput.close', async (): Promise<void> => {
        await input.close()
      })
    }
    if (file !== null) {
      try {
        fs.closeSync(file)
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close video fd failed: %{public}s', messageOf(e))
      }
    }
  }

  private async teardown(): Promise<void> {
    this.isRecordingVideo = false
    this.videoStartedAt = 0
    await this.teardownSession()
    this.videoPath = ''
    hilog.info(DOMAIN, TAG, '%{public}s', 'camera closed')
  }

  // MARK: - 内部：收尾

  /** 回收在途拍照的等待者。幂等：没有在途的直接返回。 */
  private abortPendingPhoto(): void {
    const reject: ((e: Object) => void) | null = this.pendingPhotoFail
    this.pendingPhoto = null
    this.pendingPhotoFail = null
    if (reject === null) return
    hilog.info(DOMAIN, TAG, '%{public}s', 'pending capture aborted')
    reject(new Error(CAMERA_CLOSED))
  }

  /** 删掉还没录出内容的临时 mp4，并把路径清空。 */
  private removeVideoFile(): void {
    const path: string = this.videoPath
    this.videoPath = ''
    if (path.length === 0) return
    try {
      fs.unlinkSync(path)
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'unlink empty video failed: %{public}s', messageOf(e))
    }
  }

  // MARK: - 内部：照片回调

  private onPhotoAvailable(err: BusinessError, p: camera.Photo): void {
    const resolve: ((path: string) => void) | null = this.pendingPhoto
    const reject: ((e: Object) => void) | null = this.pendingPhotoFail
    this.pendingPhoto = null
    this.pendingPhotoFail = null
    if (err !== undefined && err !== null && err.code !== 0) {
      hilog.error(DOMAIN, TAG, 'photoAvailable error %{public}d', err.code)
      if (reject !== null) reject(err)
      return
    }
    this.writePhoto(p).then((path: string): void => {
      if (resolve !== null) resolve(path)
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'write photo failed: %{public}s', messageOf(e))
      if (reject !== null) reject(e)
    })
  }

  private async writePhoto(p: camera.Photo): Promise<string> {
    const img: image.Image = p.main
    let path: string = ''
    try {
      const comp: image.Component = await img.getComponent(image.ComponentType.JPEG)
      const buffer: ArrayBuffer = comp.byteBuffer
      path = `${ServiceLocator.ctx.cacheDir}/photo-${util.generateRandomUUID(false).toLowerCase()}.jpg`
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      try {
        fs.writeSync(file.fd, buffer)
      } finally {
        fs.closeSync(file)
      }
    } finally {
      await quiet('photo.release', async (): Promise<void> => {
        await p.release()
      })
    }
    return path
  }

  // MARK: - 内部：小工具

  private ensureManager(): camera.CameraManager {
    const cached: camera.CameraManager | null = this.manager
    if (cached !== null) return cached
    const mgr: camera.CameraManager = camera.getCameraManager(ServiceLocator.ctx)   // d.ts:46
    this.manager = mgr
    return mgr
  }

  /** 后置镜头。取证要的是「镜头对着的现场」，前置没有意义；真没有后置就退回第一颗。 */
  private ensureDevice(mgr: camera.CameraManager): camera.CameraDevice {
    const cached: camera.CameraDevice | null = this.device
    if (cached !== null) return cached
    const devices: camera.CameraDevice[] = mgr.getSupportedCameras()   // d.ts:418
    if (devices.length === 0) throw new Error('no camera on this device')
    let picked: camera.CameraDevice = devices[0]
    for (const d of devices) {
      if (d.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        picked = d
        break
      }
    }
    this.device = picked
    return picked
  }

  private hasMic(): boolean {
    return hasPermission(PERM_MICROPHONE)
  }

  private run<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.chain.then(work)
    this.chain = result.then((): void => {}, (): void => {})
    return result
  }
}

// MARK: - 画幅与档位

function ratioOf(size: camera.Size): number {
  const long: number = size.width >= size.height ? size.width : size.height
  const short: number = size.width >= size.height ? size.height : size.width
  return short === 0 ? 0 : long / short
}

function isStandardRatio(r: number): boolean {
  return Math.abs(r - RATIO_4_3) < RATIO_TOLERANCE || Math.abs(r - RATIO_16_9) < RATIO_TOLERANCE
}

function pixels(size: camera.Size): number {
  return size.width * size.height
}

/** 预览取 4:3 / 16:9 里最大的一档；一档都没有就退回最大的那个，宁可画幅怪也要有画面。 */
function pickPreview(profiles: camera.Profile[]): camera.Profile {
  if (profiles.length === 0) throw new Error('no preview profile')
  let best: camera.Profile | null = null
  for (const p of profiles) {
    if (!isStandardRatio(ratioOf(p.size))) continue
    if (best === null || pixels(p.size) > pixels(best.size)) best = p
  }
  if (best !== null) return best
  let fallback: camera.Profile = profiles[0]
  for (const p of profiles) if (pixels(p.size) > pixels(fallback.size)) fallback = p
  return fallback
}

/** 与预览同比例里最大的一档：画幅不一致的话取景框里看到的和拍下来的不是同一块地方。 */
function pickByRatio(profiles: camera.Profile[], ratio: number): camera.Profile {
  if (profiles.length === 0) throw new Error('no photo profile')
  let best: camera.Profile | null = null
  for (const p of profiles) {
    if (Math.abs(ratioOf(p.size) - ratio) >= RATIO_TOLERANCE) continue
    if (best === null || pixels(p.size) > pixels(best.size)) best = p
  }
  if (best !== null) return best
  let fallback: camera.Profile = profiles[0]
  for (const p of profiles) if (pixels(p.size) > pixels(fallback.size)) fallback = p
  return fallback
}

function pickVideo(profiles: camera.VideoProfile[], ratio: number): camera.VideoProfile {
  if (profiles.length === 0) throw new Error('no video profile')
  let best: camera.VideoProfile | null = null
  for (const p of profiles) {
    if (Math.abs(ratioOf(p.size) - ratio) >= RATIO_TOLERANCE) continue
    if (best === null || pixels(p.size) > pixels(best.size)) best = p
  }
  if (best !== null) return best
  let fallback: camera.VideoProfile = profiles[0]
  for (const p of profiles) if (pixels(p.size) > pixels(fallback.size)) fallback = p
  return fallback
}

/**
 * 录制参数。码率按像素定（约 4 bit/像素·秒 的量级）：固定码率在 720p 上浪费、在 4K 上糊，
 * 而现场录像的分辨率随机器变。帧率取该档支持的上限但不超过 30——取证不需要高帧率，
 * 文件小一半更要紧。
 */
function videoRecorderProfile(vp: camera.VideoProfile, withAudio: boolean): media.AVRecorderProfile {
  const fps: number = vp.frameRateRange.max < 30 ? vp.frameRateRange.max : 30
  if (!withAudio) {
    const silent: media.AVRecorderProfile = {
      fileFormat: media.ContainerFormatType.CFT_MPEG_4,          // media.d.ts:6864
      videoCodec: media.CodecMimeType.VIDEO_AVC,                 // media.d.ts:7782
      videoBitrate: Math.round(vp.size.width * vp.size.height * 4),
      videoFrameWidth: vp.size.width,
      videoFrameHeight: vp.size.height,
      videoFrameRate: fps,
    }
    return silent
  }
  const withSound: media.AVRecorderProfile = {
    fileFormat: media.ContainerFormatType.CFT_MPEG_4,
    videoCodec: media.CodecMimeType.VIDEO_AVC,
    videoBitrate: Math.round(vp.size.width * vp.size.height * 4),
    videoFrameWidth: vp.size.width,
    videoFrameHeight: vp.size.height,
    videoFrameRate: fps,
    audioBitrate: 64000,
    audioChannels: 1,
    audioCodec: media.CodecMimeType.AUDIO_AAC,
    audioSampleRate: 44100,
  }
  return withSound
}

async function quiet(what: string, work: () => Promise<void>): Promise<void> {
  try {
    await work()
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}s', what, messageOf(e))
  }
}

function messageOf(e: Object): string {
  if (e instanceof Error) {
    const err: Error = e as Error
    return err.message.length > 0 ? err.message : err.name
  }
  return `${e}`
}
