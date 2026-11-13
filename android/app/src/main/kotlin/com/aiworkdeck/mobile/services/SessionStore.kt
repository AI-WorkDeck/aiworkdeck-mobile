package com.aiworkdeck.mobile.services

import android.content.Context
import com.aiworkdeck.mobile.design.tr
import java.util.logging.Logger

interface SessionStore {
    fun current(): String?
    /** 写盘并读回核对；存不住就抛 [SessionSaveFailed]——登录不能「成功」进一个重启即丢的会话。 */
    fun save(id: String)
    fun clear()
}

/** 登录接口已成功，但本机存不住会话。 */
class SessionSaveFailed : Exception(tr("error.sessionSaveFailed"))

/**
 * Keystore 在启动时打不开时用：不崩、也不假装能记住登录。每次登录时现试一次建加密存储
 * （开机未解锁等瞬时故障过后就能好）；还是不行就让登录明确失败。
 */
class DeferredSessionStore(private val open: () -> SessionStore) : SessionStore {
    private var delegate: SessionStore? = null
    override fun current(): String? = delegate?.current()
    override fun save(id: String) {
        val store = delegate ?: try { open() } catch (_: Exception) { throw SessionSaveFailed() }
        delegate = store
        store.save(id)
    }
    override fun clear() { delegate?.clear() }
}

/** 内存会话存储，测试用；不落盘。 */
class MemorySessionStore : SessionStore {
    private var id: String? = null
    override fun current(): String? = id
    override fun save(id: String) { this.id = id }
    override fun clear() { id = null }
}

/**
 * 会话存储的装配点。[EncryptedSessionStore] 的主密钥在 Keystore 里，重装系统、恢复出厂、
 * 从别的机器传数据过来都可能让密钥与密文对不上——那时 `create` 会抛，而它是在
 * `Application.onCreate` 里调的，抛出去就是「一开就崩」的死循环，用户连卸载都不好定位。
 *
 * 所以：抛了就把那份已经解不开的 prefs 文件删掉重来一次（代价只是要重新登录一次），
 * 再不行退到 [DeferredSessionStore]——App 能开，登录时再试；存不住就明说，不退到内存里假装记住了。
 */
object SessionStores {
    private val logger = Logger.getLogger("SessionStores")
    private const val FILE = "session"

    fun create(ctx: Context): SessionStore = try {
        EncryptedSessionStore(ctx)
    } catch (first: Exception) {
        logger.warning("加密会话存储打不开，清掉重建: ${first.message}")
        runCatching { ctx.deleteSharedPreferences(FILE) }
        try {
            EncryptedSessionStore(ctx)
        } catch (second: Exception) {
            logger.warning("加密会话存储重建仍失败，登录时再试: ${second.message}")
            DeferredSessionStore { EncryptedSessionStore(ctx) }
        }
    }
}
