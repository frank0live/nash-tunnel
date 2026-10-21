# Nash Tunnel

پنل و اسکریپت مدیریت تونل معکوس: **GRE + FRP + Backhaul (Xray) + Watchdog + Benchmark + Failover**

جایگزین کامل و متن‌باز برای پنل‌های تجاری این حوزه — بدون لایسنس، بدون قفل، بدون محدودیت تعداد سرور.

<p align="center">
  <img src="docs/panel.png" alt="Nash Tunnel panel" width="100%">
</p>


```
┌──────────────┐        GRE (L3)        ┌──────────────┐
│  IRAN server │◄══════════════════════►│ FOREIGN node │
│  (public IP) │                        │  (public IP) │
│              │◄──── FRP (reverse) ────│              │
│              │◄──── Xray REALITY ─────│              │
└──────┬───────┘                        └──────────────┘
       │
   :8090 panel  ──►  dashboard / watchdog / logs / benchmark
```

## نصب سریع

```bash
curl -fsSL https://raw.githubusercontent.com/frank0live/nash-tunnel/main/install.sh | bash
```

یا دستی:

```bash
git clone https://github.com/frank0live/nash-tunnel.git
cd nash-tunnel
bash nash.sh          # منوی تعاملی
```

## دستورات

| دستور | کار |
|---|---|
| `bash nash.sh status` | گزارش کامل سلامت (CPU/RAM/دیسک/سرویس‌ها/تونل) |
| `bash nash.sh install-iran` | نصب روی سرور ایران (GRE server + frps + پنل) |
| `bash nash.sh install-foreign` | نصب روی سرور خارج (GRE client + frpc + پنل) |
| `bash nash.sh backhaul` | ساخت سمت سرور Backhaul (Xray REALITY) |
| `bash nash.sh backhaul-client ...` | ساخت سمت کلاینت Backhaul |
| `bash nash.sh watchdog` | نصب/رفرش واچداگ (هر ۶۰ ثانیه) |
| `bash nash.sh benchmark` | تست پینگ/تاخیر همهٔ نودها و رتبه‌بندی |
| `bash nash.sh panel` | ریستارت پنل |
| `bash nash.sh uninstall` | حذف کامل |

## پنل وب

- آدرس: `http://SERVER_IP:8090`
- رمز در پایان نصب چاپ می‌شود (تصادفی ۱۴ کاراکتری)
- تغییر رمز: `bash nash.sh` → گزینه ۹
- امکانات: وضعیت زندهٔ CPU/RAM/دیسک/آپتایم، وضعیت سرویس‌ها، ریستارت تک‌کلیکی، تست زندهٔ نودها، لاگ‌ها، خروجی RTL فارسی

## Watchdog

سرویس systemd با تایمر ۶۰ ثانیه‌ای:

- سرویس‌های `nash-panel`, `nash-frps`, `nash-frpc`, `nash-backhaul` را چک می‌کند
- لینک `nash-gre` را چک می‌کند
- هر چیزی که افتاده بود را ریستارت می‌کند
- نتیجه را به تلگرام اطلاع می‌دهد (توکن/چت‌آیدی در `/etc/nash/config.json`)

## ساختار فایل‌ها

```
nash.sh                 اسکریپت اصلی (نصب/مدیریت/منو)
install.sh              نصب یک‌خطی
panel/panel.py          بک‌اند پنل (پایتون stdlib، بدون وابستگی)
web/index.html          فرانت پنل (تک‌فایل، RTL)
systemd/                یونیت‌های نمونه
/etc/nash/config.json   تنظیمات (پورت، نودها، تلگرام)
/etc/nash/panel.json    هش رمز و سشن‌ها
/etc/nash/frps.toml     تنظیمات FRP server
/etc/nash/frpc.toml     تنظیمات FRP client
/etc/nash/backhaul/     کانفیگ‌های Xray
```

## امنیت

- رمز پنل با PBKDF2-SHA256 (۱۲۰٬۰۰۰ دور) ذخیره می‌شود
- سشن با کوکی HttpOnly + SameSite=Strict، عمر ۱۲ ساعت
- توکن FRP و کلید GRE تصادفی تولید می‌شوند
- همهٔ فایل‌های حساس با مجوز `600`

پیشنهاد: پنل را پشت Nginx با TLS بگذارید یا فقط از IP خودتان باز کنید:

```bash
ufw allow from YOUR_IP to any port 8090
```

## لایسنس

MIT — آزاد برای استفاده شخصی و تجاری.
