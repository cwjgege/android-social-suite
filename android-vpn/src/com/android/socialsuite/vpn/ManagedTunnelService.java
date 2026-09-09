package com.android.socialsuite.vpn;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

import hev.sockstun.TProxyService;

public final class ManagedTunnelService extends VpnService {
    public static final String ACTION_CONNECT = "com.android.socialsuite.vpn.CONNECT";
    public static final String ACTION_DISCONNECT = "com.android.socialsuite.vpn.DISCONNECT";
    public static final String ACTION_STATUS = "com.android.socialsuite.vpn.STATUS";
    private static final String CHANNEL_ID = "android-social-tunnel";
    private static final int NOTIFICATION_ID = 1208;
    private static volatile boolean nativeRunning;
    private static volatile String lastError = "";
    private ParcelFileDescriptor tunnel;
    private String currentHost;
    private int currentPort;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_CONNECT : intent.getAction();
        if (ACTION_DISCONNECT.equals(action)) {
            stopTunnel();
            stopSelf();
            return START_NOT_STICKY;
        }

        SharedPreferences preferences = getSharedPreferences("managed", MODE_PRIVATE);
        String host = intent == null ? preferences.getString("host", "10.0.2.2")
                : intent.getStringExtra("socks_host");
        int port = intent == null ? preferences.getInt("port", 0)
                : intent.getIntExtra("socks_port", 0);
        if (host == null || !host.matches("[A-Za-z0-9.:_-]+") || port < 1 || port > 65535) {
            stopSelf();
            return START_NOT_STICKY;
        }

        Intent prepareIntent = VpnService.prepare(this);
        if (prepareIntent != null) {
            lastError = "SecurityException:VpnService authorization is required";
            android.util.Log.e("AndroidSocialTunnel", "VpnService authorization is required");
            stopSelf();
            return START_NOT_STICKY;
        }

        startAsForeground(port);
        preferences.edit().putString("host", host).putInt("port", port).apply();
        try {
            lastError = "";
            startTunnel(host, port);
            return START_STICKY;
        } catch (Exception exception) {
            lastError = exception.getClass().getSimpleName() + ":" + String.valueOf(exception.getMessage());
            android.util.Log.e("AndroidSocialTunnel", "Tunnel start failed", exception);
            stopTunnel();
            stopSelf();
            return START_NOT_STICKY;
        }
    }

    private synchronized void startTunnel(String host, int port) throws IOException {
        if (tunnel != null && port == currentPort && host.equals(currentHost)
                && nativeRunning) {
            return;
        }
        closeTunnelResources();
        Builder builder = new Builder()
                .setBlocking(false)
                .setSession("Android Social Suite")
                .setMtu(1500)
                .addAddress("198.18.0.1", 30)
                .addAddress("fd00:1:fd00:1::1", 126)
                .addRoute("0.0.0.0", 0)
                .addRoute("::", 0)
                .addDnsServer("198.18.0.2");
        try {
            builder.addDisallowedApplication(getPackageName());
        } catch (Exception ignored) {
        }
        tunnel = builder.establish();
        if (tunnel == null) {
            throw new IOException("VpnService authorization is unavailable");
        }

        File config = new File(getFilesDir(), "managed-tunnel.yml");
        String yaml = "misc:\n"
                + "  task-stack-size: 86016\n"
                + "tunnel:\n"
                + "  mtu: 1500\n"
                + "  icmp: 'reply'\n"
                + "socks5:\n"
                + "  address: '" + host + "'\n"
                + "  port: " + port + "\n"
                + "  udp: 'udp'\n"
                + "  udp-address: '" + host + "'\n"
                + "mapdns:\n"
                + "  address: 198.18.0.2\n"
                + "  port: 53\n"
                + "  network: 240.0.0.0\n"
                + "  netmask: 240.0.0.0\n"
                + "  cache-size: 10000\n";
        try (FileOutputStream output = new FileOutputStream(config, false)) {
            output.write(yaml.getBytes(StandardCharsets.UTF_8));
        }
        TProxyService.TProxyStartService(config.getAbsolutePath(), tunnel.getFd());
        nativeRunning = true;
        currentHost = host;
        currentPort = port;
    }

    private synchronized void closeTunnelResources() {
        if (nativeRunning) {
            TProxyService.TProxyStopService();
            nativeRunning = false;
        }
        if (tunnel != null) {
            try {
                tunnel.close();
            } catch (IOException ignored) {
            }
            tunnel = null;
        }
        currentHost = null;
        currentPort = 0;
    }

    private synchronized void stopTunnel() {
        closeTunnelResources();
        stopForeground(true);
    }

    public static boolean isTunnelRunning() {
        return nativeRunning;
    }

    public static String getLastError() {
        return lastError;
    }

    public static long[] getTunnelStats() {
        return nativeRunning ? TProxyService.TProxyGetStats() : new long[] { 0, 0, 0, 0 };
    }

    private void startAsForeground(int port) {
        NotificationManager manager = (NotificationManager) getSystemService(Service.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Android Social Tunnel", NotificationManager.IMPORTANCE_LOW);
            manager.createNotificationChannel(channel);
        }
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        Notification notification = builder
                .setContentTitle("Android Social Tunnel")
                .setContentText("Full device tunnel active on port " + port)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    @Override
    public void onRevoke() {
        stopTunnel();
        stopSelf();
        super.onRevoke();
    }

    @Override
    public void onDestroy() {
        stopTunnel();
        super.onDestroy();
    }
}
