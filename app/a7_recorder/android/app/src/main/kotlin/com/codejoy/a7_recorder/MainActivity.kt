package com.codejoy.a7_recorder

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Wi-Fi 快传:连设备无外网热点(Doway_<SN>)的原生通道。
 *
 * 关键坑:设备热点没有外网,Android 10+ 必须用 WifiNetworkSpecifier 连指定 SSID,
 * 连上后 **bindProcessToNetwork(该 network)**,否则 HTTP 会被系统路由到有外网的网卡、
 * 打不到 192.168.200.1。断开时解绑、恢复默认路由。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "a7/wifi"
    private var cm: ConnectivityManager? = null
    private var cb: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cm = applicationContext.getSystemService(ConnectivityManager::class.java)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> connect(
                        call.argument<String>("ssid") ?: "",
                        call.argument<String>("password") ?: "",
                        result,
                    )
                    "disconnect" -> { disconnect(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun connect(ssid: String, password: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Wi-Fi 快传需 Android 10+（WifiNetworkSpecifier）", null)
            return
        }
        disconnect() // 清掉上一次

        val specBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (password.isNotEmpty()) specBuilder.setWpa2Passphrase(password)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) // 设备热点无外网
            .setNetworkSpecifier(specBuilder.build())
            .build()

        var settled = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm?.bindProcessToNetwork(network) // 关键:本进程流量绑到无外网热点
                if (!settled) { settled = true; runOnUiThread { result.success(true) } }
            }
            override fun onUnavailable() {
                if (!settled) { settled = true; runOnUiThread { result.error("UNAVAILABLE", "连接热点失败或超时", null) } }
            }
            override fun onLost(network: Network) {
                cm?.bindProcessToNetwork(null)
            }
        }
        cb = callback
        try {
            cm?.requestNetwork(request, callback, 30000) // 30s 超时
        } catch (e: Exception) {
            result.error("REQUEST_FAILED", e.message, null)
        }
    }

    private fun disconnect() {
        try { cm?.bindProcessToNetwork(null) } catch (_: Exception) {}
        cb?.let { try { cm?.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        cb = null
    }
}
