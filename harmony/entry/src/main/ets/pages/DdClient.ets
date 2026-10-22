// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { webview } from '@kit.ArkWeb'
import { camera, cameraPicker } from '@kit.CameraKit'
import { picker } from '@kit.CoreFileKit'
import { ContractCapabilities } from 'contract'
import { tr } from '../design/L10n'
import { Tk } from '../design/Tokens'

@Component
export struct DdClient {
  stack: NavPathStack = new NavPathStack()
  private controller: webview.WebviewController = new webview.WebviewController()
  build() {
    NavDestination() {
      Web({ src: ContractCapabilities.ddClientPortalUrl, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onShowFileSelector((event): boolean => {
          if (!event) return false
          if (event.fileSelector.isCapture()) {
            const context = this.getUIContext().getHostContext()
            if (!context) { event.result.handleFileList([]); return true }
            cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK })
              .then((result: cameraPicker.PickerResult): void => { event.result.handleFileList(result.resultCode === 0 ? [result.resultUri] : []) })
              .catch((): void => { event.result.handleFileList([]) })
            return true
          }
          const filePicker = new picker.DocumentViewPicker()
          filePicker.select({ maxSelectNumber: 20 }).then((uris: string[]): void => {
            event.result.handleFileList(uris)
          }).catch((): void => { event.result.handleFileList([]) })
          return true
        })
        .width('100%').height('100%')
    }
    .title(tr('dd.title'))
    .backgroundColor(Tk.L.bg)
  }
}
