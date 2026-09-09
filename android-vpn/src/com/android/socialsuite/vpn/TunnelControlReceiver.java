package com.android.socialsuite.vpn;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import hev.sockstun.TProxyService;

public final class TunnelControlReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? "" : intent.getAction();
        if (ManagedTunnelService.ACTION_STATUS.equals(action)) {
            boolean running = ManagedTunnelService.isTunnelRunning();
            long[] stats = running ? ManagedTunnelService.getTunnelStats() : new long[] { 0, 0, 0, 0 };
            String error = ManagedTunnelService.getLastError();
            if (error == null) {
                error = "";
            }
            error = error.replace(';', ',').replace('\r', ' ').replace('\n', ' ');
            setResultCode(Activity.RESULT_OK);
            setResultData("running=" + running
                    + ";txPackets=" + stats[0]
                    + ";txBytes=" + stats[1]
                    + ";rxPackets=" + stats[2]
                    + ";rxBytes=" + stats[3]
                    + ";error=" + error);
            return;
        }

        Intent service = new Intent(context, ManagedTunnelService.class);
        service.setAction(action);
        if (intent != null && intent.getExtras() != null) {
            service.putExtras(intent.getExtras());
        }
        if (ManagedTunnelService.ACTION_CONNECT.equals(action) && Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(service);
        } else {
            context.startService(service);
        }
        setResultCode(Activity.RESULT_OK);
        setResultData("accepted=true");
    }
}
