package com.aiworkdeck.mobile
import com.aiworkdeck.mobile.services.*
import com.aiworkdeck.mobile.model.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.io.File
import java.time.Instant
class CloudEpochTest {
 @Test fun offlineDeviceReloadKeepsOldEpochAndOriginalUntilExplicitReconnect() = runBlocking {
  val root=Files.createTempDirectory("epoch-device-b").toFile()
  val store=EvidenceStore(File(root,"evidence"),DeviceFacts("test","test","test"))
  val disk=File(root,"bindings")
  var epoch=3
  val client=OkHttpClient.Builder().addInterceptor { chain ->
   val body=if(chain.request().url.encodedPath=="/api/auth/me") "{\"code\":0,\"data\":{\"id\":41}}" else "{\"cloudAccess\":{\"epoch\":$epoch}}"
   Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody()).build()
  }.build()
  val request=Request.Builder().url("https://addin.aiworkdeck.com/api/mobile/media").header("X-Session-Id","old-session").post("".toRequestBody()).build()
  CloudEpoch.configure(disk,store)
  assertEquals("3",CloudEpoch.authorize(request,client).header("X-Cloud-Epoch"))
  val original=File(root,"original.jpg").apply { writeText("original") }
  val item=store.save(MediaKind.photo,original,Instant.parse("2026-01-01T00:00:00Z"),null,RelayProject(deviceId="dev",deviceName=null,key="project",name="test"))
  epoch=7
  val restarted=EvidenceStore(File(root,"evidence"),DeviceFacts("test","test","test"))
  CloudEpoch.configure(disk,restarted)
  val rotated=request.newBuilder().header("X-Session-Id","new-session").build()
  assertThrows(ApiError::class.java) { CloudEpoch.authorize(rotated,client) }
  assertTrue(restarted.loadAll().single().cloudResumeRequired)
  assertEquals(item.id,restarted.loadAll().single().id)
  assertTrue(disk.listFiles()!!.single().readText()=="3")
  CloudEpoch.configure(disk,restarted)
  assertThrows(ApiError::class.java) { CloudEpoch.authorize(rotated,client) }
  val oldPreparation=CloudEpoch.revision()
  CloudEpoch.reconnect(rotated,client)
  assertThrows(ApiError::class.java) { CloudEpoch.authorize(rotated,client,expectedGeneration=oldPreparation) }
  assertEquals("7",CloudEpoch.authorize(rotated,client).header("X-Cloud-Epoch"))
  assertTrue(restarted.loadAll().single().cloudResumeRequired)
  CloudEpoch.reconnect(rotated,client)
  assertTrue(restarted.loadAll().single().cloudResumeRequired)
  CloudEpoch.configure(File(root,"unbound-account"),restarted)
  assertThrows(ApiError::class.java) { CloudEpoch.authorize(rotated,client) }
  Unit
 }
 @Test fun selectedQueueItemWaitingBeforeAuthorizationCannotUseReconnectedGeneration() = runBlocking {
  val root=Files.createTempDirectory("epoch-selected").toFile()
  val store=EvidenceStore(File(root,"evidence"),DeviceFacts("test","test","test"))
  CloudEpoch.configure(File(root,"binding"),store)
  val request=Request.Builder().url("https://addin.aiworkdeck.com/api/mobile/media").header("X-Session-Id","selected").post("".toRequestBody()).build()
  val client=OkHttpClient.Builder().addInterceptor { chain ->
   val body=if(chain.request().url.encodedPath.endsWith("/auth/me")) "{\"code\":0,\"data\":{\"id\":99}}" else "{\"cloudAccess\":{\"epoch\":4}}"
   Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody()).build()
  }.build()
  CloudEpoch.authorize(request,client)
  store.save(MediaKind.photo,File(root,"original").apply{writeText("keep")},Instant.now(),null,RelayProject(deviceId="d",deviceName=null,key="k",name="p"))
  val selected=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var sent=false
  val uploader=object:Uploader {
   override suspend fun upload(item:CaptureItem,project:RelayProject,fileName:String,onProgress:(Double)->Unit):UploadResult {
    selected.complete(Unit);release.await()
    CloudEpoch.authorize(request,client,expectedGeneration=currentCoroutineContext()[CloudWriteGeneration]?.value)
    sent=true;return UploadResult(code=0,id=1,clientMediaId=item.manifest.clientMediaId,delivered=false)
   }
   override suspend fun mediaStatus(ids:List<String>):List<MediaStatus> = emptyList()
  }
  val queue=UploadQueue(store,uploader)
  val running=async { queue.kick() };selected.await()
  queue.pauseCloudUploads();CloudEpoch.reconnect(request,client);release.complete(Unit);running.await()
  assertFalse(sent);assertTrue(store.loadAll().single().cloudResumeRequired)
 }

}
