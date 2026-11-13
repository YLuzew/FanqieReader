package org.mewx.wenku8_flutter

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * 番茄登录：开一个 WebView 让用户在番茄自己的页面上登录，登完把
 * fanqienovel.com 的 cookie 串读回来。
 *
 * 为什么是这条：番茄的手机号登录带 bdturing 滑块，客户端自己跑不完；
 * 而 sessionid 是 HttpOnly 的，页面里的 JavaScript 读不到 —— 只有
 * android.webkit.CookieManager 能把 HttpOnly 一起拿出来。
 */
class FanqieLoginPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(b.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "login" -> startLogin(result)
                    "cookies" -> result.success(readCookies())
                    "logout" -> {
                        CookieManager.getInstance().removeAllCookies(null)
                        CookieManager.getInstance().flush()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
        pending?.error("DETACHED", "页面已关闭", null)
        pending = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    private fun startLogin(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "登录需要在应用页面里发起", null)
            return
        }
        if (pending != null) {
            result.error("BUSY", "登录页已经开着了", null)
            return
        }
        pending = result
        try {
            activity.startActivityForResult(Intent(activity, FanqieLoginActivity::class.java), REQ)
        } catch (error: Throwable) {
            pending = null
            result.error("LAUNCH_FAILED", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ) return false
        val result = pending ?: return true
        pending = null
        if (resultCode == Activity.RESULT_OK) {
            result.success(data?.getStringExtra(FanqieLoginActivity.EXTRA_COOKIE) ?: readCookies())
        } else {
            result.success(null)
        }
        return true
    }

    /** 已经登过的话可以直接拿，不必再开一次页面。 */
    private fun readCookies(): String? {
        val manager = CookieManager.getInstance()
        manager.flush()
        return manager.getCookie(COOKIE_URL)
    }

    companion object {
        const val CHANNEL = "org.mewx.wenku8/fanqie_login"
        private const val REQ = 0x7A21
        const val COOKIE_URL = "https://fanqienovel.com"
    }
}

/**
 * 一个只干一件事的页面：把番茄首页装进 WebView。
 * 用户登完点右上角「完成」，这里把 cookie 递回去并关掉自己。
 */
class FanqieLoginActivity : Activity() {

    private lateinit var web: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(
            WebView(this).also { web = it },
            true,
        )

        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            userAgentString =
                "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
        }
        web.webViewClient = WebViewClient()
        web.loadUrl(START_URL)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(32, 24, 32, 24)
            setBackgroundColor(Color.parseColor("#F6F6F6"))
        }
        val hint = TextView(this).apply {
            text = "登录番茄后点右上角「完成」"
            textSize = 14f
            setTextColor(Color.parseColor("#666666"))
        }
        bar.addView(
            hint,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        bar.addView(
            Button(this).apply {
                text = "完成"
                setOnClickListener { finishWithCookie() }
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        root.addView(bar)
        root.addView(
            web,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        setContentView(root)
    }

    private fun finishWithCookie() {
        CookieManager.getInstance().flush()
        val cookie = CookieManager.getInstance().getCookie(COOKIE_URL) ?: ""
        setResult(RESULT_OK, Intent().putExtra(EXTRA_COOKIE, cookie))
        finish()
    }

    override fun onBackPressed() {
        if (::web.isInitialized && web.canGoBack()) {
            web.goBack()
            return
        }
        setResult(RESULT_CANCELED)
        finish()
    }

    override fun onDestroy() {
        if (::web.isInitialized) {
            web.destroy()
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_COOKIE = "cookie"
        private const val COOKIE_URL = "https://fanqienovel.com"
        private const val START_URL = "https://fanqienovel.com/"
    }
}
