import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Direct TCP path to the scrcpy server, bypassing adb's multiplexed transport.
 *
 * Launched over adb next to the scrcpy server:
 *   app_process / Relay <port> <hex token> <abstract socket name> [sndbuf bytes]
 *
 * Each accepted TCP connection must first send the 16-byte token (passed over the trusted adb
 * channel) and a mode byte; it is then connected to the scrcpy server's abstract socket and
 * piped both ways.
 *
 * Mode 1 ("timed control") is for the control connection: the client frames every message as
 * [u16 length][u64 client time µs][scrcpy control message]. The relay estimates the client
 * clock offset (minimum transit) and releases each message at its original spacing plus a small
 * adaptive jitter delay, so touch moves reach Android evenly even when Wi-Fi delivers them in
 * bursts. Android only redraws a dragged list when new input arrives for a frame, so bursty
 * input directly turns into dropped frames.
 * Connections are forwarded in accept order, so the client opens video, audio, control in turn.
 * Exits once all pipes are closed (or if nobody connects in time).
 */
public final class Relay {
    private static final AtomicInteger active = new AtomicInteger();
    private static volatile long lastActivity = System.currentTimeMillis();
    private static volatile boolean served = false;

    public static void main(String[] args) throws Exception {
        final int port = Integer.parseInt(args[0]);
        final byte[] token = hex(args[1]);
        final String name = args[2];
        final int sndbuf = args.length > 3 ? Integer.parseInt(args[3]) : 0;

        final ServerSocket server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(port), 8);
        server.setSoTimeout(1000);
        System.out.println("relay listening on " + port);
        System.out.flush();

        while (true) {
            Socket s;
            try {
                s = server.accept();
            } catch (SocketTimeoutException e) {
                long idle = System.currentTimeMillis() - lastActivity;
                if (active.get() == 0 && ((served && idle > 3000) || (!served && idle > 30000))) break;
                continue;
            }
            lastActivity = System.currentTimeMillis();
            try {
                s.setTcpNoDelay(true);
                if (sndbuf > 0) s.setSendBufferSize(sndbuf);
                s.setSoTimeout(3000);
                byte[] got = new byte[token.length];
                readFully(s.getInputStream(), got);
                if (!MessageDigest.isEqual(got, token)) { s.close(); continue; }
                int mode = s.getInputStream().read();
                s.setSoTimeout(0);
                LocalSocket local = connectLocal(name);
                served = true;
                pipe(s, local, mode == 1);
            } catch (Exception e) {
                try { s.close(); } catch (Exception ignored) {}
            }
        }
        server.close();
        System.out.println("relay done");
    }

    private static LocalSocket connectLocal(String name) throws Exception {
        long deadline = System.currentTimeMillis() + 10000;
        while (true) {
            LocalSocket l = new LocalSocket();
            try {
                l.connect(new LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT));
                return l;
            } catch (Exception e) {
                l.close();
                if (System.currentTimeMillis() > deadline) throw e;
                Thread.sleep(20);
            }
        }
    }

    private static void pipe(final Socket tcp, final LocalSocket local, boolean timed) throws Exception {
        final InputStream tin = tcp.getInputStream();
        final OutputStream tout = tcp.getOutputStream();
        final InputStream lin = local.getInputStream();
        final OutputStream lout = local.getOutputStream();
        active.addAndGet(2);
        start(lin, tout, tcp, local, "relay-down");
        if (timed) startTimed(tin, lout, tcp, local); else start(tin, lout, tcp, local, "relay-up");
    }

    /** Re-times framed control messages (see class comment). */
    private static void startTimed(final InputStream in, final OutputStream out, final Socket tcp, final LocalSocket local) {
        Thread t = new Thread(new Runnable() {
            public void run() {
                java.io.DataInputStream din = new java.io.DataInputStream(new java.io.BufferedInputStream(in, 64 * 1024));
                byte[] buf = new byte[512 * 1024];
                boolean haveOffset = false;
                long offset = 0;          // min(local arrival - client time), µs
                long lastUpdate = 0;
                final int window = 128;
                long[] excess = new long[window]; // arrival - (client time + offset): recent jitter
                int n = 0;
                long delay = 0;
                try {
                    while (true) {
                        int len = din.readUnsignedShort();
                        long clientUs = din.readLong();
                        if (len > buf.length) throw new Exception("frame too large");
                        din.readFully(buf, 0, len);
                        long nowUs = System.nanoTime() / 1000;
                        long sample = nowUs - clientUs;
                        // Track the minimum transit; let it creep up slowly (0.1%) to follow clock drift.
                        if (!haveOffset) { offset = sample; haveOffset = true; lastUpdate = nowUs; }
                        offset += (nowUs - lastUpdate) / 1000;
                        lastUpdate = nowUs;
                        if (sample < offset) offset = sample;
                        excess[n % window] = sample - offset;
                        n++;
                        if ((n & 15) == 0) {
                            int m = Math.min(n, window);
                            long[] c = java.util.Arrays.copyOf(excess, m);
                            java.util.Arrays.sort(c);
                            delay = Math.min(12000, c[(int) (m * 0.95) - (m >= 20 ? 1 : 0) < 0 ? 0 : Math.max(0, (int) (m * 0.95) - 1)]);
                        }
                        long release = clientUs + offset + delay;
                        long wait = release - System.nanoTime() / 1000;
                        if (wait > 200 && wait < 50000) java.util.concurrent.locks.LockSupport.parkNanos(wait * 1000);
                        out.write(buf, 0, len);
                        lastActivity = System.currentTimeMillis();
                    }
                } catch (Exception ignored) {
                } finally {
                    try { tcp.close(); } catch (Exception ignored) {}
                    try { local.close(); } catch (Exception ignored) {}
                    lastActivity = System.currentTimeMillis();
                    active.decrementAndGet();
                }
            }
        }, "relay-timed");
        t.setPriority(Thread.MAX_PRIORITY);
        t.start();
    }

    private static void start(final InputStream in, final OutputStream out, final Socket tcp, final LocalSocket local, String n) {
        Thread t = new Thread(new Runnable() {
            public void run() {
                byte[] buf = new byte[256 * 1024];
                try {
                    int r;
                    while ((r = in.read(buf)) > 0) {
                        out.write(buf, 0, r);
                        lastActivity = System.currentTimeMillis();
                    }
                } catch (Exception ignored) {
                } finally {
                    try { tcp.close(); } catch (Exception ignored) {}
                    try { local.close(); } catch (Exception ignored) {}
                    lastActivity = System.currentTimeMillis();
                    active.decrementAndGet();
                }
            }
        }, n);
        t.setPriority(Thread.MAX_PRIORITY);
        t.start();
    }

    private static void readFully(InputStream in, byte[] b) throws Exception {
        int off = 0;
        while (off < b.length) {
            int r = in.read(b, off, b.length - off);
            if (r < 0) throw new Exception("eof");
            off += r;
        }
    }

    private static byte[] hex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }
}
