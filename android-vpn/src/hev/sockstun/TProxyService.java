package hev.sockstun;

public final class TProxyService {
    public static native void TProxyStartService(String configPath, int fileDescriptor);
    public static native void TProxyStopService();
    public static native long[] TProxyGetStats();

    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    private TProxyService() {
    }
}
