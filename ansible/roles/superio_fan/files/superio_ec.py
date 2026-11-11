# ITE IT8613E の環境コントローラ（LDN 4）のレジスタを /dev/port から読み書きする。
# superio-fan-metrics と superio-fan-control が共有する（置き場所は /usr/local/lib/superio-fan/）。
#
# レジスタは index（base+5）に番号を書いて data（base+6）から読み書きする。2 つのプロセスが index/data を
# 取り合わないように、同じロックファイルを flock する
import fcntl
import os

LOCK = "/run/lock/superio-fan-metrics.lock"
VENDOR_REG, VENDOR_ITE = 0x58, 0x90


class EC:
    def __init__(self, base):
        self.base = base
        self._lock = open(LOCK, "w")
        self._fd = os.open("/dev/port", os.O_RDWR)

    def lock(self):
        fcntl.flock(self._lock, fcntl.LOCK_EX)

    def unlock(self):
        fcntl.flock(self._lock, fcntl.LOCK_UN)

    def raw(self, reg, value=None):
        """レジスタを 1 つ読む（value を渡せば書く）。ロックは呼ぶ側が持っていること。"""
        os.lseek(self._fd, self.base + 5, 0)
        os.write(self._fd, bytes([reg]))
        os.lseek(self._fd, self.base + 6, 0)
        if value is None:
            return os.read(self._fd, 1)[0]
        os.write(self._fd, bytes([value]))

    def io(self, reg, value=None):
        """ロックを取ってレジスタを 1 つ読み（または書き）、すぐ放す。"""
        self.lock()
        try:
            return self.raw(reg, value)
        finally:
            self.unlock()
