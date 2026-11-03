// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
package com.aiworkdeck.mobile
import com.aiworkdeck.mobile.services.*
import com.aiworkdeck.mobile.model.*
import com.aiworkdeck.mobile.features.personal.PersonalWorkspaceState
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class PersonalDesktopCopyTest {
    private val source = "65ef7d42-15a8-4c26-a781-12b146662a5b"
    private val uid = "bd62e8ac-93fc-421c-9a42-caf54052d875"
    private fun target() = PersonalCopyDestination(RelayProject("cloud",null,"999","Formal",UUID.randomUUID().toString()),
        ProjectLocation("desktop","desktop-a","17",deviceName="Mac",online=false,projectUid=uid,projectType="BLANK",owned=true))
    private fun receipt(request: DesktopCopyRequest,status: String="QUEUED") = DesktopCopyReceipt(request.requestId,status,true,false,
        request.sourceConversationId,UUID.randomUUID().toString(),request.targetProjectUid,request.targetDeviceId,request.targetProjectKey,2,"2026-12-01T00:00:00Z")
    private fun response(value: DesktopCopyReceipt) = MockResponse().setBody("{\"code\":0,\"data\":"+Json.encodeToString(value)+"}")
    @Test fun contractReceiptsDecodeAndValidateAllStatuses() {
        val values=Json.parseToJsonElement(File("../../contract/fixtures/desktop-copy.json").readText()).jsonObject.getValue("receipts").jsonArray
        val receipts=values.map { Json.decodeFromJsonElement<DesktopCopyReceipt>(it) }
        assertEquals(setOf("QUEUED","DELIVERED","EXPIRED","FAILED"),receipts.map { it.status }.toSet())
        receipts.forEach { it.validate(it.request) }
        assertFalse(PersonalDesktopCopy(receipts[0].request,receipts[0]).canRetry)
        assertTrue(PersonalDesktopCopy(receipts[0].request).canRetry)
    }
    @Test fun destinationUsesEachDeviceProofNotMergedCatalogUidOrNumericCloudKey() {
        val loc=target().desktop!!
        val project=target().project.copy(locations=listOf(ProjectLocation("cloud","cloud","999"),loc,loc.copy(deviceId="desktop-b",key="88",projectUid=UUID.randomUUID().toString())))
        val options=PersonalCopyDestination.targets(listOf(project))
        assertEquals(3,options.size);assertEquals(uid,options[1].desktop!!.projectUid)
        assertEquals("17",options[1].desktop!!.key);assertNotEquals(project.projectUid,options[1].desktop!!.projectUid)
        assertFalse(PersonalCopyDestination.eligible(loc.copy(owned=null)));assertFalse(PersonalCopyDestination.eligible(loc.copy(projectType="SCRATCH")))
        assertFalse(PersonalCopyDestination.eligible(loc.copy(projectType="LOOSE_FILES")));assertFalse(PersonalCopyDestination.eligible(loc.copy(projectUid=null)))
        assertTrue(PersonalCopyDestination.needsUpgrade(listOf(project.copy(locations=listOf(loc.copy(owned=null))))))
    }
    @Test fun requestPersistsBeforeSendAndUnknownOutcomeRetriesSameUuidThenRefreshesDelivered() = runTest {
        val server=MockWebServer();server.start()
        try {
            val backend=Backend(server.url("/").toString().trimEnd('/'),MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            var saved:String?=null
            val store=PersonalConversationStore(backend::personalAccountScope,{saved},{saved=it})
            val state=PersonalWorkspaceState(backend,store).also { it.conversationId=source;it.messages.add("user" to "Original") }
            var attempts=0
            server.dispatcher=object:Dispatcher(){override fun dispatch(call:RecordedRequest):MockResponse {
                val persisted=store.load().desktopCopy!!.request
                assertTrue(saved!!.contains(persisted.requestId));assertFalse(saved!!.contains("synthetic"))
                if(call.method=="GET") return response(receipt(persisted,"DELIVERED"))
                val body=Json.parseToJsonElement(call.body.readUtf8()).jsonObject
                assertEquals(persisted.requestId,body.getValue("requestId").jsonPrimitive.content)
                assertEquals(uid,body.getValue("targetProjectUid").jsonPrimitive.content)
                return if(attempts++==0) MockResponse().setResponseCode(503) else response(receipt(persisted))
            }}
            state.copyTo(target());val original=state.desktopCopy!!.request.requestId
            assertNull(state.desktopCopy!!.receipt);assertNotNull(state.error)
            state.retryDesktopCopy();assertEquals(original,state.desktopCopy!!.request.requestId);assertEquals("QUEUED",state.desktopCopy!!.receipt!!.status)
            assertFalse(state.copySuccess);assertEquals(source,state.conversationId);assertEquals(1,state.messages.size)
            state.refreshDesktopCopy();assertEquals("DELIVERED",state.desktopCopy!!.receipt!!.status)
            assertEquals("DELIVERED",store.load().desktopCopy!!.receipt!!.status)
        } finally { server.shutdown() }
    }
    @Test fun recentServerReceiptRestoresStableQueuedRequestBeforeChoosingTarget() = runTest {
        val server=MockWebServer();server.start()
        try {
            val backend=Backend(server.url("/").toString().trimEnd('/'),MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            var saved:String?=null;val store=PersonalConversationStore(backend::personalAccountScope,{saved},{saved=it})
            val state=PersonalWorkspaceState(backend,store).also { it.conversationId=source }
            val request=DesktopCopyRequest(sourceConversationId=source,targetProjectUid=uid,targetDeviceId="desktop-a",targetProjectKey="17")
            val other = request.copy(requestId=UUID.randomUUID().toString(), targetDeviceId="desktop-b")
            server.enqueue(MockResponse().setBody("{\"code\":0,\"data\":["+Json.encodeToString(receipt(other))+","+Json.encodeToString(receipt(request))+"]}"))
            server.enqueue(MockResponse().setBody("[]"))
            state.prepareCopy();assertEquals(other,state.desktopCopy!!.request)
            server.enqueue(response(receipt(request)));state.copyTo(target())
            assertEquals(request.requestId,state.desktopCopy!!.request.requestId);assertEquals(request,store.load().desktopCopy!!.request)
            val calls=List(3){server.takeRequest()};assertEquals("GET",calls[0].method);assertEquals("POST",calls[2].method)
        } finally { server.shutdown() }
    }
    @Test fun failedLocalPersistenceNeverSendsAndChangedAccountNeverPublishesReceipt() = runTest {
        val server=MockWebServer();server.start()
        try {
            val sessions=MemorySessionStore().also { it.save("synthetic") };val backend=Backend(server.url("/").toString().trimEnd('/'),sessions).accountSnapshot()
            val broken=PersonalConversationStore(backend::personalAccountScope,{null},{throw IllegalStateException("disk full")})
            val failed=PersonalWorkspaceState(backend,broken).also { it.conversationId=source }
            failed.copyTo(target());assertEquals(0,server.requestCount);assertEquals("disk full",failed.error)
            var saved:String?=null;val store=PersonalConversationStore(backend::personalAccountScope,{saved},{saved=it})
            val state=PersonalWorkspaceState(backend,store).also { it.conversationId=source }
            server.dispatcher=object:Dispatcher(){override fun dispatch(call:RecordedRequest):MockResponse {
                val pending=store.load().desktopCopy!!.request;sessions.save("other-account");return response(receipt(pending))
            }}
            state.copyTo(target());assertNull(state.desktopCopy!!.receipt);assertFalse(store.isCurrent())
        } finally { server.shutdown() }
    }
    @Test fun terminalRetryUsesNewUuidButKeepsTargetIdentityAndNewConversationClearsPending() = runTest {
        val server=MockWebServer();server.start()
        try {
            val backend=Backend(server.url("/").toString().trimEnd('/'),MemorySessionStore().also { it.save("synthetic") }).accountSnapshot()
            var saved:String?=null;val store=PersonalConversationStore(backend::personalAccountScope,{saved},{saved=it})
            val state=PersonalWorkspaceState(backend,store).also { it.conversationId=source }
            val request=DesktopCopyRequest(sourceConversationId=source,targetProjectUid=uid,targetDeviceId="desktop-a",targetProjectKey="17")
            state.desktopCopy=PersonalDesktopCopy(request,receipt(request,"EXPIRED"))
            server.dispatcher=object:Dispatcher(){override fun dispatch(call:RecordedRequest)=response(receipt(store.load().desktopCopy!!.request))}
            state.retryDesktopCopy();assertNotEquals(request.requestId,state.desktopCopy!!.request.requestId)
            assertEquals(uid,state.desktopCopy!!.request.targetProjectUid)
            state.newConversation();assertNull(state.desktopCopy);assertNull(store.load().desktopCopy)
        } finally {server.shutdown()}
    }
}
